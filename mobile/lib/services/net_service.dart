import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'system_playback_controls.dart';

typedef NetworkProxy = ({String host, int port});

Duration networkAttemptTimeout({
  required Duration remaining,
  required bool proxyAvailable,
  required bool proxyPreferred,
  required bool usingProxy,
}) {
  if (remaining <= Duration.zero) return Duration.zero;
  final remainingMs = remaining.inMilliseconds;
  if (!usingProxy && proxyAvailable && !proxyPreferred) {
    final fallbackReserveMs = remainingMs >= 6000
        ? 2000
        : remainingMs > 1000
        ? 500
        : math.max(100, remainingMs ~/ 4);
    final directMs = remainingMs > fallbackReserveMs
        ? remainingMs - fallbackReserveMs
        : remainingMs;
    return Duration(milliseconds: math.min(directMs, 4000));
  }
  if (usingProxy && proxyAvailable && proxyPreferred) {
    final reserveMs = remainingMs > 1000
        ? 500
        : math.max(100, remainingMs ~/ 4);
    if (remainingMs > reserveMs) {
      return Duration(milliseconds: remainingMs - reserveMs);
    }
  }
  return remaining;
}

class RemoteProbe {
  final Uint8List bytes;
  final Duration timeToFirstByte;
  final Duration elapsed;
  final String contentType;
  final Uri finalUri;
  final bool usedProxy;

  const RemoteProbe({
    required this.bytes,
    required this.timeToFirstByte,
    required this.elapsed,
    required this.contentType,
    required this.finalUri,
    this.usedProxy = false,
  });
}

/// On-device HTTP service with direct-first proxy fallback per origin.
class NetService {
  NetService({Future<NetworkProxy?> Function()? proxyProvider})
    : _proxyProvider = proxyProvider ?? SystemPlaybackControls.networkProxy;

  static const _defaultHeaders = <String, String>{
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/131 Mobile Safari/537.36',
    'Accept': '*/*',
  };
  static const _proxyPreferenceLifetime = Duration(minutes: 10);
  static final Map<String, DateTime> _proxyPreferredUntil = {};
  final Future<NetworkProxy?> Function() _proxyProvider;
  final Dio _directDio = _createDio();
  final Map<String, Dio> _proxyDios = {};
  Future<NetworkProxy?>? _proxyFuture;

