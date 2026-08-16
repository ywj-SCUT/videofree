import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'hls_manifest_filter.dart';
import 'system_playback_controls.dart';

const _maxCacheBytes = 1024 * 1024 * 1024;
const _maxEntryBytes = 100 * 1024 * 1024;
const _cacheableExtensions = {
  '.ts',
  '.m4s',
  '.aac',
  '.mp4',
  '.key',
  '.vtt',
  '.webvtt',
  '.srt',
  '.cmfv',
  '.cmfa',
};

bool isCacheableVideoResponse(Uri url, String contentType) {
  if (contentType.toLowerCase().contains('mpegurl') ||
      url.path.toLowerCase().endsWith('.m3u8')) {
    return false;
  }
  final name = url.pathSegments.isEmpty
      ? ''
      : url.pathSegments.last.toLowerCase();
  final dot = name.lastIndexOf('.');
  final extension = dot >= 0 ? name.substring(dot) : '';
  return _cacheableExtensions.contains(extension) ||
      contentType.toLowerCase().startsWith('video/') ||
      contentType.toLowerCase().startsWith('audio/') ||
      contentType.toLowerCase().startsWith('application/octet-stream');
}

class PlaybackProxy {
  PlaybackProxy._();

  static final instance = PlaybackProxy._();

  HttpServer? _server;
  final HttpClient _directClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5);
  HttpClient? _proxyClient;
  late final Directory _cacheDirectory;
  Future<void>? _starting;
  final Map<String, Future<File?>> _inflight = {};
  bool _evicting = false;

  Future<Uri> urlFor(
    String source, {
    Map<String, String>? headers,
    bool filterAds = true,
  }) async {
    await start();
    return Uri.http('127.0.0.1:${_server!.port}', '/stream', {
      'url': source,
      if (filterAds) 'filterAds': '1',
      if (headers != null && headers.isNotEmpty) 'headers': jsonEncode(headers),
    });
  }

  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    final persistentPath =
        await SystemPlaybackControls.playbackCacheDirectory();
    _cacheDirectory = Directory(
      persistentPath ??
          '${Directory.systemTemp.path}${Platform.pathSeparator}videoget-video-cache',
    );
    await _cacheDirectory.create(recursive: true);
    await for (final entry in _cacheDirectory.list()) {
      if (entry is File && entry.path.contains('.tmp-')) {
        try {
          await entry.delete();
        } catch (_) {}
      }
    }
    final proxy = await SystemPlaybackControls.networkProxy();
    if (proxy != null) {
      _proxyClient = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15)
        ..findProxy = (_) => 'PROXY ${proxy.host}:${proxy.port}';
    }
    _server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
      shared: true,
    );
    unawaited(_serve());
  }

  Future<void> _serve() async {
    await for (final request in _server!) {
      unawaited(_handle(request));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    var responseStarted = false;
    Completer<File?>? cacheOwner;
    String? ownedCacheIdentity;
    final targetValue = request.uri.queryParameters['url'] ?? '';
    final target = Uri.tryParse(targetValue);
    if (request.uri.path != '/stream' ||
        target == null ||
        !target.hasScheme ||
        !{'http', 'https'}.contains(target.scheme)) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }
    try {
      final customHeaders = _decodeHeaders(
        request.uri.queryParameters['headers'],
      );
      final range = request.headers.value(HttpHeaders.rangeHeader);
      final cacheIdentity =
          '$targetValue\n${_canonicalHeaders(customHeaders)}\nrange:${range ?? ''}';
      final cacheFile = File(
        '${_cacheDirectory.path}${Platform.pathSeparator}${_cacheKey(cacheIdentity)}',
      );
      if (await _serveCached(request, cacheFile, range)) {
        responseStarted = true;
        return;
      }

      // HLS players may ask for the same media object concurrently. Let the
      // first request stream and persist it while later requests wait for the
      // resulting cache file instead of downloading a duplicate.
      if (isCacheableVideoResponse(target, '')) {
        final pending = _inflight[cacheIdentity];
        if (pending != null) {
          final completedFile = await pending;
          if (completedFile != null &&
              await _serveCached(request, completedFile, range)) {
            responseStarted = true;
            return;
          }
        } else {
          cacheOwner = Completer<File?>();
          ownedCacheIdentity = cacheIdentity;
          _inflight[cacheIdentity] = cacheOwner.future;
        }
      }

      final upstream = await _open(
        target,
        customHeaders,
        range,
        request.uri.queryParameters['referer'],
      );
      request.response.statusCode = upstream.statusCode;
      final contentType =
          upstream.headers.value(HttpHeaders.contentTypeHeader) ?? '';
      final isManifest =
          contentType.toLowerCase().contains('mpegurl') ||
          target.path.toLowerCase().endsWith('.m3u8');
      if (isManifest) {
        final original = await utf8.decoder.bind(upstream).join();
        final filtered = request.uri.queryParameters['filterAds'] == '1'
            ? filterHlsManifest(original)
            : HlsFilterResult(
                manifest: original,
                removedSegments: 0,
                removedDuration: 0,
                removedMarkers: 0,
              );
        request.response.headers
          ..contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
            charset: 'utf-8',
          )
          ..set(HttpHeaders.cacheControlHeader, 'no-cache')
          ..set('X-VideoGET-Ad-Segments', filtered.removedSegments)
          ..set(
            'X-VideoGET-Ad-Seconds',
            filtered.removedDuration.toStringAsFixed(3),
          );
        request.response.write(
          _rewriteManifest(
            filtered.manifest,
            target,
            customHeaders,
            request.uri.queryParameters['filterAds'] == '1',
          ),
        );
        responseStarted = true;
        await request.response.close();
        return;
      }

      for (final name in [
        HttpHeaders.contentTypeHeader,
        HttpHeaders.contentLengthHeader,
        HttpHeaders.contentRangeHeader,
        HttpHeaders.acceptRangesHeader,
        HttpHeaders.cacheControlHeader,
      ]) {
        final value = upstream.headers.value(name);
        if (value != null) request.response.headers.set(name, value);
      }
      final declaredLength = upstream.contentLength;
      var cacheable =
          (upstream.statusCode == HttpStatus.ok ||
              upstream.statusCode == HttpStatus.partialContent) &&
          isCacheableVideoResponse(target, contentType) &&
          (declaredLength < 0 || declaredLength <= _maxEntryBytes);
      IOSink? sink;
      File? temporary;
      var written = 0;
      if (cacheable) {
        request.response.headers.set('X-VideoGET-Cache', 'MISS');
        temporary = File(
          '${cacheFile.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
        );
        sink = temporary.openWrite();
      }
      responseStarted = true;
      await for (final chunk in upstream) {
        request.response.add(chunk);
        if (cacheable) {
          written += chunk.length;
          if (written <= _maxEntryBytes) {
            sink!.add(chunk);
          } else {
            cacheable = false;
            await sink!.close();
            sink = null;
            try {
              await temporary!.delete();
            } catch (_) {}
          }
        }
      }
      await request.response.close();
      if (cacheable && sink != null && temporary != null) {
        await sink.close();
        if (await cacheFile.exists()) {
          await temporary.delete();
        } else {
          await temporary.rename(cacheFile.path);
        }
        cacheOwner?.complete(cacheFile);
        unawaited(_evict());
      }
    } catch (error) {
      try {
        if (!responseStarted) {
          request.response.statusCode = HttpStatus.badGateway;
          request.response.write(error);
        }
        await request.response.close();
      } catch (_) {}
    } finally {
      if (cacheOwner != null) {
        if (!cacheOwner.isCompleted) cacheOwner.complete(null);
        if (_inflight[ownedCacheIdentity] == cacheOwner.future) {
          _inflight.remove(ownedCacheIdentity);
        }
      }
    }
  }

  Future<bool> _serveCached(
    HttpRequest request,
    File cacheFile,
    String? range,
  ) async {
    if (!await cacheFile.exists()) return false;
    final size = await cacheFile.length();
    if (size <= 0) return false;
    if (range == null) {
      request.response.headers
        ..contentType = ContentType.binary
        ..contentLength = size
        ..set('X-VideoGET-Cache', 'HIT')
        ..set(
          HttpHeaders.cacheControlHeader,
          'public, max-age=86400, immutable',
        );
    } else {
      request.response
        ..statusCode = HttpStatus.partialContent
        ..headers.contentType = ContentType.binary
        ..headers.contentLength = size
        ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          _cachedRangeHeader(range, size),
        )
        ..headers.set('X-VideoGET-Cache', 'HIT');
    }
    await cacheFile.openRead().pipe(request.response);
    unawaited(cacheFile.setLastModified(DateTime.now()));
    return true;
  }

  Future<HttpClientResponse> _open(
    Uri target,
    Map<String, String> headers,
    String? range,
    String? referer,
  ) async {
    Future<HttpClientResponse> send(HttpClient client) async {
      final request = await client.getUrl(target);
      request.followRedirects = true;
      request.headers
        ..set(
          HttpHeaders.userAgentHeader,
          'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 Chrome/131 Mobile Safari/537.36',
        )
        ..set(HttpHeaders.acceptHeader, '*/*');
      headers.forEach(request.headers.set);
      if (referer != null &&
          referer.isNotEmpty &&
          !headers.keys.any((key) => key.toLowerCase() == 'referer')) {
        request.headers.set(HttpHeaders.refererHeader, referer);
      }
      if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
      return request.close().timeout(const Duration(seconds: 45));
    }

    try {
      final response = await send(_directClient);
      if (response.statusCode < 400 ||
          response.statusCode == HttpStatus.partialContent) {
        return response;
      }
      await response.drain<void>();
    } catch (_) {
      // Retry below with the configured Android network proxy.
    }
    final proxy = _proxyClient;
    if (proxy == null) {
      throw HttpException('Upstream request failed', uri: target);
    }
    return send(proxy);
  }

  Map<String, String> _decodeHeaders(String? value) {
    if (value == null || value.length > 12000) return {};
    try {
      final decoded = jsonDecode(value) as Map<String, dynamic>;
      const blocked = {
        'host',
        'content-length',
        'connection',
        'proxy-authorization',
        'transfer-encoding',
        'range',
      };
      return {
        for (final entry in decoded.entries)
          if (!blocked.contains(entry.key.toLowerCase()) &&
              !entry.value.toString().contains(RegExp(r'[\r\n]')))
            entry.key: entry.value.toString(),
      };
    } catch (_) {
      return {};
    }
  }

  String _rewriteManifest(
    String manifest,
    Uri manifestUrl,
    Map<String, String> headers,
    bool filterAds,
  ) {
    return manifest
        .split(RegExp(r'\r?\n'))
        .map((line) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) return line;
          if (trimmed.startsWith('#')) {
            return line.replaceAllMapped(RegExp(r'URI="([^"]+)"'), (match) {
              final absolute = manifestUrl.resolve(match.group(1)!).toString();
              return 'URI="${_localUrl(absolute, headers, filterAds, manifestUrl.toString())}"';
            });
          }
          return _localUrl(
            manifestUrl.resolve(trimmed).toString(),
            headers,
            filterAds,
            manifestUrl.toString(),
          );
        })
        .join('\n');
  }

  String _localUrl(
    String target,
    Map<String, String> headers,
    bool filterAds,
    String referer,
  ) => Uri.http('127.0.0.1:${_server!.port}', '/stream', {
    'url': target,
    'referer': referer,
    if (filterAds) 'filterAds': '1',
    if (headers.isNotEmpty) 'headers': jsonEncode(headers),
  }).toString();

  String _canonicalHeaders(Map<String, String> headers) {
    final entries = headers.entries.toList()
      ..sort(
        (left, right) =>
            left.key.toLowerCase().compareTo(right.key.toLowerCase()),
      );
    return entries
        .map((entry) => '${entry.key.toLowerCase()}:${entry.value}')
        .join('\n');
  }

  String _cachedRangeHeader(String range, int size) {
    final match = RegExp(
      r'^bytes=(\d+)-(\d*)$',
      caseSensitive: false,
    ).firstMatch(range);
    if (match == null) return 'bytes 0-${size - 1}/*';
    final start = int.parse(match.group(1)!);
    final requestedEnd = int.tryParse(match.group(2) ?? '') ?? start + size - 1;
    return 'bytes $start-${math.min(requestedEnd, start + size - 1)}/*';
  }

  String _cacheKey(String value) {
    var hash = 0xcbf29ce484222325;
    for (final byte in utf8.encode(value)) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  Future<void> _evict() async {
    if (_evicting) return;
    _evicting = true;
    try {
      final files = await _cacheDirectory
          .list()
          .where((entry) => entry is File && !entry.path.endsWith('.tmp'))
          .cast<File>()
          .toList();
      final entries = <({File file, FileStat stat})>[];
      var total = 0;
      for (final file in files) {
        final stat = await file.stat();
        total += stat.size;
        entries.add((file: file, stat: stat));
      }
      entries.sort(
        (left, right) => left.stat.modified.compareTo(right.stat.modified),
      );
      while (total > _maxCacheBytes * 0.9 && entries.isNotEmpty) {
        final oldest = entries.removeAt(0);
        try {
          await oldest.file.delete();
          total -= oldest.stat.size;
        } catch (_) {}
      }
    } finally {
      _evicting = false;
    }
  }
}
