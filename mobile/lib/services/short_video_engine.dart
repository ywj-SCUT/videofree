import 'dart:convert';

import '../models/models.dart';
import 'net_service.dart';

class SourceSearchPage {
  final List<MediaItem> items;
  final bool hasMore;

  const SourceSearchPage({required this.items, required this.hasMore});
}

class _CachedShortPage {
  final SourceSearchPage value;
  final DateTime storedAt;

  const _CachedShortPage({required this.value, required this.storedAt});
}

class ShortVideoEngine {
  ShortVideoEngine({NetService? net}) : _net = net ?? NetService();

  final NetService _net;
  final Map<String, List<String>> _youtubePageTokens = {};
  final Map<String, _CachedShortPage> _tikWmCache = {};
  final Map<String, Future<SourceSearchPage>> _tikWmPending = {};
  DateTime _lastTikWmRequestAt = DateTime.fromMillisecondsSinceEpoch(0);

  static const _tikWmCacheDuration = Duration(seconds: 30);
  static const _tikWmStaleDuration = Duration(minutes: 5);
  static const _tikWmMinInterval = Duration(milliseconds: 1200);

  Map<String, dynamic> _map(dynamic value) => value is Map
      ? value.map((key, item) => MapEntry(key.toString(), item))
      : <String, dynamic>{};

  String _text(dynamic value) =>
      value is String || value is num ? value.toString().trim() : '';

  dynamic _nested(dynamic value, String path) {
    dynamic current = value;
    for (final key in path.split('.')) {
      current = _map(current)[key];
    }
    return current;
  }

  String _firstUrl(Iterable<dynamic> values) {
    for (final value in values) {
      if (value is String &&
          RegExp(r'^https?://', caseSensitive: false).hasMatch(value)) {
        return value;
      }
      if (value is List) {
        final found = _firstUrl(value);
        if (found.isNotEmpty) return found;
      }
      if (value is Map) {
        final item = _map(value);
        final found = _firstUrl([
          item['url_list'],
          item['urlList'],
          item['url'],
          item['play_url'],
          item['playUrl'],
        ]);
        if (found.isNotEmpty) return found;
      }
    }
    return '';
  }

  List<dynamic> _findArray(dynamic value, Set<String> keys, [int depth = 0]) {
    if (depth > 7 || value is! Map) return const [];
    final item = _map(value);
    for (final key in keys) {
      if (item[key] is List) return item[key] as List<dynamic>;
    }
    for (final child in item.values) {
      final found = _findArray(child, keys, depth + 1);
      if (found.isNotEmpty) return found;
    }
    return const [];
  }

  String _findText(dynamic value, Set<String> keys, [int depth = 0]) {
    if (depth > 7 || value is! Map) return '';
    final item = _map(value);
    for (final key in keys) {
      final found = _text(item[key]);
      if (found.isNotEmpty) return found;
    }
    for (final child in item.values) {
      final found = _findText(child, keys, depth + 1);
      if (found.isNotEmpty) return found;
    }
    return '';
  }

  String _compactCount(dynamic value) {
    final count = num.tryParse(value?.toString() ?? '');
    if (count == null || count <= 0) return '';
    if (count >= 100000000) {
      return '${(count / 100000000).toStringAsFixed(1)} 亿播放';
    }
    if (count >= 10000) return '${(count / 10000).toStringAsFixed(1)} 万播放';
    return '${count.floor()} 播放';
  }

  List<PlayLine> _directLine(
    CmsSource source,
    String url, [
    Map<String, String>? headers,
  ]) => [
    PlayLine(
      name: source.name,
      episodes: [
        Episode(name: '短视频', url: url, sourceId: source.id, headers: headers),
      ],
    ),
  ];

  String _encodeShortToken(String provider, String videoId) =>
      'videoget-short:${base64Url.encode(utf8.encode(jsonEncode({'provider': provider, 'videoId': videoId}))).replaceAll('=', '')}';

