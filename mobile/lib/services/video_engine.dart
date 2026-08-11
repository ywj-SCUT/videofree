import '../models/models.dart';

abstract interface class VideoEngine {
  Future<SearchResponse> search(
    String query,
    MediaCategory category,
    List<CmsSource> sources,
  );

  Future<MediaItem?> detail(
    String sourceId,
    String id,
    List<CmsSource> sources,
  );

  Future<MediaItem?> resolve(MediaItem item, List<CmsSource> sources);

  Future<PlaybackResolution> play(
    String sourceId,
    String token,
    List<CmsSource> sources,
  );

  Future<ImportResult> importTvBox(dynamic config);
  Future<ImportResult> importContent(String content, String name);
  Future<ImportResult> importUrl(String url);
}
