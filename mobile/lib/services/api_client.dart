import 'package:dio/dio.dart';
import '../models/models.dart';

/// HTTP client that talks to the VideoGET Next.js API server.
/// The server URL is user-configurable; Android emulator defaults to 10.0.2.2:3000.
class ApiClient {
  final Dio _dio;
  final String baseUrl;

  ApiClient({required this.baseUrl})
    : _dio = Dio(
        BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
          headers: {'Content-Type': 'application/json'},
        ),
      );

  Future<SearchResponse> search(
    String query,
    MediaCategory category,
    List<CmsSource> sources,
  ) async {
    final response = await _dio.post(
      '/api/search',
      data: {
        'query': query,
        'category': category.apiValue,
        'sources': sources.map((s) => s.toJson()).toList(),
      },
    );
    return SearchResponse.fromJson(response.data as Map<String, dynamic>);
  }

  Future<MediaItem?> detail(
    String sourceId,
    String id,
    List<CmsSource> sources,
  ) async {
    final response = await _dio.post(
      '/api/detail',
      data: {
        'sourceId': sourceId,
        'id': id,
        'sources': sources.map((s) => s.toJson()).toList(),
      },
    );
    final data = response.data;
    if (data == null) return null;
    return MediaItem.fromJson(data as Map<String, dynamic>);
  }

  Future<MediaItem?> resolve(MediaItem item, List<CmsSource> sources) async {
    final response = await _dio.post(
      '/api/resolve',
      data: {
        'item': item.toJson(),
        'sources': sources.map((s) => s.toJson()).toList(),
      },
    );
    final data = response.data;
    if (data == null) return null;
    return MediaItem.fromJson(data as Map<String, dynamic>);
  }

  Future<PlaybackResolution> play(
    String sourceId,
    String token,
    List<CmsSource> sources,
  ) async {
    final response = await _dio.post(
      '/api/play',
      data: {
        'sourceId': sourceId,
        'token': token,
        'sources': sources.map((s) => s.toJson()).toList(),
      },
    );
    return PlaybackResolution.fromJson(response.data as Map<String, dynamic>);
  }

  Future<ImportResult> importTvBox(dynamic config) async {
    final response = await _dio.post('/api/import', data: {'config': config});
    return ImportResult.fromJson(response.data as Map<String, dynamic>);
  }

  Future<ImportResult> importContent(String content, String name) async {
    final response = await _dio.post(
      '/api/import',
      data: {'content': content, 'name': name},
    );
    return ImportResult.fromJson(response.data as Map<String, dynamic>);
  }

  Future<ImportResult> importUrl(String url) async {
    final response = await _dio.post('/api/import-url', data: {'url': url});
    return ImportResult.fromJson(response.data as Map<String, dynamic>);
  }

  Future<ImportResult> importIptv() async {
    final response = await _dio.post('/api/iptv', data: {});
    return ImportResult.fromJson(response.data as Map<String, dynamic>);
  }
}
