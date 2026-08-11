import 'dart:convert';

import '../models/models.dart';
import 'net_service.dart';
import 'spider_engine.dart';

class TvBoxImport {
  final List<CmsSource> sources;

  const TvBoxImport({required this.sources});
}

class SourceEngine {
  SourceEngine({NetService? net, SpiderRuleExecutor? spider})
    : _net = net ?? NetService(),
      _spider = spider ?? FlutterJsSpiderEngine(net: net);

  final NetService _net;
  final SpiderRuleExecutor _spider;

  static const _requestHeaders = <String, String>{
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/131 Mobile Safari/537.36',
    'Accept': 'application/json,text/plain,*/*',
  };

  MediaCategory inferMediaCategory(String typeName) {
    final text = typeName.toLowerCase();
    if ((RegExp(r'\bai\b|人工智能|aigc').hasMatch(text)) &&
        RegExp(r'短|剧|漫').hasMatch(text)) {
      return MediaCategory.aiShort;
    }
    if (RegExp(r'短剧|短视频|微剧|爽文|反转爽|女频恋爱|男频|有声剧').hasMatch(text)) {
      return MediaCategory.short;
    }
    if (RegExp(r'动漫|动画|国漫|日漫|美漫|番剧|卡通').hasMatch(text)) {
      return MediaCategory.anime;
    }
    if (RegExp(
      r'电视剧|连续剧|国产剧|港台剧|香港剧|台湾剧|日韩剧|韩剧|日剧|美剧|欧美剧|海外剧|泰剧|综艺|纪录片',
    ).hasMatch(text)) {
      return MediaCategory.series;
    }
    return MediaCategory.movie;
  }

  List<PlayLine> parsePlayLines(dynamic urls, dynamic from) {
    final groups = _text(urls).split(r'$$$').where((item) => item.isNotEmpty);
    final names = _text(from).split(r'$$$');
    final lines = <PlayLine>[];
    var lineIndex = 0;
    for (final group in groups) {
      final episodes = <Episode>[];
      var episodeIndex = 0;
      for (final entry in group.split('#')) {
        final splitAt = entry.indexOf(r'$');
        final name = splitAt < 0
            ? '第 ${episodeIndex + 1} 集'
            : (entry.substring(0, splitAt).trim().isEmpty
                  ? '第 ${episodeIndex + 1} 集'
                  : entry.substring(0, splitAt).trim());
        final url = (splitAt < 0 ? entry : entry.substring(splitAt + 1)).trim();
        if (_isHttp(url)) episodes.add(Episode(name: name, url: url));
        episodeIndex++;
      }
      if (episodes.isNotEmpty) {
        lines.add(
          PlayLine(
            name: lineIndex < names.length && names[lineIndex].isNotEmpty
                ? names[lineIndex]
                : '线路 ${lineIndex + 1}',
            episodes: episodes,
          ),
        );
      }
      lineIndex++;
    }

    int score(PlayLine line) {
      final direct = line.episodes
          .where(
            (episode) => RegExp(
              r'\.(?:m3u8|mp4)(?:$|[?#])',
              caseSensitive: false,
            ).hasMatch(episode.url),
          )
          .length;
      return direct * 10 +
          (RegExp(r'm3u8|直连|mp4', caseSensitive: false).hasMatch(line.name)
              ? 3
              : 0);
    }

    final directLines = lines.where((line) => score(line) >= 10).toList();
    final result = directLines.isNotEmpty ? directLines : lines;
    result.sort((left, right) => score(right).compareTo(score(left)));
    return result;
  }

  MediaItem normalizeVod(Map<String, dynamic> raw, CmsSource source) {
    final typeName = _text(raw['type_name'] ?? raw['vod_class']);
    return MediaItem(
      id: _text(
        raw['vod_id'] ?? raw['id'] ?? '${source.id}-${raw['vod_name']}',
      ),
      sourceId: source.id,
      sourceName: source.name,
      title: _stripHtml(raw['vod_name'] ?? raw['name']),
      poster: _text(raw['vod_pic'] ?? raw['pic']),
      year: _text(raw['vod_year']),
      remarks: _stripHtml(raw['vod_remarks'] ?? raw['note']),
      category: inferMediaCategory(typeName),
      summary: _stripHtml(raw['vod_content'] ?? raw['vod_blurb']),
      actors: _stripHtml(raw['vod_actor']),
      director: _stripHtml(raw['vod_director']),
      area: _stripHtml(raw['vod_area']),
      playLines: parsePlayLines(raw['vod_play_url'], raw['vod_play_from']),
    );
  }