  ({String provider, String videoId}) _decodeShortToken(String token) {
    try {
      final encoded = token.substring('videoget-short:'.length);
      final value = _map(
        jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(encoded)))),
      );
      final provider = _text(value['provider']);
      final videoId = _text(value['videoId']);
      if (provider.isEmpty || videoId.isEmpty) throw const FormatException();
      return (provider: provider, videoId: videoId);
    } catch (_) {
      throw Exception('短视频播放令牌无效');
    }
  }

  List<MediaItem> normalizeTikWmItems(dynamic payload, CmsSource source) {
    final values = _map(payload)['data'];
    if (values is! List) return [];
    final items = <MediaItem>[];
    for (final value in values) {
      final item = _map(value);
      final id = _text(item['video_id'] ?? item['id']);
      final url = _firstUrl([item['play'], item['wmplay']]);
      if (id.isEmpty || url.isEmpty) continue;
      final author = _map(item['author']);
      final authorName = _text(author['nickname'] ?? author['unique_id']);
      final duration = num.tryParse(item['duration']?.toString() ?? '');
      final metrics = <String>[
        if (duration != null && duration > 0) '${duration.round()} 秒',
        _compactCount(item['play_count']),
      ].where((value) => value.isNotEmpty).toList();
      items.add(
        MediaItem(
          id: 'tikwm-$id',
          sourceId: source.id,
          sourceName: authorName.isEmpty ? 'TikTok' : 'TikTok · $authorName',
          title: _text(item['title'] ?? item['content_desc']).isEmpty
              ? 'TikTok $id'
              : _text(item['title'] ?? item['content_desc']),
          poster: _firstUrl([
            item['cover'],
            item['origin_cover'],
            item['ai_dynamic_cover'],
          ]),
          category: MediaCategory.short,
          summary: _text(item['content_desc'] ?? item['title']),
          remarks: metrics.join(' · '),
          playLines: _directLine(source, url, {
            'Referer': 'https://www.tiktok.com/',
          }),
          quality: '自适应',
        ),
      );
    }
    return items;
  }

  List<MediaItem> normalizeTikHubItems(dynamic payload, CmsSource source) {
    final provider = source.provider ?? '';
    final platform = provider == 'tikhub-douyin'
        ? '抖音'
        : provider == 'tikhub-youtube'
        ? 'YouTube Shorts'
        : 'TikTok';
    final values = _findArray(
      payload,
      provider == 'tikhub-youtube'
          ? {'shorts', 'items', 'videos'}
          : {'aweme_list', 'awemeList', 'item_list', 'itemList', 'items'},
    );
    final items = <MediaItem>[];
    for (final value in values) {
      final item = _map(value);
      final id = _text(
        item['aweme_id'] ??
            item['awemeId'] ??
            item['video_id'] ??
            item['videoId'] ??
            item['id'],
      );
      if (id.isEmpty) continue;
      final author = _map(item['author']);
      final authorName = _text(
        author['nickname'] ??
            author['unique_id'] ??
            author['uniqueId'] ??
            item['channel_name'] ??
            item['author_name'],
      );
      final poster = _firstUrl([
        item['cover'],
        item['thumbnail'],
        item['thumbnail_url'],
        item['thumbnails'],
        _nested(item, 'video.cover'),
        _nested(item, 'video.origin_cover'),
        _nested(item, 'video.originCover'),
      ]);
      final playUrl = _firstUrl([
        item['play'],
        item['play_url'],
        item['download_url'],
        _nested(item, 'video.play_addr'),
        _nested(item, 'video.playAddr'),
        _nested(item, 'video.download_addr'),
        _nested(item, 'video.downloadAddr'),
        _nested(item, 'video.play_addr_h264'),
      ]);
      if (provider != 'tikhub-youtube' && playUrl.isEmpty) continue;
      final rawDuration = num.tryParse(
        (item['duration'] ?? _nested(item, 'video.duration'))?.toString() ?? '',
      );
      final seconds = rawDuration == null
          ? null
          : rawDuration > 1000
          ? (rawDuration / 1000).round()
          : rawDuration.round();
      final playCount =
          item['play_count'] ??
          _nested(item, 'statistics.play_count') ??
          _nested(item, 'statistics.playCount') ??
          item['views'];
      final metrics = <String>[
        if (seconds != null && seconds > 0) '$seconds 秒',
        _compactCount(playCount),
      ].where((value) => value.isNotEmpty).toList();
      items.add(
        MediaItem(
          id: '$provider-$id',
          sourceId: source.id,
          sourceName: authorName.isEmpty ? platform : '$platform · $authorName',
          title:
              _text(
                item['desc'] ?? item['title'] ?? item['video_description'],
              ).isEmpty
              ? '$platform $id'
              : _text(
                  item['desc'] ?? item['title'] ?? item['video_description'],
                ),
          poster: poster,
          category: MediaCategory.short,
          summary: _text(item['desc'] ?? item['description'] ?? item['title']),
          remarks: metrics.join(' · '),
          playLines: provider == 'tikhub-youtube'
              ? _directLine(source, _encodeShortToken(provider, id))
              : _directLine(source, playUrl, {
                  'Referer': provider == 'tikhub-tiktok'
                      ? 'https://www.tiktok.com/'
                      : 'https://www.douyin.com/',
                }),
          quality: '自适应',
        ),
      );
    }
    return items;
  }

  String _baseUrl(CmsSource source) =>
      (source.api ?? '').replaceFirst(RegExp(r'/$'), '');

  Map<String, String> _tikHubHeaders(CmsSource source) {
    final authorization =
        source.headers?['Authorization'] ??
        source.headers?['authorization'] ??
        '';
    if (!RegExp(
      r'^Bearer\s+\S+',
      caseSensitive: false,
    ).hasMatch(authorization)) {
      throw Exception('请先在设置中填写 TikHub Token');
    }
    return {
      ...?source.headers,
      'Authorization': authorization,
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };
  }

  dynamic _parsePayload(String raw) {
    final payload = jsonDecode(raw);
    final map = _map(payload);
    final code = num.tryParse(map['code']?.toString() ?? '') ?? 0;
    if (code != 0 && code != 200) {
      throw Exception(
        _text(map['message'] ?? map['msg']).isEmpty
            ? '平台接口错误 $code'
            : _text(map['message'] ?? map['msg']),
      );
    }
    return payload;
  }

  Future<SourceSearchPage> _searchTikWm(CmsSource source, int page) {
    final key = '${source.id}:${source.region ?? 'US'}:$page';
    final cached = _tikWmCache[key];
    final now = DateTime.now();
    if (cached != null &&
        now.difference(cached.storedAt) < _tikWmCacheDuration) {
      return Future.value(cached.value);
    }
    return _tikWmPending.putIfAbsent(key, () async {
      final sinceLastRequest = DateTime.now().difference(_lastTikWmRequestAt);
      if (sinceLastRequest < _tikWmMinInterval) {
        await Future<void>.delayed(_tikWmMinInterval - sinceLastRequest);
      }
      _lastTikWmRequestAt = DateTime.now();
      final parameters = <String, String>{
        'region': source.region ?? 'US',
        'count': '12',
        if (page > 1) 'cursor': '${(page - 1) * 12}',
      };
      final uri = Uri.parse(
        '${_baseUrl(source)}/api/feed/list',
      ).replace(queryParameters: parameters);
      try {
        final payload = _parsePayload(
          await _net.fetchRemoteText(
            uri.toString(),
            timeout: const Duration(seconds: 20),
          ),
        );
        final items = normalizeTikWmItems(payload, source);
        final value = SourceSearchPage(items: items, hasMore: items.isNotEmpty);
        _tikWmCache[key] = _CachedShortPage(
          value: value,
          storedAt: DateTime.now(),
        );
        return value;
      } catch (_) {
        if (cached != null &&
            now.difference(cached.storedAt) < _tikWmStaleDuration) {
          return cached.value;
        }
        rethrow;
      } finally {
        _tikWmPending.remove(key);
      }
    });
  }

  Future<SourceSearchPage> search(
    CmsSource source,
    String query,
    int page,
  ) async {
    final provider = source.provider;
    if (provider == null || provider.isEmpty || source.api == null) {
      return const SourceSearchPage(items: [], hasMore: false);
    }
    if (provider == 'tikwm') {
      return _searchTikWm(source, page);
    }

    final headers = _tikHubHeaders(source);
    if (provider == 'tikhub-douyin') {
      final payload = _parsePayload(
        await _net.fetchRemoteText(
          '${_baseUrl(source)}/api/v1/douyin/web/fetch_home_feed',
          method: 'POST',
          headers: headers,
          body: jsonEncode({'count': 10, 'refresh_index': page - 1}),
          timeout: const Duration(seconds: 30),
        ),
      );
      final items = normalizeTikHubItems(payload, source);
      return SourceSearchPage(items: items, hasMore: items.isNotEmpty);
    }
    if (provider == 'tikhub-tiktok') {
      final payload = _parsePayload(
        await _net.fetchRemoteText(
          '${_baseUrl(source)}/api/v1/tiktok/web/fetch_home_feed',
          method: 'POST',
          headers: headers,
          body: jsonEncode({'count': 15, 'region': source.region ?? 'US'}),
          timeout: const Duration(seconds: 30),
        ),
      );
      final items = normalizeTikHubItems(payload, source);
      return SourceSearchPage(items: items, hasMore: items.isNotEmpty);
    }

    final key = '${source.id}:${query.trim().isEmpty ? '热门' : query.trim()}';
    final tokens = _youtubePageTokens.putIfAbsent(key, () => ['']);
    if (page > 1 && (tokens.length <= page - 1 || tokens[page - 1].isEmpty)) {
      return const SourceSearchPage(items: [], hasMore: false);
    }
    final parameters = <String, String>{
      'keyword': query.trim().isEmpty ? '热门' : query.trim(),
      'sort_by': 'view_count',
      if (page > 1) 'continuation_token': tokens[page - 1],
    };
    final uri = Uri.parse(
      '${_baseUrl(source)}/api/v1/youtube/web_v2/get_shorts_search_v2',
    ).replace(queryParameters: parameters);
    final payload = _parsePayload(
      await _net.fetchRemoteText(
        uri.toString(),
        headers: headers,
        timeout: const Duration(seconds: 30),
      ),
    );
    final nextToken = _findText(payload, {
      'continuation_token',
      'continuationToken',
      'nextpage',
      'nextPageToken',
    });
    while (tokens.length <= page) {
      tokens.add('');
    }
    tokens[page] = nextToken;
    return SourceSearchPage(
      items: normalizeTikHubItems(payload, source),
      hasMore: nextToken.isNotEmpty,
    );
  }

  Future<PlaybackResolution> resolvePlayback(
    CmsSource source,
    String token,
  ) async {
    final decoded = _decodeShortToken(token);
    if (decoded.provider != 'tikhub-youtube' ||
        source.provider != decoded.provider) {
      throw Exception('短视频播放来源不匹配');
    }
    final uri = Uri.parse(
      '${_baseUrl(source)}/api/v1/youtube/web_v2/get_video_streams_v2',
    ).replace(queryParameters: {'video_id': decoded.videoId});
    final payload = _parsePayload(
      await _net.fetchRemoteText(
        uri.toString(),
        headers: _tikHubHeaders(source),
        timeout: const Duration(seconds: 45),
      ),
    );
    final formats = _findArray(payload, {
      'formats',
    }).map(_map).where((item) => _firstUrl([item['url']]).isNotEmpty).toList();
    formats.sort((left, right) {
      final leftScore =
          num.tryParse((left['height'] ?? left['bitrate'])?.toString() ?? '') ??
          0;
      final rightScore =
          num.tryParse(
            (right['height'] ?? right['bitrate'])?.toString() ?? '',
          ) ??
          0;
      return rightScore.compareTo(leftScore);
    });
    final stream = _firstUrl([
      if (formats.isNotEmpty) formats.first['url'],
      _findText(payload, {'hls_manifest_url', 'hlsManifestUrl'}),
    ]);
    if (stream.isEmpty) throw Exception('YouTube Shorts 没有可用的音视频合并流');
    return PlaybackResolution(url: stream);
  }
}
