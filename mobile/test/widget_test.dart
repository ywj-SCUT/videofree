import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:videoget_mobile/models/models.dart';
import 'package:videoget_mobile/services/quality_selector.dart';

void main() {
  test('media item JSON round trip preserves playback data', () {
    final item = MediaItem(
      id: '1',
      sourceId: 'source',
      sourceName: 'Source',
      title: 'VideoGET Test',
      poster: 'https://example.com/poster.jpg',
      category: MediaCategory.movie,
      playLines: const [
        PlayLine(
          name: '1080P',
          episodes: [
            Episode(name: 'Main', url: 'https://example.com/video.m3u8'),
          ],
        ),
      ],
    );

    final restored = MediaItem.fromJson(item.toJson());
    expect(restored.title, item.title);
    expect(restored.category, MediaCategory.movie);
    expect(
      restored.playLines?.first.episodes.first.url,
      'https://example.com/video.m3u8',
    );
  });

  test('category API values match shared contract', () {
    expect(MediaCategory.aiShort.apiValue, 'ai-short');
    expect(MediaCategoryX.fromApi('series'), MediaCategory.series);
    expect(MediaCategoryX.fromApi('unknown'), MediaCategory.all);
  });

  test('quality preference selects the expected HLS video track', () {
    const tracks = [
      VideoTrack('low', null, null, w: 1280, h: 720, bitrate: 2500000),
      VideoTrack('full-hd', null, null, w: 1920, h: 1080, bitrate: 5000000),
      VideoTrack('uhd', null, null, w: 3840, h: 2160, bitrate: 12000000),
    ];

    expect(choosePreferredVideoTrack(tracks, 'highest').id, 'uhd');
    expect(choosePreferredVideoTrack(tracks, '1080p').id, 'full-hd');
    expect(choosePreferredVideoTrack(tracks, '720p').id, 'low');
    expect(choosePreferredVideoTrack(tracks, 'auto').id, 'auto');
    expect(videoTrackLabel(tracks[1]), contains('1080P'));
  });
}
