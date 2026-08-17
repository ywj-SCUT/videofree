import '../models/models.dart';

abstract interface class VideoEngine {
  Future<SearchResponse> search(
    String query,
    MediaCategory category,
    List<CmsSource> sources, [
    int page = 1,
  ]);

  Future<MediaItem?> detail(
    String sourceId,
    String id,
    List<CmsSource> sources,
  );

  Future<MediaItem?> resolve(
    MediaItem item,
    List<CmsSource> sources, {
    String? preferredLineName,
    String? episodeName,
  });

  Future<PlaybackResolution> play(
    String sourceId,
    String token,
    List<CmsSource> sources,
  );

  Future<ImportResult> importTvBox(dynamic config);
  Future<ImportResult> importContent(String content, String name);
  Future<ImportResult> importUrl(String url);
}
