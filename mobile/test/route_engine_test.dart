import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:videoget_mobile/models/models.dart';
import 'package:videoget_mobile/services/net_service.dart';
import 'package:videoget_mobile/services/route_engine.dart';

void main() {
  setUp(RouteEngine.resetHealthForTesting);

  test('优先选择启动快且吞吐足够的高清线路', () async {
    final engine = RouteEngine(probe: _fakeProbe);
    final ranked = await engine.rankLines([
      const PlayLine(
        name: '慢速超清',
        episodes: [Episode(name: '第1集', url: 'https://slow.test/master.m3u8')],
      ),
      const PlayLine(
        name: '快速高清',
        episodes: [Episode(name: '第1集', url: 'https://fast.test/master.m3u8')],
      ),
    ]);

    expect(ranked.first.name, '快速高清');
  });

  test('探测失败的线路排在成功线路之后', () async {
    final engine = RouteEngine(probe: _fakeProbe);
    final ranked = await engine.rankLines([
      const PlayLine(
        name: '失败线路',
        episodes: [
          Episode(name: '第1集', url: 'https://failed.test/master.m3u8'),
        ],
      ),
      const PlayLine(
        name: '可用线路',
        episodes: [Episode(name: '第1集', url: 'https://fast.test/master.m3u8')],
      ),
    ]);

    expect(ranked.first.name, '可用线路');
  });

  test('需要代理回退的线路排在稳定直连线路之后', () async {
    final engine = RouteEngine(
      probe:
          (
            String url, {
            Map<String, String>? headers,
            Duration timeout = const Duration(seconds: 3),
            int maxBytes = 256 * 1024,
          }) async => RemoteProbe(
            bytes: Uint8List(192 * 1024),
            timeToFirstByte: const Duration(milliseconds: 80),
            elapsed: Duration(milliseconds: url.contains('proxy') ? 100 : 450),
            contentType: 'video/mp4',
            finalUri: Uri.parse(url),
            usedProxy: url.contains('proxy'),
          ),
    );

    final ranked = await engine.rankLines(const [
      PlayLine(
        name: '代理回退线路',
        episodes: [Episode(name: '第1集', url: 'https://proxy.test/video.mp4')],
      ),
      PlayLine(
        name: '稳定直连线路',
        episodes: [Episode(name: '第1集', url: 'https://direct.test/video.mp4')],
      ),
    ]);

    expect(ranked.first.name, '稳定直连线路');
  });

  test('实时低延迟线路优先于已过期的历史稳定先验', () async {
    final engine = RouteEngine(
      probe:
          (
            String url, {
            Map<String, String>? headers,
            Duration timeout = const Duration(seconds: 3),
            int maxBytes = 256 * 1024,
          }) async => RemoteProbe(
            bytes: Uint8List(192 * 1024),
            timeToFirstByte: const Duration(milliseconds: 80),
            elapsed: Duration(
              milliseconds: url.contains('validated') ? 900 : 100,
            ),
            contentType: 'video/mp4',
            finalUri: Uri.parse(url),
            usedProxy: url.contains('validated'),
          ),
    );

    final ranked = await engine.rankLines(const [
      PlayLine(
        name: '短时探测较快线路',
        episodes: [Episode(name: '第1集', url: 'https://fast.test/video.mp4')],
      ),
      PlayLine(
        name: '完整播放验证线路',
        episodes: [
          Episode(
            name: '第1集',
            url: 'https://validated.test/video.mp4',
            sourceId: 'builtin-line-b',
          ),
        ],
      ),
    ]);

    expect(ranked.first.name, '短时探测较快线路');
  });

  test('完整播放验证线路实时探测失败时不会被硬置顶', () async {
    final engine = RouteEngine(
      probe:
          (
            String url, {
            Map<String, String>? headers,
            Duration timeout = const Duration(seconds: 3),
            int maxBytes = 256 * 1024,
          }) async {
            if (url.contains('validated')) throw Exception('offline');
            return RemoteProbe(
              bytes: Uint8List(192 * 1024),
              timeToFirstByte: const Duration(milliseconds: 80),
              elapsed: const Duration(milliseconds: 400),
              contentType: 'video/mp4',
              finalUri: Uri.parse(url),
            );
          },
    );

    final ranked = await engine.rankLines(const [
      PlayLine(
        name: '离线的验证线路',
        episodes: [
          Episode(
            name: '第1集',
            url: 'https://validated.test/video.mp4',
            sourceId: 'builtin-line-b',
          ),
        ],
      ),
      PlayLine(
        name: '当前可用线路',
        episodes: [
          Episode(name: '第1集', url: 'https://available.test/video.mp4'),
        ],
      ),
    ]);

    expect(ranked.first.name, '当前可用线路');
  });

  test('已实播归零的线路不会因快速 HTTP 响应置顶', () async {
    final engine = RouteEngine(
      probe:
          (
            String url, {
            Map<String, String>? headers,
            Duration timeout = const Duration(seconds: 3),
            int maxBytes = 256 * 1024,
          }) async => RemoteProbe(
            bytes: Uint8List(192 * 1024),
            timeToFirstByte: const Duration(milliseconds: 50),
            elapsed: Duration(
              milliseconds: url.contains('resetting') ? 80 : 500,
            ),
            contentType: 'video/mp4',
            finalUri: Uri.parse(url),
          ),
    );

    final ranked = await engine.rankLines(const [
      PlayLine(
        name: '实播归零线路',
        episodes: [
          Episode(
            name: '第1集',
            url: 'https://resetting.test/video.mp4',
            sourceId: 'builtin-line-g',
          ),
        ],
      ),
      PlayLine(
        name: '持续播放线路',
        episodes: [Episode(name: '第1集', url: 'https://stable.test/video.mp4')],
      ),
    ]);

    expect(ranked.first.name, '持续播放线路');
  });

  test('实时探测超时时优先当前可用线路', () async {
    final engine = RouteEngine(
      routeBudget: const Duration(milliseconds: 20),
      probe:
          (
            String url, {
            Map<String, String>? headers,
            Duration timeout = const Duration(seconds: 3),
            int maxBytes = 256 * 1024,
          }) async {
            if (url.contains('validated')) {
              await Future<void>.delayed(const Duration(milliseconds: 60));
            }
            return RemoteProbe(
              bytes: Uint8List(192 * 1024),
              timeToFirstByte: const Duration(milliseconds: 10),
              elapsed: const Duration(milliseconds: 10),
              contentType: 'video/mp4',
              finalUri: Uri.parse(url),
            );
          },
    );

    final ranked = await engine.rankLines(const [
      PlayLine(
        name: '瞬时探测成功线路',
        episodes: [Episode(name: '第1集', url: 'https://fast.test/video.mp4')],
      ),
      PlayLine(
        name: '完整播放验证线路',
        episodes: [
          Episode(
            name: '第1集',
            url: 'https://validated.test/video.mp4',
            sourceId: 'builtin-line-b',
          ),
        ],
      ),
    ]);

    expect(ranked.first.name, '瞬时探测成功线路');
  });

  test('空响应不会被记录为健康线路', () async {
    final engine = RouteEngine(
      probe:
          (
            String url, {
            Map<String, String>? headers,
            Duration timeout = const Duration(seconds: 3),
            int maxBytes = 256 * 1024,
          }) async => RemoteProbe(
            bytes: Uint8List(0),
            timeToFirstByte: const Duration(milliseconds: 20),
            elapsed: const Duration(milliseconds: 30),
            contentType: 'video/mp4',
            finalUri: Uri.parse(url),
          ),
    );

    final ranked = await engine.rankLines(const [
      PlayLine(
        name: '空响应线路',
        episodes: [Episode(name: '第1集', url: 'https://empty.test/video.mp4')],
      ),
      PlayLine(
        name: '未探测线路',
        episodes: [Episode(name: '第1集', url: 'not-http')],
      ),
    ]);

    expect(ranked.first.name, '未探测线路');
  });

  test('存在 1080p 时不探测更高码率的 4K 变体', () async {
    final requested = <String>[];
    final engine = RouteEngine(
      probe:
          (
            String url, {
            Map<String, String>? headers,
            Duration timeout = const Duration(seconds: 3),
            int maxBytes = 256 * 1024,
          }) async {
            requested.add(url);
            final uri = Uri.parse(url);
            if (url.endsWith('master.m3u8')) {
              return _probe(
                uri,
                '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=9000000,RESOLUTION=3840x2160\n4k.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=1800000,RESOLUTION=1920x1080\n1080.m3u8',
                50,
              );
            }
            if (url.endsWith('1080.m3u8')) {
              return _probe(uri, '#EXTM3U\n#EXTINF:6,\nsegment.ts', 50);
            }
            return RemoteProbe(
              bytes: Uint8List(192 * 1024),
              timeToFirstByte: const Duration(milliseconds: 50),
              elapsed: const Duration(milliseconds: 300),
              contentType: 'video/mp2t',
              finalUri: uri,
            );
          },
    );

    await engine.rankLines(const [
      PlayLine(
        name: '自适应线路',
        episodes: [
          Episode(name: '第1集', url: 'https://adaptive.test/master.m3u8'),
        ],
      ),
      PlayLine(
        name: '备用直链',
        episodes: [Episode(name: '第1集', url: 'https://backup.test/video.mp4')],
      ),
    ]);

    expect(requested, contains('https://adaptive.test/1080.m3u8'));
    expect(requested, isNot(contains('https://adaptive.test/4k.m3u8')));
  });

  test('首分片成功但第二分片失败的线路不会置顶', () async {
    final engine = RouteEngine(
      probe:
          (
            String url, {
            Map<String, String>? headers,
            Duration timeout = const Duration(seconds: 3),
            int maxBytes = 256 * 1024,
          }) async {
            final uri = Uri.parse(url);
            if (url.endsWith('.m3u8')) {
              return _probe(
                uri,
                '#EXTM3U\n#EXTINF:5,\nfirst.ts\n#EXTINF:5,\nsecond.ts',
                40,
              );
            }
            if (url.contains('opening-only.test') &&
                url.endsWith('second.ts')) {
              throw Exception('second segment unavailable');
            }
            return RemoteProbe(
              bytes: Uint8List(32 * 1024),
              timeToFirstByte: const Duration(milliseconds: 40),
              elapsed: const Duration(milliseconds: 100),
              contentType: 'video/mp2t',
              finalUri: uri,
            );
          },
    );

    final ranked = await engine.rankLines(const [
      PlayLine(
        name: '只能播放首分片',
        episodes: [
          Episode(name: '第1集', url: 'https://opening-only.test/index.m3u8'),
        ],
      ),
      PlayLine(
        name: '可连续播放',
        episodes: [Episode(name: '第1集', url: 'https://stable.test/index.m3u8')],
      ),
    ]);

    expect(ranked.first.name, '可连续播放');
  });

  test('远端分片首包快但完整下载慢的线路不会置顶', () async {
    final engine = RouteEngine(
      probe:
          (
            String url, {
            Map<String, String>? headers,
            Duration timeout = const Duration(seconds: 3),
            int maxBytes = 256 * 1024,
          }) async {
            final uri = Uri.parse(url);
            if (url.endsWith('.m3u8')) {
              return _probe(
                uri,
                '#EXTM3U\n#EXTINF:5,\nfirst.ts\n#EXTINF:5,\nsecond.ts\n'
                '#EXTINF:5,\nseek.ts',
                30,
              );
            }
            final slow = url.contains('bursty.test');
            return RemoteProbe(
              bytes: Uint8List(512 * 1024),
              timeToFirstByte: const Duration(milliseconds: 40),
              elapsed: Duration(milliseconds: slow ? 2800 : 180),
              contentType: 'video/mp2t',
              finalUri: uri,
            );
          },
    );

    final ranked = await engine.rankLines(const [
      PlayLine(
        name: '首包快但远端慢',
        episodes: [Episode(name: '第1集', url: 'https://bursty.test/index.m3u8')],
      ),
      PlayLine(
        name: '完整分片稳定',
        episodes: [Episode(name: '第1集', url: 'https://steady.test/index.m3u8')],
      ),
    ]);

    expect(ranked.first.name, '完整分片稳定');
  });

  test('第 8 条线路也会进入实测候选', () async {
    final requested = <String>[];
    final engine = RouteEngine(
      probe:
          (
            String url, {
            Map<String, String>? headers,
            Duration timeout = const Duration(seconds: 3),
            int maxBytes = 256 * 1024,
          }) async {
            requested.add(url);
            return RemoteProbe(
              bytes: Uint8List(16),
              timeToFirstByte: const Duration(milliseconds: 20),
              elapsed: const Duration(milliseconds: 30),
              contentType: 'video/mp4',
              finalUri: Uri.parse(url),
            );
          },
    );

    await engine.rankLines([
      for (var index = 0; index < 8; index++)
        PlayLine(
          name: '线路 ${index + 1}',
          episodes: [
            Episode(
              name: '第1集',
              url: 'https://line-${index + 1}.test/video.mp4',
            ),
          ],
        ),
    ]);

    expect(requested, contains('https://line-8.test/video.mp4'));
  });
}

