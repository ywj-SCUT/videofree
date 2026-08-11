// VideoGET shared data models - mirrors the TypeScript types.

enum MediaCategory { all, movie, series, anime, short, aiShort }

extension MediaCategoryX on MediaCategory {
  String get label {
    switch (this) {
      case MediaCategory.all:
        return '全部';
      case MediaCategory.movie:
        return '电影';
      case MediaCategory.series:
        return '电视剧';
      case MediaCategory.anime:
        return '动漫';
      case MediaCategory.short:
        return '短视频';
      case MediaCategory.aiShort:
        return 'AI 短视频';
    }
  }

  String get apiValue {
    switch (this) {
      case MediaCategory.aiShort:
        return 'ai-short';
      case MediaCategory.all:
        return 'all';
      default:
        return name;
    }
  }

  static MediaCategory fromApi(String? value) {
    switch (value) {
      case 'movie':
        return MediaCategory.movie;
      case 'series':
        return MediaCategory.series;
      case 'anime':
        return MediaCategory.anime;
      case 'short':
        return MediaCategory.short;
      case 'ai-short':
        return MediaCategory.aiShort;
      default:
        return MediaCategory.all;
    }
  }
}

class Episode {
  final String name;
  final String url;
  final String? sourceId;
  final Map<String, String>? headers;
  const Episode({
    required this.name,
    required this.url,
    this.sourceId,
    this.headers,
  });
  factory Episode.fromJson(Map<String, dynamic> json) => Episode(
    name: json['name'] as String? ?? '',
    url: json['url'] as String? ?? '',
    sourceId: json['sourceId'] as String?,
    headers: (json['headers'] as Map<String, dynamic>?)?.cast<String, String>(),
  );
  Map<String, dynamic> toJson() => {
    'name': name,
    'url': url,
    if (sourceId != null) 'sourceId': sourceId,
    if (headers != null) 'headers': headers,
  };
}

