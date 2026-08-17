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

  test('自动换线按集号匹配同一集', () {
    const line = PlayLine(
      name: '备用线路',
      episodes: [
        Episode(name: '第 1 集', url: 'https://example.com/1.m3u8'),
        Episode(name: '第 2 集', url: 'https://example.com/2.m3u8'),
      ],
    );

    expect(matchingEpisodeIndex(line, '第02集', 0), 1);
    expect(matchingEpisodeIndex(line, '特别篇', 1), 1);
  });

  test('首播失败会选择下一线路的同一集', () {
    const lines = [
      PlayLine(
        name: '首选线路',
        episodes: [
          Episode(name: '第1集', url: 'https://a.example.com/1.m3u8'),
          Episode(name: '第2集', url: 'https://a.example.com/2.m3u8'),
        ],
      ),
      PlayLine(
        name: '备用线路',
        episodes: [
          Episode(name: '第 1 集', url: 'https://b.example.com/1.m3u8'),
          Episode(name: '第 2 集', url: 'https://b.example.com/2.m3u8'),
        ],
      ),
    ];

    final targets = failoverTargets(lines, 0, {0}, '第2集', 1);

    expect(targets, hasLength(1));
    expect(targets.single.lineIndex, 1);
    expect(targets.single.episodeIndex, 1);
  });

  test('首播只有状态正常但未连续推进时仍触发换线', () {
    expect(
      needsStartupFailover(
        duration: const Duration(hours: 1),
        playing: true,
        buffering: true,
        continuousProgress: const Duration(seconds: 8),
      ),
      isTrue,
    );
    expect(
      needsStartupFailover(
        duration: const Duration(hours: 1),
        playing: true,
        buffering: false,
        continuousProgress: const Duration(milliseconds: 4500),
      ),
      isTrue,
    );
    expect(
      needsStartupFailover(
        duration: const Duration(hours: 1),
        playing: true,
        buffering: false,
        continuousProgress: playbackRouteHealthThreshold,
      ),
      isFalse,
    );
  });

  test('换线就绪需要累计三秒真实单调推进', () {
    var progress = Duration.zero;
    Duration? previous;
    for (var milliseconds = 0; milliseconds <= 3000; milliseconds += 500) {
      final position = Duration(milliseconds: milliseconds);
      progress = continuousPlaybackProgress(
        accumulated: progress,
        previousPosition: previous,
        position: position,
        playing: true,
        buffering: false,
      );
      previous = position;
    }

    expect(progress, playbackReadyProgressThreshold);
    expect(
      hasVerifiedPlaybackProgress(
        duration: const Duration(hours: 1),
        playing: true,
        buffering: false,
        continuousProgress: progress,
        threshold: playbackReadyProgressThreshold,
      ),
      isTrue,
    );
  });

  test('缓冲、回退和跳播会重置连续推进窗口', () {
    for (final position in [
      const Duration(seconds: 5),
      const Duration(seconds: 3),
      const Duration(seconds: 20),
    ]) {
      expect(
        continuousPlaybackProgress(
          accumulated: const Duration(seconds: 4),
          previousPosition: const Duration(seconds: 5),
          position: position,
          playing: true,
          buffering: false,
        ),
        position == const Duration(seconds: 5)
            ? const Duration(seconds: 4)
            : Duration.zero,
      );
    }
    expect(
      continuousPlaybackProgress(
        accumulated: const Duration(seconds: 4),
        previousPosition: const Duration(seconds: 5),
        position: const Duration(seconds: 6),
        playing: true,
        buffering: true,
      ),
      Duration.zero,
    );
  });

  test('播放中未报缓冲但位置停滞时触发换线', () {
    expect(
      isPlaybackProgressStalled(
        baselinePosition: const Duration(seconds: 5),
        currentPosition: const Duration(milliseconds: 5200),
        elapsed: playbackProgressStallThreshold,
        opened: true,
        playing: true,
        buffering: false,
        nearEnd: false,
      ),
      isTrue,
    );
    expect(
      isPlaybackProgressStalled(
        baselinePosition: const Duration(seconds: 5),
        currentPosition: const Duration(seconds: 6),
        elapsed: playbackProgressStallThreshold,
        opened: true,
        playing: true,
        buffering: false,
        nearEnd: false,
      ),
      isFalse,
    );
  });

  test('后台缓存只在连续稳定播放后启动', () {
    var stable = Duration.zero;
    Duration? previous;
    final thresholdSeconds = timelinePrefetchStabilityThreshold.inSeconds;
    for (var second = 1; second <= thresholdSeconds; second++) {
      final position = Duration(seconds: second);
      stable = timelinePrefetchStableDuration(
        accumulated: stable,
        previousPosition: previous,
        position: position,
        playing: true,
        buffering: false,
      );
      previous = position;
    }

    expect(stable, Duration(seconds: thresholdSeconds - 1));
    expect(stable, lessThan(timelinePrefetchStabilityThreshold));
    stable = timelinePrefetchStableDuration(
      accumulated: stable,
      previousPosition: previous,
      position: Duration(seconds: thresholdSeconds + 1),
      playing: true,
      buffering: false,
    );
    expect(stable, timelinePrefetchStabilityThreshold);
  });

  test('跳播和缓冲会重置后台缓存稳定窗口', () {
    expect(
      isTimelinePositionDiscontinuity(
        const Duration(minutes: 5),
        const Duration(minutes: 10),
      ),
      isTrue,
    );
    expect(
      timelinePrefetchStableDuration(
        accumulated: timelinePrefetchStabilityThreshold,
        previousPosition: const Duration(minutes: 5),
        position: const Duration(minutes: 10),
        playing: true,
        buffering: false,
      ),
      Duration.zero,
    );
    expect(
      timelinePrefetchStableDuration(
        accumulated: const Duration(seconds: 12),
        previousPosition: const Duration(seconds: 12),
        position: const Duration(seconds: 13),
        playing: true,
        buffering: true,
      ),
      Duration.zero,
    );
  });
}
