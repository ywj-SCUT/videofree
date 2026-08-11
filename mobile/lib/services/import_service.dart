import 'dart:convert';

import '../models/models.dart';
import 'net_service.dart';
import 'source_engine.dart';

class ImportService {
  ImportService({NetService? net, SourceEngine? sourceEngine})
    : _net = net ?? NetService(),
      _sourceEngine = sourceEngine ?? SourceEngine(net: net);

  final NetService _net;
  final SourceEngine _sourceEngine;

  Future<ImportResult> importContent(String content, String name) async {
    final trimmed = content.trim();
    if (trimmed.isEmpty) throw Exception('导入内容为空');
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      return importTvBox(jsonDecode(trimmed));
    }
    throw Exception('仅支持 JSON 格式的 TVBox 点播配置');
  }

  Future<ImportResult> importTvBox(dynamic config) async {
    final imported = _sourceEngine.importTvBox(config);
    return ImportResult(sources: imported.sources, failures: const []);
  }

  Future<ImportResult> importUrl(String url) async {
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(url)) {
      throw Exception('仅支持 HTTP/HTTPS 地址');
    }
    final uri = Uri.parse(url);
    final name = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : '远程导入';
    return importContent(await _net.fetchRemoteText(url), name);
  }
}