Future<RemoteProbe> _fakeProbe(
  String url, {
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 3),
  int maxBytes = 256 * 1024,
}) async {
  if (url.contains('failed.test')) throw Exception('offline');
  final uri = Uri.parse(url);
  if (url.endsWith('master.m3u8')) {
    final slow = url.contains('slow.test');
    return _probe(
      uri,
      '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=${slow ? 8000000 : 1200000},RESOLUTION=${slow ? '3840x2160' : '1920x1080'}\nmedia.m3u8',
      slow ? 900 : 80,
    );
  }
  if (url.endsWith('media.m3u8')) {
    return _probe(uri, '#EXTM3U\n#EXTINF:6,\nsegment.ts', 70);
  }
  final slow = url.contains('slow.test');
  return RemoteProbe(
    bytes: Uint8List(192 * 1024),
    timeToFirstByte: Duration(milliseconds: slow ? 800 : 90),
    elapsed: Duration(milliseconds: slow ? 1500 : 450),
    contentType: 'video/mp2t',
    finalUri: uri,
  );
}

RemoteProbe _probe(Uri uri, String text, int elapsedMs) => RemoteProbe(
  bytes: Uint8List.fromList(utf8.encode(text)),
  timeToFirstByte: Duration(milliseconds: elapsedMs),
  elapsed: Duration(milliseconds: elapsedMs),
  contentType: 'application/vnd.apple.mpegurl',
  finalUri: uri,
);
