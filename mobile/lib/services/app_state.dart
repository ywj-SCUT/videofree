import 'package:flutter/foundation.dart';
import '../models/models.dart';
import 'storage_service.dart';
import 'api_client.dart';

/// Central app state: sources, favorites, history, live channels, server config.
class AppState extends ChangeNotifier {
  final StorageService _storage = StorageService();
  ApiClient? _api;

  List<CmsSource> _sources = [];
  List<MediaItem> _favorites = [];
  List<HistoryItem> _history = [];
  List<LiveChannel> _liveChannels = [];
  String _serverUrl = 'http://10.0.2.2:3000';
  String _qualityPreference = 'highest';

  List<CmsSource> get sources => _sources;
  List<MediaItem> get favorites => _favorites;
  List<HistoryItem> get history => _history;
  List<LiveChannel> get liveChannels => _liveChannels;
  String get serverUrl => _serverUrl;
  String get qualityPreference => _qualityPreference;
  ApiClient get api => _api ??= ApiClient(baseUrl: _serverUrl);

  Future<void> initialize() async {
    _serverUrl = await _storage.getServerUrl();
    _api = ApiClient(baseUrl: _serverUrl);
    _sources = await _storage.getSources();
    _favorites = await _storage.getFavorites();
    _history = await _storage.getHistory();
    _liveChannels = await _storage.getLiveChannels();
    _qualityPreference = await _storage.getQualityPreference();
    notifyListeners();
  }

  Future<void> updateServerUrl(String url) async {
    _serverUrl = url;
    _api = ApiClient(baseUrl: url);
    await _storage.saveServerUrl(url);
    notifyListeners();
  }

  Future<void> updateQualityPreference(String quality) async {
    _qualityPreference = quality;
    await _storage.saveQualityPreference(quality);
    notifyListeners();
  }

  Future<void> updateSources(List<CmsSource> sources) async {
    _sources = sources;
    await _storage.saveSources(sources);
    notifyListeners();
  }

  Future<void> toggleFavorite(MediaItem item) async {
    final exists = _favorites.any(
      (f) => f.id == item.id && f.sourceId == item.sourceId,
    );
    if (exists) {
      _favorites.removeWhere(
        (f) => f.id == item.id && f.sourceId == item.sourceId,
      );
    } else {
      _favorites.insert(0, item);
    }
    await _storage.saveFavorites(_favorites);
    notifyListeners();
  }

  bool isFavorite(String sourceId, String id) {
    return _favorites.any((f) => f.id == id && f.sourceId == sourceId);
  }

  Future<void> updateProgress(
    MediaItem item,
    double progress,
    double duration,
    String lineName,
    String episodeName,
  ) async {
    _history.removeWhere(
      (h) => h.item.id == item.id && h.item.sourceId == item.sourceId,
    );
    _history.insert(
      0,
      HistoryItem(
        item: item,
        progress: progress,
        duration: duration,
        lineName: lineName,
        episodeName: episodeName,
        watchedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (_history.length > 100) _history = _history.sublist(0, 100);
    await _storage.saveHistory(_history);
    notifyListeners();
  }

  Future<void> clearHistory() async {
    _history = [];
    await _storage.saveHistory(_history);
    notifyListeners();
  }

  Future<void> setLiveChannels(List<LiveChannel> channels) async {
    _liveChannels = channels;
    await _storage.saveLiveChannels(channels);
    notifyListeners();
  }

  Future<void> mergeImportedSources(List<CmsSource> imported) async {
    final map = {for (var s in _sources) s.id: s};
    for (final s in imported) {
      map[s.id] = s;
    }
    await updateSources(map.values.toList());
  }

  HistoryItem? getResume(MediaItem item) {
    for (final h in _history) {
      if (h.item.id == item.id && h.item.sourceId == item.sourceId) return h;
    }
    return null;
  }
}
