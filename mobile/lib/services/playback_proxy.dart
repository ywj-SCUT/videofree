import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;

import 'hls_manifest_filter.dart';
import 'net_service.dart';
import 'system_playback_controls.dart';

const _maxCacheBytes = 4 * 1024 * 1024 * 1024;
const _maxEntryBytes = 100 * 1024 * 1024;
const _upstreamResponseTimeout = Duration(seconds: 12);
const _directProbeTimeout = Duration(seconds: 4);
// A distant VOD segment can be several megabytes on a congested mobile
// route.  Prefetch is background work, so give the body enough time to finish
// instead of cancelling the local proxy request while the player is seeking.
const _prefetchResponseTimeout = Duration(seconds: 90);
const _prefetchSnapshotLifetime = Duration(seconds: 30);
const _rangePrefetchMinimumAge = Duration(seconds: 3);
const _rangePrefetchWaitTimeout = Duration(milliseconds: 4500);
// Keep one upstream lane free for foreground playback. The seek anchors are
// still fetched before sequential backfill, but a second background transfer
// can otherwise starve the segment mpv is currently decoding on slower hosts.
const _prefetchConcurrency = 1;
const _prefetchOpeningSegments = 6;
const _prefetchMaxSegments = 24;
const _prefetchAnchorSeconds = 5 * 60.0;
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

void _debugProxyLog(String message) {
  assert(() {
    developer.log(message, name: 'VideoGET.PlaybackProxy.Debug');
    return true;
  }());
}

Duration upstreamAttemptTimeout({
  required Duration remaining,
  required bool proxyAvailable,
  required bool proxyPreferred,
  required bool usingProxy,
}) {
  if (remaining <= Duration.zero) return Duration.zero;
  final remainingMs = remaining.inMilliseconds;
  final fallbackReserveMs = remainingMs >= 6000
      ? 2000
      : remainingMs > 1000
      ? 500
      : math.max(100, remainingMs ~/ 4);
  final budgetWithFallback = remainingMs > fallbackReserveMs
      ? Duration(milliseconds: remainingMs - fallbackReserveMs)
      : remaining;
  if (!usingProxy && proxyAvailable && !proxyPreferred) {
    return budgetWithFallback < _directProbeTimeout
        ? budgetWithFallback
        : _directProbeTimeout;
  }
  if (usingProxy && proxyAvailable && proxyPreferred) {
    return budgetWithFallback;
  }
  return remaining;
}

Duration rangePrefetchWaitBudget({
  required DateTime now,
  required DateTime? startedAt,
}) {
  if (startedAt == null ||
      now.difference(startedAt) < _rangePrefetchMinimumAge) {
    return Duration.zero;
  }
  return _rangePrefetchWaitTimeout;
}

({int start, int end})? resolveCachedByteRange(String range, int size) {
  if (size <= 0) return null;
  final match = RegExp(
    r'^bytes=(\d*)-(\d*)$',
    caseSensitive: false,
  ).firstMatch(range.trim());
  if (match == null) return null;
  final startValue = match.group(1) ?? '';
  final endValue = match.group(2) ?? '';
  if (startValue.isEmpty) {
    final suffixLength = int.tryParse(endValue);
    if (suffixLength == null || suffixLength <= 0) return null;
    final start = math.max(0, size - suffixLength);
    return (start: start, end: size - 1);
  }
  final start = int.tryParse(startValue);
  if (start == null || start < 0 || start >= size) return null;
  final requestedEnd = endValue.isEmpty ? size - 1 : int.tryParse(endValue);
  if (requestedEnd == null || requestedEnd < start) return null;
  return (start: start, end: math.min(requestedEnd, size - 1));
}

({int start, int end, int total})? parseProgressiveContentRange(String? value) {
  final match = RegExp(
    r'^bytes\s+(\d+)-(\d+)/(\d+)$',
    caseSensitive: false,
  ).firstMatch(value?.trim() ?? '');
  if (match == null) return null;
  final start = int.parse(match.group(1)!);
  final end = int.parse(match.group(2)!);
  final total = int.parse(match.group(3)!);
  if (start < 0 || end < start || total <= end) return null;
  return (start: start, end: end, total: total);
}

