import '../models/models.dart';
import 'import_service.dart';
import 'source_engine.dart';
import 'video_engine.dart';

class LocalEngine implements VideoEngine {
  LocalEngine({SourceEngine? sourceEngine, ImportService? importService})
    : _sourceEngine = sourceEngine ?? SourceEngine(),
      _importService = importService ?? ImportService();

  final SourceEngine _sourceEngine;
  final ImportService _importService;

  @override
  Future<SearchResponse> search(
    String query,
    MediaCategory category,
    List<CmsSource> sources, [
    int page = 1,
  ]) => _sourceEngine.aggregateSearch(sources, query, category, page);

  @override
  Future<MediaItem?> detail(
    String sourceId,
    String id,
    List<CmsSource> sources,
  ) => _sourceEngine.getDetail(sources, sourceId, id);

  @override
  Future<MediaItem?> resolve(
    MediaItem item,
    List<CmsSource> sources, {
    String? preferredLineName,
    String? episodeName,
  }) => _sourceEngine.resolveMedia(
    sources,
    item,
    preferredLineName: preferredLineName,
    episodeName: episodeName,
  );

  @override
  Future<PlaybackResolution> play(
    String sourceId,
    String token,
    List<CmsSource> sources,
  ) => _sourceEngine.resolvePlayback(sources, sourceId, token);

  @override
  Future<ImportResult> importTvBox(dynamic config) =>
      _importService.importTvBox(config);

  @override
  Future<ImportResult> importContent(String content, String name) =>
      _importService.importContent(content, name);

  @override
  Future<ImportResult> importUrl(String url) => _importService.importUrl(url);
}