  MediaItem? normalizeSpiderItem(
    dynamic raw,
    CmsSource source, {
    bool includePlayback = false,
  }) {
    final item = _map(raw);
    final id = _text(item['id'] ?? item['vod_id']);
    final title = _stripHtml(item['title'] ?? item['vod_name'] ?? item['name']);
    if (id.isEmpty || title.isEmpty) return null;
    final typeName = _text(item['type_name'] ?? item['vod_class']);
    final categoryText = _text(item['category']);
    return MediaItem(
      id: id,
      sourceId: source.id,
      sourceName: source.name,
      title: title,
      poster: _text(item['poster'] ?? item['vod_pic'] ?? item['pic']),
      backdrop: _text(item['backdrop']).isEmpty
          ? null
          : _text(item['backdrop']),
      year: _text(item['year'] ?? item['vod_year']),
      remarks: _stripHtml(
        item['remarks'] ?? item['vod_remarks'] ?? item['note'],
      ),
      category: categoryText.isEmpty
          ? inferMediaCategory(typeName)
          : MediaCategoryX.fromApi(categoryText),
      summary: _stripHtml(
        item['summary'] ?? item['vod_content'] ?? item['vod_blurb'],
      ),
      actors: _stripHtml(item['actors'] ?? item['vod_actor']),
      director: _stripHtml(item['director'] ?? item['vod_director']),
      area: _stripHtml(item['area'] ?? item['vod_area']),
      quality: _text(item['quality']).isEmpty ? null : _text(item['quality']),
      playLines: includePlayback
          ? _normalizeSpiderPlayLines(item['playLines'], source.id)
          : null,
    );
  }

  List<PlayLine> _normalizeSpiderPlayLines(dynamic raw, String sourceId) {
    if (raw is! List) return [];
    return raw
        .asMap()
        .entries
        .map((lineEntry) {
          final line = _map(lineEntry.value);
          final rawEpisodes = _rawList(line['episodes']);
          final episodes = rawEpisodes
              .asMap()
              .entries
              .map((episodeEntry) {
                final episode = _map(episodeEntry.value);
                final direct = _text(episode['url']);
                final hasToken = episode.containsKey('token');
                final url = hasToken
                    ? _encodeSpiderToken(episode['token'])
                    : direct;
                return Episode(
                  name: _text(episode['name']).isEmpty
                      ? '第 ${episodeEntry.key + 1} 集'
                      : _text(episode['name']),
                  url: url,
                  sourceId: sourceId,
                  headers: _stringMap(episode['headers']),
                );
              })
              .where(
                (episode) =>
                    _isHttp(episode.url) ||
                    episode.url.startsWith('videoget-rule:'),
              )
              .toList();
          return PlayLine(
            name: _text(line['name']).isEmpty
                ? '线路 ${lineEntry.key + 1}'
                : _text(line['name']),
            episodes: episodes,
          );
        })
        .where((line) => line.episodes.isNotEmpty)
        .toList();
  }

  Future<List<MediaItem>> searchCms(CmsSource source, String query) async {
    final api = source.api;
    if (api == null || api.isEmpty) return [];
    final data = await _fetchCmsJson(
      _cmsUrl(api, {'ac': 'videolist', 'wd': query}),
      source,
    );
    return _vodList(data).map((item) => normalizeVod(item, source)).toList();
  }

  Future<MediaItem?> detailCms(CmsSource source, String id) async {
    final api = source.api;
    if (api == null || api.isEmpty) return null;
    final data = await _fetchCmsJson(
      _cmsUrl(api, {'ac': 'videolist', 'ids': id}),
      source,
    );
    final list = _vodList(data);
    return list.isEmpty ? null : normalizeVod(list.first, source);
  }

