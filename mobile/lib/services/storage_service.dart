import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';

/// Local persistence for sources, favorites, history and settings.
class StorageService {
  static const _sourcesKey = 'videoget.sources';
  static const _favoritesKey = 'videoget.favorites';
  static const _historyKey = 'videoget.history';
  static const _serverKey = 'videoget.serverUrl';
  static const _qualityKey = 'videoget.quality';
  static const _liveKey = 'videoget.liveChannels';

  static const _defaultSources = [
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
  ];

  Future<List<CmsSource>> getSources() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_sourcesKey);
    if (raw == null) {
      return _defaultSources.map((s) => CmsSource.fromJson(s)).toList();
    }
    final list = jsonDecode(raw) as List<dynamic>;
    final sources = list
        .map((s) => CmsSource.fromJson(s as Map<String, dynamic>))
        .toList();
    return sources.isEmpty
        ? _defaultSources.map((s) => CmsSource.fromJson(s)).toList()
        : sources;
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

  Future<String> getServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_serverKey) ?? 'http://10.0.2.2:3000';
  }

  Future<void> saveServerUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverKey, url);
  }

  Future<String> getQualityPreference() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_qualityKey) ?? 'highest';
  }

  Future<void> saveQualityPreference(String quality) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_qualityKey, quality);
  }

  Future<List<LiveChannel>> getLiveChannels() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_liveKey);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => LiveChannel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveLiveChannels(List<LiveChannel> channels) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _liveKey,
      jsonEncode(channels.map((e) => e.toJson()).toList()),
    );
  }
}