bool validPartialContent(String range, int statusCode, String? contentRange) {
  if (statusCode != HttpStatus.partialContent || contentRange == null) {
    return false;
  }
  final requested = RegExp(
    r'^bytes=(\d+)-(\d*)$',
    caseSensitive: false,
  ).firstMatch(range);
  final received = RegExp(
    r'^bytes\s+(\d+)-(\d+)/(\d+)$',
    caseSensitive: false,
  ).firstMatch(contentRange.trim());
  if (requested == null || received == null) return false;
  final requestedStart = int.parse(requested.group(1)!);
  final requestedEnd = int.tryParse(requested.group(2) ?? '');
  final receivedStart = int.parse(received.group(1)!);
  final receivedEnd = int.parse(received.group(2)!);
  final total = int.parse(received.group(3)!);
  if (total <= 0 || receivedStart >= total || receivedEnd >= total) {
    return false;
  }
  final expectedEnd = requestedEnd == null
      ? total - 1
      : math.min(requestedEnd, total - 1);
  return receivedStart == requestedStart &&
      receivedEnd >= receivedStart &&
      receivedEnd == expectedEnd;
}

class _HlsManifestSnapshot {
  final Uri uri;
  final String rootSource;
  final String manifest;
  final DateTime capturedAt;

  const _HlsManifestSnapshot({
    required this.uri,
    required this.rootSource,
    required this.manifest,
    required this.capturedAt,
  });
}

class _OpenedResponse {
  final HttpClientResponse response;
  final bool usedProxy;

  const _OpenedResponse(this.response, {required this.usedProxy});
}

List<Uri> hlsReferencedUris(String manifest, Uri manifestUri) {
  final references = <Uri>[];
  final seen = <String>{};

  void add(String value) {
    final uri = manifestUri.resolve(value.trim());
    if (!{'http', 'https'}.contains(uri.scheme) || uri.host.isEmpty) return;
    if (seen.add(uri.toString())) references.add(uri);
  }

  for (final line in manifest.split(RegExp(r'\r?\n'))) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    if (trimmed.startsWith('#')) {
      for (final match in RegExp(r'URI="([^"]+)"').allMatches(trimmed)) {
        add(match.group(1)!);
      }
    } else {
      add(trimmed);
    }
  }
  return references;
}

void inheritHlsProxyPreference(String manifest, Uri manifestUri) {
  for (final uri in hlsReferencedUris(manifest, manifestUri)) {
    NetService.recordProxyResult(uri, usedProxy: true);
  }
}

List<int> timelinePrefetchIndexes(
  List<double> segmentDurations, {
  int openingSegmentCount = _prefetchOpeningSegments,
  int maxSegments = _prefetchMaxSegments,
  double anchorSeconds = _prefetchAnchorSeconds,
}) {
  if (segmentDurations.isEmpty || maxSegments <= 0) return const [];
  final selected = <int>[];

  void add(int index) {
    if (index >= 0 &&
        index < segmentDurations.length &&
        selected.length < maxSegments &&
        !selected.contains(index)) {
      selected.add(index);
    }
  }

  final opening = math.min(
    segmentDurations.length,
    openingSegmentCount.clamp(0, 6),
  );
  for (var index = 0; index < opening; index++) {
    add(index);
  }
  if (anchorSeconds <= 0) return selected;

  final anchors = <int>[];
  var anchor = anchorSeconds;
  var segmentIndex = 0;
  var elapsed = 0.0;
  while (segmentIndex < segmentDurations.length) {
    while (segmentIndex < segmentDurations.length &&
        elapsed + math.max(0, segmentDurations[segmentIndex]) <= anchor) {
      elapsed += math.max(0, segmentDurations[segmentIndex]);
      segmentIndex++;
    }
    if (segmentIndex >= segmentDurations.length) break;
    anchors.add(segmentIndex);
    anchor += anchorSeconds;
  }
  // Start both common seek points and their following segments in the first
  // burst. mpv requests that pair for the tested 5/10-minute seeks. The
  // preceding keyframe segments follow immediately as a secondary window.
  final initialAnchors = math.min(2, anchors.length);
  for (var index = 0; index < initialAnchors; index++) {
    add(anchors[index]);
  }
  for (var index = 0; index < initialAnchors; index++) {
    add(anchors[index] + 1);
  }
  for (var index = 0; index < initialAnchors; index++) {
    add(anchors[index] - 1);
  }
  for (var index = initialAnchors; index < anchors.length; index++) {
    add(anchors[index]);
    add(anchors[index] + 1);
    add(anchors[index] - 1);
  }
  return selected;
}