  Future<SearchResponse> aggregateSearch(
    List<CmsSource> sources,
    String query,
    MediaCategory category,
  ) async {
    final stopwatch = Stopwatch()..start();
    final active = sources
        .where((source) => source.enabled && source.searchable)
        .toList();
    final attempts = await Future.wait(
      active.map((source) async {
        try {
          if (source.type == 'spider') {
            final raw = await _spider.search(source, query);
            final values = raw is List ? raw : _rawList(_map(raw)['items']);
            final items = values
                .map((value) => normalizeSpiderItem(value, source))
                .whereType<MediaItem>()
                .toList();
            return _SearchAttempt(source: source, items: items);
          }
          return _SearchAttempt(
            source: source,
            items: await searchCms(source, query),
          );
        } catch (error) {
          return _SearchAttempt(source: source, error: _errorText(error));
        }
      }),
    );
    final remote = attempts
        .expand((attempt) => attempt.items)
        .where(
          (item) => category == MediaCategory.all || item.category == category,
        );
    final failures = attempts
        .where((attempt) => attempt.error != null)
        .map(
          (attempt) => SourceFailure(
            sourceId: attempt.source.id,
            sourceName: attempt.source.name,
            message: attempt.error!,
          ),
        )
        .toList();
    stopwatch.stop();
    return SearchResponse(
      items: mergeMediaVariants(remote.toList()),
      failures: failures,
      elapsedMs: stopwatch.elapsedMilliseconds,
    );
  }

  List<MediaItem> mergeMediaVariants(List<MediaItem> items) {
    final groups = <String, MediaItem>{};
    for (final item in items) {
      final year =
          RegExp(r'(?:19|20)\d{2}').firstMatch(item.year ?? '')?.group(0) ?? '';
      final key = '${_canonicalTitle(item.title)}|$year';
      final existing = groups[key];
      final incoming = item.alternatives?.isNotEmpty == true
          ? item.alternatives!
          : [_variantOf(item)];
      if (existing == null) {
        groups[key] = _copyItem(item, alternatives: [...incoming]);
        continue;
      }
      final alternatives = <MediaVariant>[
        ...(existing.alternatives?.isNotEmpty == true
            ? existing.alternatives!
            : [_variantOf(existing)]),
      ];
      final known = alternatives.map((v) => '${v.sourceId}:${v.id}').toSet();
      for (final variant in incoming) {
        if (known.add('${variant.sourceId}:${variant.id}')) {
          alternatives.add(variant);
        }
      }
      groups[key] = _copyItem(
        existing,
        poster: existing.poster.isNotEmpty ? existing.poster : item.poster,
        summary: _prefer(existing.summary, item.summary),
        actors: _prefer(existing.actors, item.actors),
        director: _prefer(existing.director, item.director),
        remarks: _prefer(existing.remarks, item.remarks),
        alternatives: alternatives,
      );
    }
    return groups.values.toList();
  }

  Future<MediaItem?> getDetail(
    List<CmsSource> sources,
    String sourceId,
    String id,
  ) async {
    final source = sources.where((entry) => entry.id == sourceId).firstOrNull;
    if (source == null) return null;
    if (source.type == 'spider') {
      final raw = await _spider.detail(source, id);
      return normalizeSpiderItem(raw, source, includePlayback: true);
    }
    return detailCms(source, id);
  }