  static Dio _createDio() => Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 15),
      followRedirects: true,
      validateStatus: (status) => status != null && status < 400,
    ),
  );

  static bool preferProxyFor(Uri uri) {
    if (!uri.hasScheme || uri.host.isEmpty) return false;
    final key = uri.origin;
    final expiry = _proxyPreferredUntil[key];
    if (expiry == null) return false;
    if (expiry.isAfter(DateTime.now())) return true;
    _proxyPreferredUntil.remove(key);
    return false;
  }

  static void recordProxyResult(Uri uri, {required bool usedProxy}) {
    if (!uri.hasScheme || uri.host.isEmpty) return;
    if (usedProxy) {
      _proxyPreferredUntil[uri.origin] = DateTime.now().add(
        _proxyPreferenceLifetime,
      );
    } else {
      _proxyPreferredUntil.remove(uri.origin);
    }
  }

  static void resetProxyPreferencesForTesting() => _proxyPreferredUntil.clear();

  /// Fetches text, strips a BOM and rejects unexpectedly large responses.
  Future<String> fetchRemoteText(
    String url, {
    String method = 'GET',
    Map<String, String>? headers,
    String? body,
    Duration? timeout,
    int maxBytes = 20 * 1024 * 1024,
  }) async {
    final normalizedMethod = method.toUpperCase();
    _validateRequest(url, normalizedMethod);
    final response = await _request<String>(
      url,
      method: normalizedMethod,
      headers: headers,
      body: body,
      timeout: timeout,
      responseType: ResponseType.plain,
    );
    var text = response.data ?? '';
    if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) {
      text = text.substring(1);
    }
    if (utf8.encode(text).length > maxBytes) {
      throw Exception('响应内容过大');
    }
    return text;
  }

  /// Reads only the leading bytes needed by route health checks.
  Future<RemoteProbe> probeRemote(
    String url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 3),
    int maxBytes = 256 * 1024,
  }) async {
    _validateRequest(url, 'GET');
    final stopwatch = Stopwatch()..start();
    final response = await _request<ResponseBody>(
      url,
      method: 'GET',
      headers: {
        ...?headers,
        HttpHeaders.rangeHeader: 'bytes=0-${maxBytes - 1}',
      },
      timeout: timeout,
      responseType: ResponseType.stream,
    );
    final timeToFirstByte = stopwatch.elapsed;
    final builder = BytesBuilder(copy: false);
    var remaining = maxBytes;
    final stream = response.data?.stream;
    if (stream != null) {
      await for (final chunk in stream.timeout(timeout)) {
        if (remaining <= 0) break;
        final take = chunk.length > remaining ? remaining : chunk.length;
        builder.add(take == chunk.length ? chunk : chunk.sublist(0, take));
        remaining -= take;
        if (remaining <= 0) break;
      }
    }
    stopwatch.stop();
    return RemoteProbe(
      bytes: builder.takeBytes(),
      timeToFirstByte: timeToFirstByte,
      elapsed: stopwatch.elapsed,
      contentType: response.headers.value(HttpHeaders.contentTypeHeader) ?? '',
      finalUri: response.realUri,
      usedProxy: response.requestOptions.extra['videogetUsedProxy'] == true,
    );
  }

  Future<dynamic> fetchJson(
    String url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    final text = await fetchRemoteText(url, headers: headers, timeout: timeout);
    return jsonDecode(text);
  }

  void _validateRequest(String url, String method) {
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(url)) {
      throw Exception('仅支持 HTTP/HTTPS 地址');
    }
    if (method != 'GET' && method != 'POST') {
      throw Exception('仅支持 GET/POST 请求');
    }
  }

  Future<Response<T>> _request<T>(
    String url, {
    required String method,
    required ResponseType responseType,
    Map<String, String>? headers,
    String? body,
    Duration? timeout,
  }) async {
    final proxy = await (_proxyFuture ??= _proxyProvider());
    final totalTimeout = timeout ?? const Duration(seconds: 8);
    final deadline = DateTime.now().add(totalTimeout);
    final target = Uri.parse(url);
    final proxyFirst = proxy != null && preferProxyFor(target);
    final attempts = proxyFirst
        ? <bool>[true, false]
        : <bool>[false, if (proxy != null) true];
    Object? lastError;
    StackTrace? lastStack;
    for (final useProxy in attempts) {
      if (useProxy && proxy == null) continue;
      try {
        final dio = useProxy ? _proxyDio(proxy!) : _directDio;
        final remaining = deadline.difference(DateTime.now());
        final attemptTimeout = networkAttemptTimeout(
          remaining: remaining,
          proxyAvailable: proxy != null,
          proxyPreferred: proxyFirst,
          usingProxy: useProxy,
        );
        if (attemptTimeout <= Duration.zero) break;
        final future = dio.request<T>(
          url,
          data: body,
          options: Options(
            method: method,
            headers: {..._defaultHeaders, ...?headers},
            responseType: responseType,
            sendTimeout: attemptTimeout,
            receiveTimeout: attemptTimeout,
          ),
        );
        final response = await future.timeout(attemptTimeout);
        response.requestOptions.extra['videogetUsedProxy'] = useProxy;
        recordProxyResult(target, usedProxy: useProxy);
        recordProxyResult(response.realUri, usedProxy: useProxy);
        return response;
      } catch (error, stack) {
        if (!useProxy && proxy != null && _isTransportFailure(error)) {
          _proxyPreferredUntil[target.origin] = DateTime.now().add(
            _proxyPreferenceLifetime,
          );
        }
        lastError = error;
        lastStack = stack;
      }
    }
    Error.throwWithStackTrace(
      lastError ?? TimeoutException('网络请求超时', totalTimeout),
      lastStack ?? StackTrace.current,
    );
  }

  Dio _proxyDio(NetworkProxy proxy) {
    final key = '${proxy.host}:${proxy.port}';
    return _proxyDios.putIfAbsent(key, () {
      final dio = _createDio();
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () => HttpClient()
          ..connectionTimeout = const Duration(seconds: 8)
          ..findProxy = (_) => 'PROXY ${proxy.host}:${proxy.port}',
      );
      return dio;
    });
  }

  bool _isTransportFailure(Object error) {
    if (error is TimeoutException || error is SocketException) return true;
    if (error is! DioException) return false;
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.connectionError ||
      DioExceptionType.unknown => true,
      _ => false,
    };
  }
}