List<Uri> hlsTimelinePrefetchTargets(
  String manifest,
  Uri manifestUri, {
  int openingSegmentCount = _prefetchOpeningSegments,
  int maxSegments = _prefetchMaxSegments,
  double anchorSeconds = _prefetchAnchorSeconds,
}) {
  final durations = <double>[];
  final urls = <Uri>[];
  double? pendingDuration;
  for (final line in manifest.split(RegExp(r'\r?\n'))) {
    final trimmed = line.trim();
    if (trimmed.toUpperCase().startsWith('#EXTINF:')) {
      pendingDuration =
          double.tryParse(
            RegExp(
                  r'^#EXTINF:([\d.]+)',
                  caseSensitive: false,
                ).firstMatch(trimmed)?.group(1) ??
                '',
          ) ??
          0;
      continue;
    }
    if (pendingDuration != null &&
        trimmed.isNotEmpty &&
        !trimmed.startsWith('#')) {
      durations.add(pendingDuration);
      urls.add(manifestUri.resolve(trimmed));
      pendingDuration = null;
    }
  }
  return timelinePrefetchIndexes(
    durations,
    openingSegmentCount: openingSegmentCount,
    maxSegments: maxSegments,
    anchorSeconds: anchorSeconds,
  ).map((index) => urls[index]).toList();
}

List<int> fullEpisodePrefetchIndexes(
  List<double> segmentDurations, {
  int openingSegmentCount = _prefetchOpeningSegments,
  int prioritySegments = _prefetchMaxSegments,
  double anchorSeconds = _prefetchAnchorSeconds,
}) {
  final priority = timelinePrefetchIndexes(
    segmentDurations,
    openingSegmentCount: openingSegmentCount,
    maxSegments: prioritySegments,
    anchorSeconds: anchorSeconds,
  );
  final selected = priority.toSet();
  return [
    ...priority,
    for (var index = 0; index < segmentDurations.length; index++)
      if (selected.add(index)) index,
  ];
}

List<Uri> hlsFullEpisodePrefetchTargets(
  String manifest,
  Uri manifestUri, {
  int openingSegmentCount = _prefetchOpeningSegments,
  int prioritySegments = _prefetchMaxSegments,
  double anchorSeconds = _prefetchAnchorSeconds,
}) {
  final durations = <double>[];
  final urls = <Uri>[];
  double? pendingDuration;
  for (final line in manifest.split(RegExp(r'\r?\n'))) {
    final trimmed = line.trim();
    if (trimmed.toUpperCase().startsWith('#EXTINF:')) {
      pendingDuration =
          double.tryParse(
            RegExp(
                  r'^#EXTINF:([\d.]+)',
                  caseSensitive: false,
                ).firstMatch(trimmed)?.group(1) ??
                '',
          ) ??
          0;
      continue;
    }
    if (pendingDuration != null &&
        trimmed.isNotEmpty &&
        !trimmed.startsWith('#')) {
      durations.add(pendingDuration);
      urls.add(manifestUri.resolve(trimmed));
      pendingDuration = null;
    }
  }
  return fullEpisodePrefetchIndexes(
    durations,
    openingSegmentCount: openingSegmentCount,
    prioritySegments: prioritySegments,
    anchorSeconds: anchorSeconds,
  ).map((index) => urls[index]).toList();
}