  Future<MediaItem?> resolveMedia(
    List<CmsSource> sources,
    MediaItem item,
  ) async {
    final variants = item.alternatives?.isNotEmpty == true
        ? item.alternatives!
        : [_variantOf(item)];
    final details = <MediaItem>[];
    await Future.wait(
      variants.map((variant) async {
        try {
          final detail = await getDetail(sources, variant.sourceId, variant.id);
          if (detail != null) details.add(detail);
        } catch (_) {
          // 单个来源失败不应阻止其他线路返回。
        }
      }),
    );
    if (details.isEmpty) return null;
    final playLines = details
        .expand(
          (detail) => (detail.playLines ?? const <PlayLine>[]).map(
            (line) => PlayLine(
              name: '${detail.sourceName} · ${line.name}',
              episodes: line.episodes
                  .map(
                    (episode) => Episode(
                      name: episode.name,
                      url: episode.url,
                      sourceId: episode.sourceId ?? detail.sourceId,
                      headers: episode.headers,
                    ),
                  )
                  .toList(),
            ),
          ),
        )
        .toList();
    details.sort((left, right) => _richness(right).compareTo(_richness(left)));
    final richest = details.first;
    return _copyItem(
      item,
      poster: richest.poster.isNotEmpty ? richest.poster : item.poster,
      summary: _prefer(richest.summary, item.summary),
      actors: _prefer(richest.actors, item.actors),
      director: _prefer(richest.director, item.director),
      area: _prefer(richest.area, item.area),
      remarks: _prefer(richest.remarks, item.remarks),
      alternatives: variants,
      playLines: playLines,
    );
  }

  Future<PlaybackResolution> resolvePlayback(
    List<CmsSource> sources,
    String sourceId,
    String token,
  ) async {
    if (_isHttp(token)) return PlaybackResolution(url: token);
    final source = sources.where((entry) => entry.id == sourceId).firstOrNull;
    if (source?.type != 'spider' || !token.startsWith('videoget-rule:')) {
      throw Exception('没有找到剧集对应的规则源');
    }
    final raw = await _spider.play(source!, _decodeSpiderToken(token));
    if (raw is String && _isHttp(raw)) return PlaybackResolution(url: raw);
    final result = _map(raw);
    final url = _text(result['url']);
    if (!_isHttp(url)) throw Exception('规则返回的播放地址无效');
    return PlaybackResolution(url: url, headers: _stringMap(result['headers']));
  }

  TvBoxImport importTvBox(dynamic input) {
    final config = _map(input);
    final sources = <CmsSource>[];
    final sites = _rawList(config['sites']);
    for (var index = 0; index < sites.length; index++) {
      final site = _map(sites[index]);
      final type = _number(site['type'], fallback: 1);
      final api = _text(site['api']);
      final ext = site['ext'];
      final extMap = _map(ext);
      final inlineScript = _text(extMap['script']).isNotEmpty
          ? _text(extMap['script'])
          : (ext is String &&
                    RegExp(r'(?:module\.exports|exports\.)').hasMatch(ext)
                ? ext
                : null);
      final scriptUrl = _firstHttp([
        _text(extMap['scriptUrl']),
        _text(extMap['url']),
        ext is String ? ext : '',
        type == 3 && api.endsWith('.js') ? api : '',
      ]);
      final ruleConfig = extMap['config'] is Map
          ? _map(extMap['config'])
          : null;
      if (type == 1 && _isHttp(api)) {
        sources.add(
          CmsSource(
            id: _text(site['key']).isNotEmpty
                ? _text(site['key'])
                : 'tvbox-$index',
            name: _text(site['name']).isNotEmpty
                ? _text(site['name'])
                : '视频源 ${index + 1}',
            type: 'cms',
            api: api,
            enabled: true,
            searchable: _number(site['searchable'], fallback: 1) != 0,
          ),
        );
      } else if (type == 3 && (inlineScript != null || scriptUrl != null)) {
        sources.add(
          CmsSource(
            id: _text(site['key']).isNotEmpty
                ? _text(site['key'])
                : 'spider-$index',
            name: _text(site['name']).isNotEmpty
                ? _text(site['name'])
                : '规则源 ${index + 1}',
            type: 'spider',
            script: inlineScript,
            scriptUrl: scriptUrl,
            ruleConfig: ruleConfig,
            enabled: true,
            searchable: _number(site['searchable'], fallback: 1) != 0,
          ),
        );
      }
    }
    return TvBoxImport(sources: sources);
  }

  Future<dynamic> _fetchCmsJson(String url, CmsSource source) async {
    final text = await _net.fetchRemoteText(
      url,
      headers: {..._requestHeaders, ...?source.headers},
    );
    return jsonDecode(text);
  }

  String _cmsUrl(String api, Map<String, String> params) {
    final uri = Uri.parse(api);
    return uri
        .replace(queryParameters: {...uri.queryParameters, ...params})
        .toString();
  }

