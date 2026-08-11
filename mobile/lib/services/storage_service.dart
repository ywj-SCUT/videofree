import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';

/// Local persistence for sources, favorites, history and settings.
class StorageService {
  static const _sourcesKey = 'videoget.sources';
  static const _favoritesKey = 'videoget.favorites';
  static const _historyKey = 'videoget.history';
  static const _qualityKey = 'videoget.quality';

  static const _defaultSources = [
    {
      'id': 'builtin-short-tikhub-tiktok',
      'name': 'TikTok 推荐',
      'type': 'short-api',
      'api': 'https://api.tikhub.io',
      'provider': 'tikhub-tiktok',
      'region': 'US',
      'enabled': false,
      'searchable': true,
    },
    {
      'id': 'builtin-short-douyin',
      'name': '抖音推荐',
      'type': 'short-api',
      'api': 'https://api.tikhub.io',
      'provider': 'tikhub-douyin',
      'region': 'CN',
      'enabled': false,
      'searchable': true,
    },
    {
      'id': 'builtin-short-youtube',
      'name': 'YouTube Shorts',
      'type': 'short-api',
      'api': 'https://api.tikhub.io',
      'provider': 'tikhub-youtube',
      'region': 'CN',
      'enabled': false,
      'searchable': true,
    },
    {
      'id': 'builtin-line-a',
      'name': '默认线路 A',
      'type': 'cms',
      'api': 'https://caiji.moduapi.cc/api.php/provide/vod/',
      'enabled': true,
      'searchable': true,
    },
    {
      'id': 'builtin-line-b',
      'name': '默认线路 B',
      'type': 'cms',
      'api': 'https://jszyapi.com/api.php/provide/vod/',
      'enabled': true,
      'searchable': true,
    },
    {
      'id': 'builtin-line-c',
      'name': '默认线路 C',
      'type': 'cms',
      'api': 'https://cj.lziapi.com/api.php/provide/vod/',
      'enabled': true,
      'searchable': true,
    },
    {
      'id': 'builtin-line-d',
      'name': '默认线路 D',
      'type': 'cms',
      'api': 'https://api.ukuapi.com/api.php/provide/vod/',
      'enabled': true,
      'searchable': true,
    },
    {
      'id': 'builtin-line-e',
      'name': '默认线路 E',
      'type': 'cms',
      'api': 'https://api.wujinapi.me/api.php/provide/vod/',
      'enabled': true,
      'searchable': true,
    },
    {
      'id': 'builtin-line-f',
      'name': '默认线路 F',
      'type': 'cms',
      'api': 'https://cj.rycjapi.com/api.php/provide/vod/',
      'enabled': true,
      'searchable': true,
    },
  ];

  Future<List<CmsSource>> getSources() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_sourcesKey);
    if (raw == null) {
      return _defaultSources.map((s) => CmsSource.fromJson(s)).toList();
    }
    final list = jsonDecode(raw) as List<dynamic>;
    final persisted = list
        .map((s) => CmsSource.fromJson(s as Map<String, dynamic>))
        .toList();
    final byId = {for (final source in persisted) source.id: source.toJson()};
    final managed = _defaultSources
        .map(
          (source) => CmsSource.fromJson({...source, ...?byId[source['id']]}),
        )
        .toList();
    final custom = persisted
        .where((source) => !source.id.startsWith('builtin-'))
        .toList();
    return [...managed, ...custom];
  }

  Future<void> saveSources(List<CmsSource> sources) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _sourcesKey,
      jsonEncode(sources.map((s) => s.toJson()).toList()),
    );
  }

  Future<List<MediaItem>> getFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_favoritesKey);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => MediaItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveFavorites(List<MediaItem> favorites) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _favoritesKey,
      jsonEncode(favorites.map((e) => e.toJson()).toList()),
    );
  }

  Future<List<HistoryItem>> getHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_historyKey);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => HistoryItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveHistory(List<HistoryItem> history) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _historyKey,
      jsonEncode(history.map((e) => e.toJson()).toList()),
    );
  }

  Future<String> getQualityPreference() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_qualityKey) ?? 'highest';
  }

  Future<void> saveQualityPreference(String quality) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_qualityKey, quality);
  }
}