class PlayLine {
  final String name;
  final List<Episode> episodes;
  const PlayLine({required this.name, required this.episodes});
  factory PlayLine.fromJson(Map<String, dynamic> json) => PlayLine(
    name: json['name'] as String? ?? '',
    episodes: (json['episodes'] as List<dynamic>? ?? [])
        .map((e) => Episode.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
  Map<String, dynamic> toJson() => {
    'name': name,
    'episodes': episodes.map((e) => e.toJson()).toList(),
  };
}

class MediaVariant {
  final String id;
  final String sourceId;
  final String sourceName;
  const MediaVariant({
    required this.id,
    required this.sourceId,
    required this.sourceName,
  });
  factory MediaVariant.fromJson(Map<String, dynamic> json) => MediaVariant(
    id: json['id'] as String? ?? '',
    sourceId: json['sourceId'] as String? ?? '',
    sourceName: json['sourceName'] as String? ?? '',
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'sourceId': sourceId,
    'sourceName': sourceName,
  };
}

class MediaItem {
  final String id;
  final String sourceId;
  final String sourceName;
  final String title;
  final String poster;
  final String? backdrop;
  final String? year;
  final String? remarks;
  final MediaCategory category;
  final String? summary;
  final String? actors;
  final String? director;
  final String? area;
  final List<PlayLine>? playLines;
  final String? quality;
  final List<MediaVariant>? alternatives;
  const MediaItem({
    required this.id,
    required this.sourceId,
    required this.sourceName,
    required this.title,
    required this.poster,
    this.backdrop,
    this.year,
    this.remarks,
    required this.category,
    this.summary,
    this.actors,
    this.director,
    this.area,
    this.playLines,
    this.quality,
    this.alternatives,
  });
  factory MediaItem.fromJson(Map<String, dynamic> json) => MediaItem(
    id: json['id'] as String? ?? '',
    sourceId: json['sourceId'] as String? ?? '',
    sourceName: json['sourceName'] as String? ?? '',
    title: json['title'] as String? ?? '',
    poster: json['poster'] as String? ?? '',
    backdrop: json['backdrop'] as String?,
    year: json['year'] as String?,
    remarks: json['remarks'] as String?,
    category: MediaCategoryX.fromApi(json['category'] as String?),
    summary: json['summary'] as String?,
    actors: json['actors'] as String?,
    director: json['director'] as String?,
    area: json['area'] as String?,
    playLines: (json['playLines'] as List<dynamic>?)
        ?.map((e) => PlayLine.fromJson(e as Map<String, dynamic>))
        .toList(),
    quality: json['quality'] as String?,
    alternatives: (json['alternatives'] as List<dynamic>?)
        ?.map((e) => MediaVariant.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'sourceId': sourceId,
    'sourceName': sourceName,
    'title': title,
    'poster': poster,
    if (backdrop != null) 'backdrop': backdrop,
    if (year != null) 'year': year,
    if (remarks != null) 'remarks': remarks,
    'category': category.apiValue,
    if (summary != null) 'summary': summary,
    if (actors != null) 'actors': actors,
    if (director != null) 'director': director,
    if (area != null) 'area': area,
    if (playLines != null)
      'playLines': playLines!.map((e) => e.toJson()).toList(),
    if (quality != null) 'quality': quality,
    if (alternatives != null)
      'alternatives': alternatives!.map((e) => e.toJson()).toList(),
  };
}

class SourceFailure {
  final String sourceId;
  final String sourceName;
  final String message;
  const SourceFailure({
    required this.sourceId,
    required this.sourceName,
    required this.message,
  });
  factory SourceFailure.fromJson(Map<String, dynamic> json) => SourceFailure(
    sourceId: json['sourceId'] as String? ?? '',
    sourceName: json['sourceName'] as String? ?? '',
    message: json['message'] as String? ?? '',
  );
  Map<String, dynamic> toJson() => {
    'sourceId': sourceId,
    'sourceName': sourceName,
    'message': message,
  };
}

class SearchResponse {
  final List<MediaItem> items;
  final List<SourceFailure> failures;
  final int elapsedMs;
  final int page;
  final bool hasMore;
  const SearchResponse({
    required this.items,
    required this.failures,
    required this.elapsedMs,
    this.page = 1,
    this.hasMore = false,
  });
  factory SearchResponse.fromJson(Map<String, dynamic> json) => SearchResponse(
    items: (json['items'] as List<dynamic>? ?? [])
        .map((e) => MediaItem.fromJson(e as Map<String, dynamic>))
        .toList(),
    failures: (json['failures'] as List<dynamic>? ?? [])
        .map((e) => SourceFailure.fromJson(e as Map<String, dynamic>))
        .toList(),
    elapsedMs: json['elapsedMs'] as int? ?? 0,
    page: json['page'] as int? ?? 1,
    hasMore: json['hasMore'] as bool? ?? false,
  );
  Map<String, dynamic> toJson() => {
    'items': items.map((e) => e.toJson()).toList(),
    'failures': failures.map((e) => e.toJson()).toList(),
    'elapsedMs': elapsedMs,
    'page': page,
    'hasMore': hasMore,
  };
}

class PlaybackResolution {
  final String url;
  final Map<String, String>? headers;
  const PlaybackResolution({required this.url, this.headers});
  factory PlaybackResolution.fromJson(Map<String, dynamic> json) =>
      PlaybackResolution(
        url: json['url'] as String? ?? '',
        headers: (json['headers'] as Map<String, dynamic>?)
            ?.cast<String, String>(),
      );
}

class CmsSource {
  final String id;
  final String name;
  final String type;
  final String? api;
  final bool enabled;
  final bool searchable;
  final Map<String, String>? headers;
  final String? script;
  final String? scriptUrl;
  final Map<String, dynamic>? ruleConfig;
  final String? provider;
  final String? region;
  const CmsSource({
    required this.id,
    required this.name,
    required this.type,
    this.api,
    required this.enabled,
    required this.searchable,
    this.headers,
    this.script,
    this.scriptUrl,
    this.ruleConfig,
    this.provider,
    this.region,
  });
  factory CmsSource.fromJson(Map<String, dynamic> json) => CmsSource(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    type: json['type'] as String? ?? 'cms',
    api: json['api'] as String?,
    enabled: json['enabled'] as bool? ?? true,
    searchable: json['searchable'] as bool? ?? true,
    headers: (json['headers'] as Map<String, dynamic>?)?.cast<String, String>(),
    script: json['script'] as String?,
    scriptUrl: json['scriptUrl'] as String?,
    ruleConfig: json['ruleConfig'] as Map<String, dynamic>?,
    provider: json['provider'] as String?,
    region: json['region'] as String?,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'type': type,
    if (api != null) 'api': api,
    'enabled': enabled,
    'searchable': searchable,
    if (headers != null) 'headers': headers,
    if (script != null) 'script': script,
    if (scriptUrl != null) 'scriptUrl': scriptUrl,
    if (ruleConfig != null) 'ruleConfig': ruleConfig,
    if (provider != null) 'provider': provider,
    if (region != null) 'region': region,
  };
}

class HistoryItem {
  final MediaItem item;
  final String? lineName;
  final String? episodeName;
  final double progress;
  final double duration;
  final int watchedAt;
  const HistoryItem({
    required this.item,
    this.lineName,
    this.episodeName,
    required this.progress,
    required this.duration,
    required this.watchedAt,
  });
  factory HistoryItem.fromJson(Map<String, dynamic> json) => HistoryItem(
    item: MediaItem.fromJson(json),
    lineName: json['lineName'] as String?,
    episodeName: json['episodeName'] as String?,
    progress: (json['progress'] as num?)?.toDouble() ?? 0,
    duration: (json['duration'] as num?)?.toDouble() ?? 0,
    watchedAt: json['watchedAt'] as int? ?? 0,
  );
  Map<String, dynamic> toJson() => {
    ...item.toJson(),
    if (lineName != null) 'lineName': lineName,
    if (episodeName != null) 'episodeName': episodeName,
    'progress': progress,
    'duration': duration,
    'watchedAt': watchedAt,
  };
}

class ImportResult {
  final List<CmsSource> sources;
  final List<String> failures;
  const ImportResult({required this.sources, required this.failures});
  factory ImportResult.fromJson(Map<String, dynamic> json) => ImportResult(
    sources: (json['sources'] as List<dynamic>? ?? [])
        .map((e) => CmsSource.fromJson(e as Map<String, dynamic>))
        .toList(),
    failures: (json['failures'] as List<dynamic>? ?? []).cast<String>(),
  );
}