  List<Map<String, dynamic>> _vodList(dynamic data) {
    final map = _map(data);
    return _rawList(map['list'] ?? map['data']).map(_map).toList();
  }

  MediaVariant _variantOf(MediaItem item) => MediaVariant(
    id: item.id,
    sourceId: item.sourceId,
    sourceName: item.sourceName,
  );

  MediaItem _copyItem(
    MediaItem item, {
    String? poster,
    String? summary,
    String? actors,
    String? director,
    String? area,
    String? remarks,
    List<PlayLine>? playLines,
    List<MediaVariant>? alternatives,
  }) {
    return MediaItem(
      id: item.id,
      sourceId: item.sourceId,
      sourceName: item.sourceName,
      title: item.title,
      poster: poster ?? item.poster,
      backdrop: item.backdrop,
      year: item.year,
      remarks: remarks ?? item.remarks,
      category: item.category,
      summary: summary ?? item.summary,
      actors: actors ?? item.actors,
      director: director ?? item.director,
      area: area ?? item.area,
      playLines: playLines ?? item.playLines,
      quality: item.quality,
      alternatives: alternatives ?? item.alternatives,
    );
  }

  String _canonicalTitle(String title) => title
      .toLowerCase()
      .replaceAll(RegExp(r'[（(]\s*(?:19|20)\d{2}\s*[）)]\s*$'), '')
      .replaceAll(RegExp(r'(?:19|20)\d{2}\s*$'), '')
      .replaceAll(RegExp(r'''[\s·•:：,，.。!！?？'"“”‘’《》【】\[\]()（）_-]+'''), '');

  int _richness(MediaItem item) =>
      (item.summary?.length ?? 0) +
      (item.poster.isNotEmpty ? 20 : 0) +
      ((item.actors?.isNotEmpty ?? false) ? 10 : 0);

  String _stripHtml(dynamic value) => _text(value)
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .trim();

  String? _prefer(String? primary, String? fallback) =>
      primary != null && primary.isNotEmpty ? primary : fallback;

  String _text(dynamic value) => value?.toString().trim() ?? '';
  bool _isHttp(String value) =>
      RegExp(r'^https?://', caseSensitive: false).hasMatch(value);
  int _number(dynamic value, {required int fallback}) =>
      int.tryParse(value?.toString() ?? '') ?? fallback;
  List<dynamic> _rawList(dynamic value) => value is List ? value : const [];
  Map<String, dynamic> _map(dynamic value) => value is Map
      ? value.map((key, item) => MapEntry(key.toString(), item))
      : <String, dynamic>{};
  String _errorText(Object error) =>
      error.toString().replaceFirst('Exception: ', '');

  String _encodeSpiderToken(dynamic value) =>
      'videoget-rule:${base64UrlEncode(utf8.encode(jsonEncode(value))).replaceAll('=', '')}';

  dynamic _decodeSpiderToken(String value) {
    final encoded = value.substring('videoget-rule:'.length);
    if (encoded.isEmpty || encoded.length > 128000) {
      throw Exception('规则播放令牌无效');
    }
    try {
      return jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(encoded))),
      );
    } catch (_) {
      throw Exception('规则播放令牌无效');
    }
  }

  Map<String, String>? _stringMap(dynamic value) {
    final map = _map(value);
    final entries = <String, String>{};
    for (final entry in map.entries) {
      final key = entry.key.trim();
      final val = _text(entry.value);
      if (key.isNotEmpty &&
          val.isNotEmpty &&
          !RegExp(r'[\r\n]').hasMatch(val)) {
        entries[key] = val;
      }
    }
    return entries.isEmpty ? null : entries;
  }

  String? _firstHttp(List<String> values) =>
      values.firstWhere((value) => _isHttp(value), orElse: () => '').isEmpty
      ? null
      : values.firstWhere((value) => _isHttp(value));
}

class _SearchAttempt {
  final CmsSource source;
  final List<MediaItem> items;
  final String? error;

  const _SearchAttempt({
    required this.source,
    this.items = const [],
    this.error,
  });
}
