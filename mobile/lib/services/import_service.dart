import 'dart:convert';

import '../models/models.dart';
import 'live_engine.dart';
import 'net_service.dart';
import 'source_engine.dart';

class ImportService {
  ImportService({
    NetService? net,
    SourceEngine? sourceEngine,
    LiveEngine? liveEngine,
  })  : _net = net ?? NetService(),
        _sourceEngine = sourceEngine ?? SourceEngine(net: net),
        _liveEngine = liveEngine ?? LiveEngine();

  final NetService _net;
  final SourceEngine _sourceEngine;
  final LiveEngine _liveEngine;

  Future<ImportResult> importContent(
    String content,
    String name, {
    String? originUrl,
  }) async {
    final trimmed = content.trim();
    if (trimmed.isEmpty) throw Exception('导入内容为空');
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      return importTvBox(jsonDecode(trimmed));
    }
    final sourceName = name.isEmpty ? '导入直播' : name;
    final encoded = base64Url.encode(utf8.encode(sourceName)).replaceAll('=', '');
    final sourceId = 'playlist-${encoded.substring(0, encoded.length.clamp(0, 32))}';
    var lives = _liveEngine.parseLivePlaylist(trimmed, sourceId, sourceName);
    if (lives.isEmpty && originUrl != null && _isM3u8(originUrl)) {
      lives = [
        LiveChannel(
          id: '$sourceId-direct',
          sourceId: sourceId,
          sourceName: sourceName,
          name: sourceName,
          group: sourceName,
          url: originUrl,
          urls: [originUrl],
        ),
      ];
    }
    if (lives.isEmpty) throw Exception('未识别到 TVBox 配置或直播频道');
    return ImportResult(sources: const [], lives: lives, failures: const []);
  }

  Future<ImportResult> importTvBox(dynamic config) async {
    final imported = _sourceEngine.importTvBox(config);
    final lives = [...imported.lives];
    final failures = <String>[];
    for (final playlist in imported.livePlaylists) {
      try {
        final content = await _net.fetchRemoteText(playlist.url);
        final channels = _liveEngine.parseLivePlaylist(
          content,
          playlist.id,
          playlist.name,
        );
        if (channels.isNotEmpty) {
          lives.addAll(channels);
        } else if (_isM3u8(playlist.url)) {
          lives.add(
            LiveChannel(
              id: '${playlist.id}-direct',
              sourceId: playlist.id,
              sourceName: playlist.name,
              name: playlist.name,
              group: playlist.name,
              url: playlist.url,
              urls: [playlist.url],
            ),
          );
        } else {
          failures.add('${playlist.name}: 播放列表中没有频道');
        }
      } catch (error) {
        failures.add('${playlist.name}: ${_errorText(error)}');
      }
    }
    return ImportResult(
      sources: imported.sources,
      lives: lives,
      failures: failures,
    );
  }

  Future<ImportResult> importUrl(String url) async {
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(url)) {
      throw Exception('仅支持 HTTP/HTTPS 地址');
    }
    final uri = Uri.parse(url);
    final name = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : '远程导入';
    return importContent(
      await _net.fetchRemoteText(url),
      name,
      originUrl: url,
    );
  }

  bool _isM3u8(String value) =>
      RegExp(r'\.m3u8(?:$|\?)', caseSensitive: false).hasMatch(value);
  String _errorText(Object error) => error.toString().replaceFirst('Exception: ', '');
}
