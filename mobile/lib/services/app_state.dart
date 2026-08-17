import 'package:flutter/foundation.dart';
import '../models/models.dart';
import 'storage_service.dart';
import 'local_engine.dart';
import 'system_playback_controls.dart';
import 'video_engine.dart';

/// Central app state for the on-device engine and local library.
class AppState extends ChangeNotifier {
  final StorageService _storage = StorageService();
  final VideoEngine _engine = LocalEngine();

  List<CmsSource> _sources = [];
  List<MediaItem> _favorites = [];
  List<HistoryItem> _history = [];
  String _qualityPreference = 'auto';
  bool _isEmulator = false;

  List<CmsSource> get sources => _sources;
  List<MediaItem> get favorites => _favorites;
  List<HistoryItem> get history => _history;
  String get qualityPreference => _qualityPreference;
  bool get isEmulator => _isEmulator;
  VideoEngine get engine => _engine;

  Future<void> initialize() async {
    _sources = await _storage.getSources();
    _favorites = await _storage.getFavorites();
    _history = await _storage.getHistory();
    _qualityPreference = await _storage.getQualityPreference();
    _isEmulator = await SystemPlaybackControls.isEmulator();
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