List<Uri> _hlsVariantManifests(String manifest, Uri manifestUri) {
  final variants = <Uri>[];
  var expectsVariant = false;
  for (final line in manifest.split(RegExp(r'\r?\n'))) {
    final trimmed = line.trim();
    if (trimmed.toUpperCase().startsWith('#EXT-X-STREAM-INF:')) {
      expectsVariant = true;
      continue;
    }
    if (expectsVariant && trimmed.isNotEmpty && !trimmed.startsWith('#')) {
      variants.add(manifestUri.resolve(trimmed));
      expectsVariant = false;
    }
  }
  return variants;
}

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
  final Set<String> _prefetchInflight = {};
  final Map<String, DateTime> _prefetchStartedAt = {};
  _HlsManifestSnapshot? _latestMediaManifest;
  HttpClient? _prefetchClient;
  int _prefetchGeneration = 0;
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

  Future<bool> warmUpFirstSegment(Uri playbackUrl) async {
    await start();
    final rootSource = playbackUrl.queryParameters['url'];
    final sourceUri = rootSource == null ? null : Uri.tryParse(rootSource);
    if (sourceUri == null || !sourceUri.path.toLowerCase().endsWith('.m3u8')) {
      return true;
    }

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      var manifestUri = playbackUrl;
      for (var depth = 0; depth < 3; depth++) {
        final manifest = await _readWarmupManifest(client, manifestUri);
        if (manifest == null) return false;
        final targets = hlsFullEpisodePrefetchTargets(
          manifest,
          manifestUri,
          openingSegmentCount: 1,
          prioritySegments: 1,
        );
        if (targets.isNotEmpty) {
          return _warmupTarget(client, targets.first);
        }
        final variants = _hlsVariantManifests(manifest, manifestUri);
        if (variants.isEmpty) return false;
        manifestUri = variants.first;
      }
      return false;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<String?> _readWarmupManifest(HttpClient client, Uri uri) async {
    final request = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 3));
    final response = await request.close().timeout(_upstreamResponseTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await utf8.decoder.bind(response).join();
      developer.log(
        'Warmup manifest failed: uri=$uri status=${response.statusCode} body=$body',
        name: 'VideoGET.PlaybackProxy',
      );
      return null;
    }
    return utf8.decoder.bind(response).join().timeout(_upstreamResponseTimeout);
  }

  Future<bool> _warmupTarget(HttpClient client, Uri target) async {
    final request = await client
        .getUrl(target)
        .timeout(const Duration(seconds: 3));
    final response = await request.close().timeout(_upstreamResponseTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await utf8.decoder.bind(response).join();
      developer.log(
        'Warmup segment failed: uri=$target status=${response.statusCode} body=$body',
        name: 'VideoGET.PlaybackProxy',
      );
      return false;
    }
    var bytes = 0;
    await for (final chunk in response.timeout(_prefetchResponseTimeout)) {
      bytes += chunk.length;
    }
    return bytes > 0;
  }

  Future<void> prefetchTimeline(Uri playbackUrl) async {
    stopPrefetch();
    final generation = _prefetchGeneration;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    _prefetchClient = client;
    try {
      final rootSource = playbackUrl.queryParameters['url'] ?? '';
      final snapshot = _latestMediaManifest;
      var manifestUri = playbackUrl;
      String? manifest;
      if (snapshot != null &&
          snapshot.rootSource == rootSource &&
          DateTime.now().difference(snapshot.capturedAt) <=
              _prefetchSnapshotLifetime) {
        manifestUri = snapshot.uri;
        manifest = snapshot.manifest;
      } else {
        final sourceUri = Uri.tryParse(rootSource);
        if (sourceUri == null) {
          return;
        }
        if (!sourceUri.path.toLowerCase().endsWith('.m3u8')) {
          await _prefetchProgressive(
            client,
            playbackUrl,
            rootSource,
            generation,
          );
          return;
        }
        manifest = await _readPrefetchManifest(client, playbackUrl, generation);
      }
      if (manifest == null || generation != _prefetchGeneration) return;

      // Playback already owns the opening segments. Fetch seek anchors first
      // so a jump to 5/10 minutes does not wait behind sequential backfill.
      var priorityTargets = hlsTimelinePrefetchTargets(
        manifest,
        manifestUri,
        openingSegmentCount: 0,
        maxSegments: 8,
      );
      var targets = hlsFullEpisodePrefetchTargets(manifest, manifestUri);
      if (targets.isEmpty) {
        for (final variant in _hlsVariantManifests(
          manifest,
          manifestUri,
        ).take(3)) {
          final nested = await _readPrefetchManifest(
            client,
            variant,
            generation,
          );
          if (nested == null || generation != _prefetchGeneration) return;
          priorityTargets = hlsTimelinePrefetchTargets(
            nested,
            variant,
            openingSegmentCount: 0,
            maxSegments: 8,
          );
          targets = hlsFullEpisodePrefetchTargets(nested, variant);
          if (targets.isNotEmpty) break;
        }
      }
      if (targets.isEmpty || generation != _prefetchGeneration) return;

      Future<void> fetchBatch(List<Uri> batch, int concurrency) async {
        var next = 0;
        Future<void> worker() async {
          while (generation == _prefetchGeneration && next < batch.length) {
            final target = batch[next++];
            try {
              await _prefetchTarget(client, target, generation);
            } catch (_) {
              if (generation != _prefetchGeneration) return;
            }
          }
        }

        await Future.wait(
          List.generate(math.min(concurrency, batch.length), (_) => worker()),
        );
      }

      // Keep a single worker moving through the seek window so foreground
      // playback always has bandwidth for its current segment.
      await fetchBatch(priorityTargets, _prefetchConcurrency);
      if (generation == _prefetchGeneration) {
        final prioritySet = priorityTargets
            .map((uri) => uri.toString())
            .toSet();
        await fetchBatch(
          targets
              .where((target) => !prioritySet.contains(target.toString()))
              .toList(),
          1,
        );
      }
    } catch (_) {
      // Prefetch is opportunistic and must never interrupt active playback.
    } finally {
      client.close(force: true);
      if (identical(_prefetchClient, client)) _prefetchClient = null;
    }
  }

  void stopPrefetch() {
    _prefetchGeneration++;
    _prefetchClient?.close(force: true);
    _prefetchClient = null;
  }

  Future<String?> _readPrefetchManifest(
    HttpClient client,
    Uri uri,
    int generation,
  ) async {
    if (generation != _prefetchGeneration) return null;
    final request = await client.getUrl(uri);
    final response = await request.close().timeout(_upstreamResponseTimeout);
    if (response.statusCode >= 400) {
      await response.drain<void>();
      return null;
    }
    final contentType =
        response.headers.value(HttpHeaders.contentTypeHeader)?.toLowerCase() ??
        '';
    if (!contentType.contains('mpegurl')) {
      await response.drain<void>();
      return null;
    }
    final manifest = await utf8.decoder
        .bind(response)
        .join()
        .timeout(_upstreamResponseTimeout);
    return generation == _prefetchGeneration ? manifest : null;
  }

  Future<void> _prefetchTarget(
    HttpClient client,
    Uri target,
    int generation,
  ) async {
    if (generation != _prefetchGeneration) return;
    // Tag background requests so a foreground seek never waits on their
    // slower cache-owner future. The query parameter is consumed locally and
    // is not sent to the upstream media URL.
    final requestUri = target.replace(
      queryParameters: {...target.queryParameters, 'prefetch': '1'},
    );
    final request = await client.getUrl(requestUri);
    final response = await request.close().timeout(_upstreamResponseTimeout);
    if (response.statusCode >= 400) {
      await response.drain<void>();
      return;
    }
    await response.drain<void>().timeout(_prefetchResponseTimeout);
  }

  Future<void> _prefetchProgressive(
    HttpClient client,
    Uri playbackUrl,
    String rootSource,
    int generation,
  ) async {
    final headers = _decodeHeaders(playbackUrl.queryParameters['headers']);
    final complete = _cacheFileFor(rootSource, headers, null);
    if (await complete.exists()) return;
    final partial = File('${complete.path}.progress');
    var offset = await partial.exists() ? await partial.length() : 0;
    final request = await client.getUrl(playbackUrl);
    if (offset > 0) {
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
    }
    final response = await request.close().timeout(_upstreamResponseTimeout);
    if (response.statusCode >= 400) {
      await response.drain<void>();
      return;
    }

    int? totalLength;
    var append = false;
    if (response.statusCode == HttpStatus.partialContent) {
      final contentRange = parseProgressiveContentRange(
        response.headers.value(HttpHeaders.contentRangeHeader),
      );
      if (contentRange == null || contentRange.start != offset) {
        await response.drain<void>();
        return;
      }
      totalLength = contentRange.total;
      append = offset > 0;
    } else if (response.statusCode == HttpStatus.ok) {
      offset = 0;
    } else {
      await response.drain<void>();
      return;
    }

    final sink = partial.openWrite(
      mode: append ? FileMode.append : FileMode.write,
    );
    var written = offset;
    try {
      await for (final chunk in response) {
        if (generation != _prefetchGeneration) break;
        sink.add(chunk);
        written += chunk.length;
      }
    } finally {
      await sink.close();
    }
    if (generation != _prefetchGeneration) return;
    final completeResponse = response.statusCode == HttpStatus.ok;
    if (!completeResponse && (totalLength == null || written < totalLength)) {
      return;
    }
    if (await complete.exists()) {
      await partial.delete();
    } else {
      await partial.rename(complete.path);
    }
    unawaited(_evict());
  }

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
        ..connectionTimeout = const Duration(seconds: 8)
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
    final requestTimer = Stopwatch()..start();
    var responseStarted = false;
    Completer<File?>? cacheOwner;
    String? ownedCacheIdentity;
    var ownedPrefetch = false;
    final isPrefetchRequest = request.uri.queryParameters['prefetch'] == '1';
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
      final cacheIdentity = _cacheIdentity(targetValue, customHeaders, range);
      final cacheFile = _cacheFileFor(targetValue, customHeaders, range);
      final debugTarget = '${target.host}${target.path}';
      if (range != null) {
        final completeFile = _cacheFileFor(targetValue, customHeaders, null);
        if (await _serveCompleteFileRange(request, completeFile, range)) {
          responseStarted = true;
          return;
        }
      }
      if (await _serveCached(request, cacheFile, range)) {
        responseStarted = true;
        return;
      }

      if (range != null && !isPrefetchRequest) {
        final completeIdentity = _cacheIdentity(
          targetValue,
          customHeaders,
          null,
        );
        final completePending = _inflight[completeIdentity];
        final waitBudget = rangePrefetchWaitBudget(
          now: DateTime.now(),
          startedAt: _prefetchStartedAt[completeIdentity],
        );
        if (completePending != null && waitBudget > Duration.zero) {
          File? completedFile;
          try {
            completedFile = await completePending.timeout(waitBudget);
          } on TimeoutException {
            // The interactive request falls through to its own upstream fetch.
          }
          if (completedFile != null &&
              await _serveCompleteFileRange(request, completedFile, range)) {
            responseStarted = true;
            return;
          }
        }
      }

      // HLS players may ask for the same media object concurrently. Let the
      // first request stream and persist it while later requests wait for the
      // resulting cache file instead of downloading a duplicate.
      if (isCacheableVideoResponse(target, '')) {
        final pending = _inflight[cacheIdentity];
        if (pending != null) {
          // A background prefetch can be much slower than an interactive seek.
          // In that case stream the foreground request independently; the two
          // temporary files race harmlessly and the first completed cache wins.
          if (!isPrefetchRequest && _prefetchInflight.contains(cacheIdentity)) {
            // Continue with a foreground upstream request.
          } else {
            final completedFile = await pending;
            if (completedFile != null &&
                await _serveCached(request, completedFile, range)) {
              responseStarted = true;
              return;
            }
          }
        } else {
          cacheOwner = Completer<File?>();
          ownedCacheIdentity = cacheIdentity;
          ownedPrefetch = isPrefetchRequest;
          _inflight[cacheIdentity] = cacheOwner.future;
          if (ownedPrefetch) {
            _prefetchInflight.add(cacheIdentity);
            _prefetchStartedAt[cacheIdentity] = DateTime.now();
          }
        }
      }

      final opened = await _open(
        target,
        customHeaders,
        range,
        request.uri.queryParameters['referer'],
      );
      final upstream = opened.response;
      if (range != null) {
        // A range request can arrive while a full-segment prefetch is about to
        // finish. Recheck after the upstream handshake so the completed file
        // wins that race instead of downloading the same segment twice.
        final completeFile = _cacheFileFor(targetValue, customHeaders, null);
        if (await _serveCompleteFileRange(request, completeFile, range)) {
          responseStarted = true;
          final subscription = upstream.listen((_) {});
          await subscription.cancel();
          return;
        }
      }
      _debugProxyLog(
        'open target=$debugTarget prefetch=$isPrefetchRequest '
        'proxy=${opened.usedProxy} status=${upstream.statusCode} '
        'length=${upstream.contentLength}',
      );
      request.response.statusCode = upstream.statusCode;
      final contentType =
          upstream.headers.value(HttpHeaders.contentTypeHeader) ?? '';
      final isManifest =
          contentType.toLowerCase().contains('mpegurl') ||
          target.path.toLowerCase().endsWith('.m3u8');
      if (isManifest) {
        final original = await utf8.decoder.bind(upstream).join();
        if (opened.usedProxy) {
          inheritHlsProxyPreference(original, target);
        }
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
        final rewritten = _rewriteManifest(
          filtered.manifest,
          target,
          customHeaders,
          request.uri.queryParameters['filterAds'] == '1',
        );
        final localManifestUri = Uri.parse(
          'http://127.0.0.1:${_server!.port}${request.uri}',
        );
        if (hlsTimelinePrefetchTargets(
          rewritten,
          localManifestUri,
          maxSegments: 1,
        ).isNotEmpty) {
          _latestMediaManifest = _HlsManifestSnapshot(
            uri: localManifestUri,
            rootSource:
                request.uri.queryParameters['referer'] ?? target.toString(),
            manifest: rewritten,
            capturedAt: DateTime.now(),
          );
        }
        request.response.write(rewritten);
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
      final cacheableStatus = range == null
          ? upstream.statusCode == HttpStatus.ok
          : validPartialContent(
              range,
              upstream.statusCode,
              upstream.headers.value(HttpHeaders.contentRangeHeader),
            );
      var cacheable =
          cacheableStatus &&
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
      _debugProxyLog(
        'complete target=$debugTarget prefetch=$isPrefetchRequest '
        'bytes=$written elapsedMs=${requestTimer.elapsedMilliseconds} '
        'cached=$cacheable',
      );
    } catch (error) {
      _debugProxyLog(
        'failed target=${target.host}${target.path} '
        'prefetch=$isPrefetchRequest responseStarted=$responseStarted '
        'elapsedMs=${requestTimer.elapsedMilliseconds} error=$error',
      );
      developer.log(
        'Proxy request failed: target=$target '
        'range=${request.headers.value(HttpHeaders.rangeHeader)} '
        'error=$error',
        name: 'VideoGET.PlaybackProxy',
        error: error,
      );
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
        if (ownedPrefetch) {
          _prefetchInflight.remove(ownedCacheIdentity);
          _prefetchStartedAt.remove(ownedCacheIdentity);
        }
      }
    }
  }

  Future<bool> _serveCompleteFileRange(
    HttpRequest request,
    File completeFile,
    String range,
  ) async {
    if (!await completeFile.exists()) return false;
    final size = await completeFile.length();
    final resolved = resolveCachedByteRange(range, size);
    if (resolved == null) {
      request.response
        ..statusCode = HttpStatus.requestedRangeNotSatisfiable
        ..headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
      await request.response.close();
      return true;
    }
    final length = resolved.end - resolved.start + 1;
    request.response
      ..statusCode = HttpStatus.partialContent
      ..headers.contentType = ContentType.binary
      ..headers.contentLength = length
      ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes ${resolved.start}-${resolved.end}/$size',
      )
      ..headers.set('X-VideoGET-Cache', 'HIT-FULL');
    _debugProxyLog(
      'hit-full target=${request.uri.queryParameters['url']} '
      'range=$range bytes=$length',
    );
    await completeFile
        .openRead(resolved.start, resolved.end + 1)
        .pipe(request.response);
    unawaited(completeFile.setLastModified(DateTime.now()));
    return true;
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
    _debugProxyLog(
      'hit target=${request.uri.queryParameters['url']} '
      'range=${range ?? 'full'} bytes=$size',
    );
    await cacheFile.openRead().pipe(request.response);
    unawaited(cacheFile.setLastModified(DateTime.now()));
    return true;
  }

  Future<_OpenedResponse> _open(
    Uri target,
    Map<String, String> headers,
    String? range,
    String? referer,
  ) async {
    Future<HttpClientResponse> send(
      HttpClient client,
      Duration attemptBudget,
    ) async {
      final attemptTimer = Stopwatch()..start();
      HttpClientRequest? request;
      try {
        request = await client.getUrl(target).timeout(attemptBudget);
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

        final closeBudget = attemptBudget - attemptTimer.elapsed;
        if (closeBudget <= Duration.zero) {
          throw TimeoutException('Upstream response timeout', attemptBudget);
        }
        return await request.close().timeout(closeBudget);
      } on TimeoutException catch (error) {
        request?.abort(error);
        rethrow;
      }
    }

    final totalTimer = Stopwatch()..start();
    final proxy = _proxyClient;
    final proxyFirst = proxy != null && NetService.preferProxyFor(target);
    final clients = proxyFirst
        ? <({HttpClient client, bool proxy})>[
            (client: proxy, proxy: true),
            (client: _directClient, proxy: false),
          ]
        : <({HttpClient client, bool proxy})>[
            (client: _directClient, proxy: false),
            if (proxy != null) (client: proxy, proxy: true),
          ];
    Object? lastError;
    for (final attempt in clients) {
      final remaining = _upstreamResponseTimeout - totalTimer.elapsed;
      final attemptBudget = upstreamAttemptTimeout(
        remaining: remaining,
        proxyAvailable: proxy != null,
        proxyPreferred: proxyFirst,
        usingProxy: attempt.proxy,
      );
      if (attemptBudget <= Duration.zero) {
        lastError = TimeoutException(
          'Upstream response timeout',
          _upstreamResponseTimeout,
        );
        break;
      }
      try {
        final response = await send(attempt.client, attemptBudget);
        if (response.statusCode < 400 ||
            response.statusCode == HttpStatus.partialContent) {
          NetService.recordProxyResult(target, usedProxy: attempt.proxy);
          return _OpenedResponse(response, usedProxy: attempt.proxy);
        }
        await response.listen((_) {}).cancel();
        lastError = HttpException(
          'Upstream returned HTTP ${response.statusCode}',
          uri: target,
        );
      } catch (error) {
        lastError = error;
      }
    }
    throw HttpException(
      'Upstream request failed: ${lastError ?? 'unknown error'}',
      uri: target,
    );
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

  String _cacheIdentity(
    String target,
    Map<String, String> headers,
    String? range,
  ) => '$target\n${_canonicalHeaders(headers)}\nrange-v2:${range ?? ''}';

  File _cacheFileFor(
    String target,
    Map<String, String> headers,
    String? range,
  ) => File(
    '${_cacheDirectory.path}${Platform.pathSeparator}'
    '${_cacheKey(_cacheIdentity(target, headers, range))}',
  );

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
          .where(
            (entry) =>
                entry is File &&
                !entry.path.endsWith('.tmp') &&
                !entry.path.contains('.tmp-') &&
                !entry.path.endsWith('.progress'),
          )
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
