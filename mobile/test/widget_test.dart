import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:videoget_mobile/models/models.dart';
import 'package:videoget_mobile/services/media_url.dart';
import 'package:videoget_mobile/services/quality_selector.dart';
import 'package:videoget_mobile/screens/player_screen.dart';

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
    expect(choosePlaybackStartVideoTrack(tracks, 'auto').id, 'auto');
    expect(videoTrackLabel(tracks[1]), contains('1080P'));
  });

  test('media URLs are consumed directly by the local engine', () {
    expect(resolveMediaUrl('posters/sintel.jpg'), 'posters/sintel.jpg');
    expect(
      resolveMediaUrl('https://images.example/sintel.jpg'),
      'https://images.example/sintel.jpg',
    );
  });

  test('resume policy keeps an unfinished episode without duration', () {
    final item = MediaItem(
      id: 'resume',
      sourceId: 'source',
      sourceName: 'Source',
      title: 'Resume',
      poster: '',
      category: MediaCategory.movie,
    );
    expect(
      shouldResumePlayback(
        HistoryItem(
          item: item,
          progress: 420,
          duration: 0,
          episodeName: 'Episode 1',
          watchedAt: 1,
        ),
        'Episode 1',
      ),
      isTrue,
    );
    expect(
      shouldResumePlayback(
        HistoryItem(
          item: item,
          progress: 100,
          duration: 100,
          episodeName: 'Episode 1',
          watchedAt: 1,
        ),
        'Episode 1',
      ),
      isFalse,
    );
    final resume = HistoryItem(
      item: item,
      progress: 420,
      duration: 1200,
      episodeName: 'Episode 1',
      watchedAt: 1,
    );
    expect(
      shouldApplyResumeSeek(resume, 'Episode 1', Duration.zero, Duration.zero),
      isFalse,
    );
    expect(
      shouldApplyResumeSeek(
        resume,
        'Episode 1',
        const Duration(minutes: 20),
        Duration.zero,
      ),
      isTrue,
    );
    expect(
      shouldApplyResumeSeek(
        resume,
        'Episode 1',
        Duration.zero,
        const Duration(milliseconds: 200),
      ),
      isTrue,
    );
  });

  test(
    'nearby pointer downs toggle playback only within double-tap window',
    () {
      const first = Duration(seconds: 1);
      expect(
        isPlaybackToggleDoubleTap(
          first,
          const Offset(100, 100),
          first + const Duration(milliseconds: 250),
          const Offset(118, 106),
        ),
        isTrue,
      );
      expect(
        isPlaybackToggleDoubleTap(
          first,
          const Offset(100, 100),
          first + const Duration(milliseconds: 500),
          const Offset(118, 106),
        ),
        isFalse,
      );
      expect(
        isPlaybackToggleRegion(const Offset(300, 220), const Size(600, 400)),
        isTrue,
      );
      expect(
        isPlaybackToggleRegion(const Offset(160, 90), const Size(320, 180)),
        isTrue,
      );
      expect(
        isPlaybackToggleRegion(const Offset(300, 360), const Size(600, 400)),
        isFalse,
      );
    },
  );
}
