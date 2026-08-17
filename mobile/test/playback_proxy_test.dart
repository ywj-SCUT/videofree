import 'package:flutter_test/flutter_test.dart';
import 'package:videoget_mobile/services/net_service.dart';
import 'package:videoget_mobile/services/playback_proxy.dart';

void main() {
  test('direct-first request uses a four-second probe when proxy exists', () {
    expect(
      upstreamAttemptTimeout(
        remaining: const Duration(seconds: 8),
        proxyAvailable: true,
        proxyPreferred: false,
        usingProxy: false,
      ),
      const Duration(seconds: 4),
    );
  });

  test('proxy attempt receives the remaining shared response budget', () {
    expect(
      upstreamAttemptTimeout(
        remaining: const Duration(seconds: 5),
        proxyAvailable: true,
        proxyPreferred: false,
        usingProxy: true,
      ),
      const Duration(seconds: 5),
    );
  });

  test('direct request without proxy receives the full response budget', () {
    expect(
      upstreamAttemptTimeout(
        remaining: const Duration(seconds: 8),
        proxyAvailable: false,
        proxyPreferred: false,
        usingProxy: false,
      ),
      const Duration(seconds: 8),
    );
  });

  test('proxy-preferred attempt reserves time for direct fallback', () {
    expect(
      upstreamAttemptTimeout(
        remaining: const Duration(seconds: 12),
        proxyAvailable: true,
        proxyPreferred: true,
        usingProxy: true,
      ),
      const Duration(seconds: 10),
    );
  });

  test('completed progressive cache resolves normal and suffix ranges', () {
    expect(resolveCachedByteRange('bytes=10-19', 100), (start: 10, end: 19));
    expect(resolveCachedByteRange('bytes=90-', 100), (start: 90, end: 99));
    expect(resolveCachedByteRange('bytes=-12', 100), (start: 88, end: 99));
    expect(resolveCachedByteRange('bytes=100-', 100), isNull);
  });

  test('progressive content range exposes resume offset and total size', () {
    expect(parseProgressiveContentRange('bytes 1048576-2097151/8388608'), (
      start: 1048576,
      end: 2097151,
      total: 8388608,
    ));
    expect(parseProgressiveContentRange('bytes */8388608'), isNull);
    expect(parseProgressiveContentRange('bytes 2-1/8'), isNull);
  });

  test('range cache only accepts matching partial content', () {
    expect(validPartialContent('bytes=10-19', 206, 'bytes 10-19/100'), isTrue);
    expect(validPartialContent('bytes=10-', 206, 'bytes 10-99/100'), isTrue);
    expect(validPartialContent('bytes=10-', 206, 'bytes 10-49/100'), isFalse);
    expect(validPartialContent('bytes=10-49', 206, 'bytes 10-39/100'), isFalse);
    expect(validPartialContent('bytes=10-200', 206, 'bytes 10-99/100'), isTrue);
    expect(validPartialContent('bytes=10-19', 200, null), isFalse);
    expect(validPartialContent('bytes=10-19', 206, 'bytes 0-99/100'), isFalse);
    expect(validPartialContent('bytes=10-', 206, 'bytes 10-99/*'), isFalse);
    expect(validPartialContent('bytes=10-19', 206, 'invalid'), isFalse);
  });

  test('upstream attempt budget clamps exhausted time to zero', () {
    expect(
      upstreamAttemptTimeout(
        remaining: const Duration(milliseconds: -1),
        proxyAvailable: true,
        proxyPreferred: false,
        usingProxy: true,
      ),
      Duration.zero,
    );
    expect(
      upstreamAttemptTimeout(
        remaining: Duration.zero,
        proxyAvailable: false,
        proxyPreferred: false,
        usingProxy: false,
      ),
      Duration.zero,
    );
  });

  test('range request waits only for an established full prefetch', () {
    final now = DateTime(2026, 8, 18, 0, 0, 10);

    expect(rangePrefetchWaitBudget(now: now, startedAt: null), Duration.zero);
    expect(
      rangePrefetchWaitBudget(
        now: now,
        startedAt: now.subtract(const Duration(seconds: 2)),
      ),
      Duration.zero,
    );
    expect(
      rangePrefetchWaitBudget(
        now: now,
        startedAt: now.subtract(const Duration(seconds: 3)),
      ),
      const Duration(milliseconds: 4500),
    );
  });

  test('timeline prefetch starts both anchor keyframe windows together', () {
    final indexes = timelinePrefetchIndexes(List.filled(360, 10.0));

    expect(indexes.take(6), [0, 1, 2, 3, 4, 5]);
    expect(indexes, containsAllInOrder([30, 60, 31, 61, 29, 59, 90, 91, 89]));
    expect(indexes.indexOf(60), lessThan(indexes.indexOf(31)));
    expect(indexes.indexOf(61), lessThan(indexes.indexOf(29)));
    expect(indexes, hasLength(24));
    expect(indexes.last, 179);
  });

  test(
    'full episode prefetch prioritizes anchors before sequential backfill',
    () {
      final indexes = fullEpisodePrefetchIndexes(List.filled(180, 4.0));

      expect(indexes, hasLength(180));
      expect(indexes.toSet(), hasLength(180));
      expect(indexes.take(12), [0, 1, 2, 3, 4, 5, 75, 150, 76, 151, 74, 149]);
      expect(indexes.indexOf(150), lessThan(indexes.indexOf(6)));
    },
  );

  test('timeline prefetch resolves media URLs and includes next segments', () {
    final manifest = [
      '#EXTM3U',
      for (var index = 0; index < 9; index++) ...[
        '#EXTINF:6,',
        'segments/$index.ts',
      ],
    ].join('\n');

    final targets = hlsTimelinePrefetchTargets(
      manifest,
      Uri.parse('https://media.example.test/path/index.m3u8'),
      openingSegmentCount: 2,
      anchorSeconds: 18,
      maxSegments: 8,
    );

    expect(targets.map((target) => target.toString()), [
      'https://media.example.test/path/segments/0.ts',
      'https://media.example.test/path/segments/1.ts',
      'https://media.example.test/path/segments/3.ts',
      'https://media.example.test/path/segments/6.ts',
      'https://media.example.test/path/segments/4.ts',
      'https://media.example.test/path/segments/7.ts',
      'https://media.example.test/path/segments/2.ts',
      'https://media.example.test/path/segments/5.ts',
    ]);
  });

  test(
    'timeline prefetch ignores a master manifest without media segments',
    () {
      const manifest = '''#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2400000
high/index.m3u8''';

      expect(
        hlsTimelinePrefetchTargets(
          manifest,
          Uri.parse('https://media.example.test/master.m3u8'),
        ),
        isEmpty,
      );
    },
  );

  test('full episode targets contain every media segment once', () {
    final manifest = [
      '#EXTM3U',
      for (var index = 0; index < 12; index++) ...[
        '#EXTINF:5,',
        'segments/$index.ts',
      ],
    ].join('\n');

    final targets = hlsFullEpisodePrefetchTargets(
      manifest,
      Uri.parse('https://media.example.test/path/index.m3u8'),
      openingSegmentCount: 2,
      prioritySegments: 6,
      anchorSeconds: 20,
    );

    expect(targets, hasLength(12));
    expect(targets.toSet(), hasLength(12));
    expect(targets[2].path, endsWith('/segments/4.ts'));
    expect(
      targets.indexWhere((target) => target.path.endsWith('/segments/4.ts')),
      lessThan(
        targets.indexWhere((target) => target.path.endsWith('/segments/2.ts')),
      ),
    );
  });

  test('first-segment warmup selection does not jump to a seek anchor', () {
    final manifest = [
      '#EXTM3U',
      for (var index = 0; index < 120; index++) ...[
        '#EXTINF:5,',
        'segments/$index.ts',
      ],
    ].join('\n');

    final targets = hlsFullEpisodePrefetchTargets(
      manifest,
      Uri.parse('https://media.example.test/path/index.m3u8'),
      openingSegmentCount: 1,
      prioritySegments: 1,
    );

    expect(targets.first.path, endsWith('/segments/0.ts'));
  });

  test('proxied manifest preference reaches cross-origin child resources', () {
    NetService.resetProxyPreferencesForTesting();
    const manifest = '''#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="https://keys.example.test/key.bin"
#EXT-X-STREAM-INF:BANDWIDTH=2400000
https://video.example.test/high/index.m3u8
#EXTINF:5,
https://segments.example.test:9443/episode/0.ts''';

    inheritHlsProxyPreference(
      manifest,
      Uri.parse('https://manifest.example.test/master.m3u8'),
    );

    expect(
      NetService.preferProxyFor(
        Uri.parse('https://keys.example.test/another-key.bin'),
      ),
      isTrue,
    );
    expect(
      NetService.preferProxyFor(
        Uri.parse('https://video.example.test/high/next.m3u8'),
      ),
      isTrue,
    );
    expect(
      NetService.preferProxyFor(
        Uri.parse('https://segments.example.test:9443/episode/1.ts'),
      ),
      isTrue,
    );
    expect(
      NetService.preferProxyFor(
        Uri.parse('https://manifest.example.test/master.m3u8'),
      ),
      isFalse,
    );
  });
}
