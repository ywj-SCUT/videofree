import 'dart:convert';
import 'package:dio/dio.dart';

/// 本地 HTTP 文本获取服务，替代 electron/net-client.ts。
/// 手机直连 CMS 源，不走电脑上的服务或代理。
class NetService {
  NetService();

  static const _defaultHeaders = <String, String>{
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/131 Mobile Safari/537.36',
    'Accept': '*/*',
  };

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      followRedirects: true,
      validateStatus: (status) => status != null && status < 400,
    ),
  );

  /// 远程获取文本内容。去掉 BOM 头，限制最大响应长度。
  Future<String> fetchRemoteText(
    String url, {
    String method = 'GET',
    Map<String, String>? headers,
    String? body,
    Duration? timeout,
    int maxBytes = 20 * 1024 * 1024,
  }) async {
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(url)) {
      throw Exception('仅支持 HTTP/HTTPS 地址');
    }
    final normalizedMethod = method.toUpperCase();
    if (normalizedMethod != 'GET' && normalizedMethod != 'POST') {
      throw Exception('仅支持 GET/POST 请求');
    }
    final response = await _dio.request<String>(
      url,
      data: body,
      options: Options(
        method: normalizedMethod,
        headers: {..._defaultHeaders, ...?headers},
        responseType: ResponseType.plain,
        receiveTimeout: timeout,
      ),
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

  Future<dynamic> fetchJson(
    String url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    final text = await fetchRemoteText(url, headers: headers, timeout: timeout);
    return jsonDecode(text);
  }
}
