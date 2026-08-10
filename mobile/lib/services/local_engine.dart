import '../models/models.dart';
import 'import_service.dart';
import 'iptv_catalog.dart';
import 'source_engine.dart';
import 'video_engine.dart';

class LocalEngine implements VideoEngine {
  LocalEngine({
    SourceEngine? sourceEngine,
    ImportService? importService,
    IptvCatalog? iptvCatalog,
  })  : _sourceEngine = sourceEngine ?? SourceEngine(),
        _importService = importService ?? ImportService(),
        _iptvCatalog = iptvCatalog ?? IptvCatalog();

  final SourceEngine _sourceEngine;
  final ImportService _importService;
  final IptvCatalog _iptvCatalog;

  @override
  Future<SearchResponse> search(
    String query,
    MediaCategory category,
    List<CmsSource> sources,
  ) => _sourceEngine.aggregateSearch(sources, query, category);

  @override
  Future<MediaItem?> detail(
    String sourceId,
    String id,
    List<CmsSource> sources,
  ) => _sourceEngine.getDetail(sources, sourceId, id);

  @override
  Future<MediaItem?> resolve(MediaItem item, List<CmsSource> sources) =>
      _sourceEngine.resolveMedia(sources, item);

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

  @override
  Future<ImportResult> importIptv() async {
    final lives = await _iptvCatalog.fetchIptvCatalog();
    if (lives.isEmpty) throw Exception('公开 IPTV 目录没有返回可用频道');
    return ImportResult(sources: const [], lives: lives, failures: const []);
  }
}
