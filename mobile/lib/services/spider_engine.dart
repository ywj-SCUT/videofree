import 'dart:async';
import 'dart:convert';

import 'package:flutter_js/flutter_js.dart';

import '../models/models.dart';
import 'net_service.dart';

/// Executes the same CommonJS rule contract used by the Electron client.
///
/// A rule exports async `search`, `detail`, and `play` functions. Each function
/// receives `{query|id|token}` and a context containing `request` and `config`.
/// `request` is bridged back to Dart so headers, limits, and timeouts remain
/// under the mobile client's control.
abstract interface class SpiderRuleExecutor {
  Future<dynamic> search(CmsSource source, String query);
  Future<dynamic> detail(CmsSource source, String id);
  Future<dynamic> play(CmsSource source, dynamic token);
}

class FlutterJsSpiderEngine implements SpiderRuleExecutor {
  FlutterJsSpiderEngine({NetService? net}) : _net = net ?? NetService();

  final NetService _net;
  final Map<String, Future<String>> _scriptCache = {};

  static final RegExp _blockedScript = RegExp(
    r'\b(?:process|require|child_process|worker_threads|global\.process|Deno)\b|'
    r'\bimport\s*\(|\beval\s*\(|\bFunction\s*\(',
  );

  @override
  Future<dynamic> search(CmsSource source, String query) =>
      _run(source, 'search', {'query': query, 'page': 1});

  @override
  Future<dynamic> detail(CmsSource source, String id) =>
      _run(source, 'detail', {'id': id});

  @override
  Future<dynamic> play(CmsSource source, dynamic token) =>
      _run(source, 'play', {'token': token});

  Future<dynamic> _run(
    CmsSource source,
    String operation,
    Map<String, dynamic> input,
  ) async {
    final script = await _loadScript(source);
    _validateScript(script);

    final runtime = getJavascriptRuntime(xhr: false);
    try {
      runtime.onMessage('VideoGETRequest', (dynamic args) async {
        final request = _asMap(args is String ? jsonDecode(args) : args);
        final url = _text(request['url']);
        if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(url)) {
          throw Exception('规则仅可请求 HTTP/HTTPS 地址');
        }
        final options = _asMap(request['options']);
        final rawMethod = _text(options['method']).toUpperCase();
        final method = rawMethod.isEmpty ? 'GET' : rawMethod;
        if (method != 'GET' && method != 'POST') {
          throw Exception('规则请求仅支持 GET/POST');
        }
        final body = options['body'] is String
            ? options['body'] as String
            : null;
        if (body != null && utf8.encode(body).length > 256 * 1024) {
          throw Exception('规则请求体超过 256 KB');
        }
        final rawHeaders = _asMap(options['headers']);
        final headers = <String, String>{
          ...?source.headers,
          for (final entry in rawHeaders.entries)
            entry.key.toString(): entry.value.toString(),
        };
        return _net.fetchRemoteText(
          url,
          method: method,
          headers: headers,
          body: body,
          timeout: const Duration(seconds: 8),
          maxBytes: 2 * 1024 * 1024,
        );
      });

      final code =
          '''
        globalThis.module = { exports: {} };
        globalThis.exports = globalThis.module.exports;
        globalThis.__input = ${jsonEncode(input)};
        globalThis.__config = ${jsonEncode(source.ruleConfig ?? const {})};
        globalThis.__request = function(url, options) {
          return sendMessage('VideoGETRequest', JSON.stringify({
            url: url,
            options: options || {}
          }));
        };
        globalThis.fetch = async function(url, options) {
          var body = await globalThis.__request(url, options || {});
          return Object.freeze({
            ok: true,
            status: 200,
            text: async function() { return body; },
            json: async function() { return JSON.parse(body); }
          });
        };
        $script
        globalThis.__rule = globalThis.module.exports;
        if (globalThis.__rule && globalThis.__rule.default &&
            typeof globalThis.__rule.default === 'object') {
          globalThis.__rule = globalThis.__rule.default;
        }
        (async function() {
          if (!globalThis.__rule ||
              typeof globalThis.__rule[${jsonEncode(operation)}] !== 'function') {
            throw new Error('规则缺少 $operation 函数');
          }
          return await globalThis.__rule[${jsonEncode(operation)}](
            globalThis.__input,
            Object.freeze({ request: globalThis.__request, config: globalThis.__config })
          );
        })();
      ''';
      final pending = await runtime.evaluateAsync(
        code,
        sourceUrl: 'videoget-rule.js',
      );
      if (pending.isError) throw Exception(_cleanJsError(pending.stringResult));
      runtime.executePendingJob();
      final result = await runtime.handlePromise(
        pending,
        timeout: const Duration(seconds: 12),
      );
      if (result.isError) throw Exception(_cleanJsError(result.stringResult));
      return _decodeResult(result);
    } on TimeoutException {
      throw Exception('规则 $operation 执行超过 12 秒');
    } finally {
      runtime.dispose();
    }
  }

  Future<String> _loadScript(CmsSource source) {
    if (source.script != null && source.script!.trim().isNotEmpty) {
      return Future.value(source.script!);
    }
    final url = source.scriptUrl;
    if (url == null ||
        !RegExp(r'^https?://', caseSensitive: false).hasMatch(url)) {
      throw Exception('规则源没有有效脚本地址');
    }
    return _scriptCache.putIfAbsent(
      url,
      () => _net.fetchRemoteText(
        url,
        headers: source.headers,
        timeout: const Duration(seconds: 10),
        maxBytes: 200 * 1024,
      ),
    );
  }

  void _validateScript(String script) {
    if (script.trim().isEmpty) throw Exception('规则脚本为空');
    if (utf8.encode(script).length > 200 * 1024) {
      throw Exception('规则脚本超过 200 KB');
    }
    if (_blockedScript.hasMatch(script)) {
      throw Exception('规则包含不支持的运行时能力');
    }
  }

  dynamic _decodeResult(JsEvalResult result) {
    final text = result.stringResult.trim();
    if (text.isEmpty || text == 'undefined') return null;
    try {
      return jsonDecode(text);
    } catch (_) {
      if (result.rawResult is String) return result.rawResult;
      return text;
    }
  }

  String _cleanJsError(String value) => value
      .replaceFirst(RegExp(r'^Exception:\s*'), '')
      .replaceFirst(RegExp(r'^Error:\s*'), '')
      .trim();

  static Map<String, dynamic> _asMap(dynamic value) => value is Map
      ? value.map((key, item) => MapEntry(key.toString(), item))
      : <String, dynamic>{};

  static String _text(dynamic value) => value?.toString().trim() ?? '';
}
