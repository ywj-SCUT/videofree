import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:videoget_mobile/models/models.dart';
import 'package:videoget_mobile/services/net_service.dart';
import 'package:videoget_mobile/services/route_engine.dart';
import 'package:videoget_mobile/services/short_video_engine.dart';
import 'package:videoget_mobile/services/source_engine.dart';
import 'package:videoget_mobile/services/spider_engine.dart';

const _url = 'https://stream.example.com/ep.m3u8';
const _url2 = 'https://stream.example.com/ep2.mp4';
const _sep = r'$$$';
const _d = r'$';

void main() {
  final spider = _FakeSpiderRuleExecutor();
  final engine = SourceEngine(spider: spider);
  final source = CmsSource(
    id: 'test-cms',
    name: '测试源',
    type: 'cms',
    api: 'https://example.com/api.php/provide/vod/',
    enabled: true,
    searchable: true,
  );

  group('inferMediaCategory', () {
    test('识别动漫', () {
      expect(engine.inferMediaCategory('动漫'), MediaCategory.anime);
      expect(engine.inferMediaCategory('国产动画'), MediaCategory.anime);
    });

    test('识别电视剧', () {
      expect(engine.inferMediaCategory('电视剧'), MediaCategory.series);
      expect(engine.inferMediaCategory('韩剧'), MediaCategory.series);
      expect(engine.inferMediaCategory('美剧'), MediaCategory.series);
      expect(engine.inferMediaCategory('综艺'), MediaCategory.series);
    });

    test('识别短视频', () {
      expect(engine.inferMediaCategory('短视频'), MediaCategory.short);
      expect(engine.inferMediaCategory('微剧'), MediaCategory.short);
    });

    test('识别 AI 短视频', () {
      expect(engine.inferMediaCategory('AI 短视频'), MediaCategory.aiShort);
    });

    test('默认电影', () {
      expect(engine.inferMediaCategory('动作片'), MediaCategory.movie);
    });
  });

  group('parsePlayLines', () {
    test('解析多线路多集数', () {
      final lines = engine.parsePlayLines(
        '第1集$_d$_url#第2集$_d$_url$_sep线路2第1集$_d$_url2',
        '线路1$_sep线路2',
      );
      expect(lines, hasLength(2));
      expect(lines[0].name, '线路1');
      expect(lines[0].episodes, hasLength(2));
      expect(lines[1].name, '线路2');
      expect(lines[1].episodes, hasLength(1));
    });

    test('过滤非 HTTP 的集数', () {
      final lines = engine.parsePlayLines('第1集/bad-url#第2集$_d$_url', '');
      expect(lines, hasLength(1));
      expect(lines.first.episodes, hasLength(1));
    });

    test('空输入返回空列表', () {
      expect(engine.parsePlayLines('', ''), isEmpty);
    });
  });

  group('normalizeVod', () {
    test('完整字段映射', () {
      final item = engine.normalizeVod({
        'vod_id': 42,
        'vod_name': '<b>测试电影</b>',
        'vod_pic': 'https://img.example.com/p.jpg',
        'vod_year': '2024',
        'vod_remarks': 'HD',
        'type_name': '电视剧',
        'vod_content': '剧情简介',
        'vod_actor': '演员A,演员B',
        'vod_director': '导演X',
        'vod_area': '大陆',
        'vod_play_url': '第1集$_d$_url#第2集$_d$_url',
        'vod_play_from': '线路1',
      }, source);
      expect(item.id, '42');
      expect(item.title, '测试电影');
      expect(item.poster, 'https://img.example.com/p.jpg');
      expect(item.year, '2024');
      expect(item.remarks, 'HD');
      expect(item.category, MediaCategory.series);
      expect(item.summary, '剧情简介');
      expect(item.actors, '演员A,演员B');
      expect(item.director, '导演X');
      expect(item.area, '大陆');
      expect(item.playLines, hasLength(1));
      expect(item.playLines!.first.episodes, hasLength(2));
    });
  });

  group('mergeMediaVariants', () {
    test('跨源同名合并', () {
      final item1 = MediaItem(
        id: 'a1',
        sourceId: 'src-a',
        sourceName: '源A',
        title: '同一部电影',
        poster: 'https://img.example.com/a.jpg',
        category: MediaCategory.movie,
        year: '2024',
      );
      final item2 = MediaItem(
        id: 'b1',
        sourceId: 'src-b',
        sourceName: '源B',
        title: '同一部电影',
        poster: '',
        category: MediaCategory.movie,
        year: '2024',
      );
      final result = engine.mergeMediaVariants([item1, item2]);
      expect(result, hasLength(1));
      expect(result.first.alternatives, hasLength(2));
      expect(result.first.poster, 'https://img.example.com/a.jpg');
    });

    test('同名不同年份保持分组并优先完整实播来源', () {
      final older = MediaItem(
        id: 'older',
        sourceId: 'builtin-line-a',
        sourceName: '源A',
        title: '同名剧集',
        poster: '',
        category: MediaCategory.series,
        year: '2024',
      );
      final validated = MediaItem(
        id: 'validated',
        sourceId: 'builtin-line-b',
        sourceName: '源B',
        title: '同名剧集',
        poster: '',
        category: MediaCategory.series,
        year: '2025',
      );

      final result = engine.mergeMediaVariants([older, validated]);

      expect(result, hasLength(2));
      expect(result.first.sourceId, 'builtin-line-b');
      expect(result.first.year, '2025');
    });
  });

  test('详情聚合不会被超时来源拖住', () async {
    final boundedEngine = _DelayedDetailEngine();
    final item = MediaItem(
      id: 'fast-id',
      sourceId: 'fast',
      sourceName: '快速源',
      title: '测试剧集',
      poster: '',
      category: MediaCategory.series,
      alternatives: const [
        MediaVariant(id: 'fast-id', sourceId: 'fast', sourceName: '快速源'),
        MediaVariant(id: 'slow-id', sourceId: 'slow', sourceName: '慢速源'),
      ],
    );
    final stopwatch = Stopwatch()..start();

    final detail = await boundedEngine.resolveMedia(const [], item);

    stopwatch.stop();
    expect(detail?.playLines, hasLength(1));
    expect(detail?.playLines?.single.name, startsWith('快速源'));
    expect(stopwatch.elapsedMilliseconds, lessThan(180));
  });

  test('聚合搜索不会被单个慢源拖住', () async {
    final boundedEngine = _DelayedSearchEngine();
    final stopwatch = Stopwatch()..start();

    final response = await boundedEngine.aggregateSearch(
      const [
        CmsSource(
          id: 'slow',
          name: '慢速源',
          type: 'cms',
          enabled: true,
          searchable: true,
        ),
      ],
      '测试',
      MediaCategory.series,
    );

    stopwatch.stop();
    expect(response.items, isEmpty);
    expect(response.failures.single.sourceId, 'slow');
    expect(stopwatch.elapsedMilliseconds, lessThan(180));
  });

  test('B 来源搜索使用独立预算', () async {
    final boundedEngine = _DelayedSearchEngine();

    final response = await boundedEngine.aggregateSearch(
      const [
        CmsSource(
          id: 'builtin-line-b',
          name: 'B 来源',
          type: 'cms',
          enabled: true,
          searchable: true,
        ),
      ],
      '测试',
      MediaCategory.series,
    );

    expect(response.failures, isEmpty);
    expect(response.items.single.sourceId, 'builtin-line-b');
  });

  test('B 来源详情使用独立预算', () async {
    final boundedEngine = _DelayedDetailEngine();
    const item = MediaItem(
      id: 'b-id',
      sourceId: 'builtin-line-b',
      sourceName: 'B 来源',
      title: '测试剧集',
      poster: '',
      category: MediaCategory.series,
    );

    final detail = await boundedEngine.resolveMedia(const [], item);

    expect(detail?.sourceId, 'builtin-line-b');
    expect(detail?.playLines, hasLength(1));
  });

  test('内置 H 来源详情使用与 B 相同的预算', () async {
    final boundedEngine = _DelayedDetailEngine();
    const item = MediaItem(
      id: 'h-id',
      sourceId: 'builtin-line-h',
      sourceName: 'H 来源',
      title: '测试剧集',
      poster: '',
      category: MediaCategory.series,
    );

    final detail = await boundedEngine.resolveMedia(const [], item);

    expect(detail?.sourceId, 'builtin-line-h');
    expect(detail?.playLines, hasLength(1));
  });

  test('详情完成后的线路探测也受整体预算约束', () async {
    final routes = RouteEngine(
      probeTimeout: const Duration(milliseconds: 30),
      routeBudget: const Duration(milliseconds: 60),
      probe:
          (
            String url, {
            Map<String, String>? headers,
            Duration timeout = const Duration(seconds: 3),
            int maxBytes = 256 * 1024,
          }) async {
            await Future<void>.delayed(const Duration(milliseconds: 300));
            return RemoteProbe(
              bytes: Uint8List(1),
              timeToFirstByte: const Duration(milliseconds: 300),
              elapsed: const Duration(milliseconds: 300),
              contentType: 'video/mp2t',
              finalUri: Uri.parse(url),
            );
          },
    );
    final boundedEngine = _BudgetedResolveEngine(routes);
    final item = MediaItem(
      id: 'a-id',
      sourceId: 'a',
      sourceName: '来源 A',
      title: '测试剧集',
      poster: '',
      category: MediaCategory.series,
      alternatives: const [
        MediaVariant(id: 'a-id', sourceId: 'a', sourceName: '来源 A'),
        MediaVariant(id: 'b-id', sourceId: 'b', sourceName: '来源 B'),
      ],
    );
    final stopwatch = Stopwatch()..start();

    final detail = await boundedEngine.resolveMedia(const [], item);

    stopwatch.stop();
    expect(detail?.playLines, hasLength(2));
    expect(stopwatch.elapsedMilliseconds, lessThan(180));
  });

  group('短视频平台来源隔离', () {
    test('短视频分类只查询 short-api 来源', () async {
      final filteredSpider = _FakeSpiderRuleExecutor();
      final shorts = _FakeShortVideoEngine();
      final filteredEngine = SourceEngine(
        spider: filteredSpider,
        shorts: shorts,
      );
      final response = await filteredEngine.aggregateSearch(
        [
          const CmsSource(
            id: 'cms-short',
            name: '普通点播源',
            type: 'spider',
            enabled: true,
            searchable: true,
          ),
          const CmsSource(
            id: 'platform-short',
            name: '平台短视频',
            type: 'short-api',
            api: 'https://api.example.com',
            provider: 'tikhub-tiktok',
            enabled: true,
            searchable: true,
          ),
        ],
        '',
        MediaCategory.short,
      );

      expect(filteredSpider.searchCalls, 0);
      expect(shorts.searchCalls, 1);
      expect(response.items, hasLength(1));
      expect(response.items.single.sourceId, 'platform-short');
    });

    test('AI 短视频分类不会查询平台来源', () async {
      final shorts = _FakeShortVideoEngine();
      final filteredEngine = SourceEngine(shorts: shorts);
      final response = await filteredEngine.aggregateSearch(
        [
          const CmsSource(
            id: 'platform-short',
            name: '平台短视频',
            type: 'short-api',
            api: 'https://api.example.com',
            provider: 'tikhub-tiktok',
            enabled: true,
            searchable: true,
          ),
        ],
        '',
        MediaCategory.aiShort,
      );

      expect(shorts.searchCalls, 0);
      expect(response.items, isEmpty);
    });
  });

  group('importTvBox', () {
    test('解析 type=1 CMS 和 type=3 Spider 源', () {
      final imported = engine.importTvBox({
        'sites': [
          {
            'key': 'a',
            'name': '源A',
            'type': 1,
            'api': 'https://cms.example.com/api',
            'searchable': 1,
          },
          {
            'key': 'b',
            'name': '源B',
            'type': 3,
            'api': 'https://spider.example.com/x.js',
            'ext': {
              'scriptUrl': 'https://spider.example.com/x.js',
              'config': {'region': 'us'},
            },
          },
        ],
      });
      expect(imported.sources, hasLength(2));
      expect(imported.sources.first.id, 'a');
      expect(imported.sources.first.type, 'cms');
      expect(imported.sources.last.type, 'spider');
      expect(
        imported.sources.last.scriptUrl,
        'https://spider.example.com/x.js',
      );
      expect(imported.sources.last.ruleConfig, {'region': 'us'});
    });
  });

  group('Spider 本地规则链路', () {
    final source = CmsSource(
      id: 'test-spider',
      name: '规则源',
      type: 'spider',
      script: 'module.exports = {};',
      enabled: true,
      searchable: true,
    );

    test('搜索并按分类聚合', () async {
      final response = await engine.aggregateSearch(
        [source],
        '测试美剧',
        MediaCategory.series,
      );
      expect(response.failures, isEmpty);
      expect(response.items, hasLength(1));
      expect(response.items.first.title, '测试美剧');
      expect(response.items.first.category, MediaCategory.series);
    });

    test('详情令牌交给 Spider play 解析', () async {
      final detail = await engine.getDetail([source], source.id, 'spider-1');
      expect(detail, isNotNull);
      final episode = detail!.playLines!.single.episodes.single;
      expect(episode.url, startsWith('videoget-rule:'));

      final playback = await engine.resolvePlayback(
        [source],
        source.id,
        episode.url,
      );
      expect(playback.url, _url);
      expect(playback.headers, {'Referer': 'https://example.com/'});
      expect(spider.lastToken, {'episode': 1});
    });
  });
}

class _FakeSpiderRuleExecutor implements SpiderRuleExecutor {
  dynamic lastToken;
  int searchCalls = 0;

  @override
  Future<dynamic> search(CmsSource source, String query, [int page = 1]) async {
    searchCalls++;
    return [
      {
        'id': 'spider-1',
        'title': query,
        'category': 'series',
        'poster': 'https://img.example.com/spider.jpg',
      },
    ];
  }

  @override
  Future<dynamic> detail(CmsSource source, String id) async => {
    'id': id,
    'title': '测试美剧',
    'category': 'series',
    'playLines': [
      {
        'name': '规则线路',
        'episodes': [
          {
            'name': '第 1 集',
            'token': {'episode': 1},
          },
        ],
      },
    ],
  };

  @override
  Future<dynamic> play(CmsSource source, dynamic token) async {
    lastToken = token;
    return {
      'url': _url,
      'headers': {'Referer': 'https://example.com/'},
    };
  }
}

class _FakeShortVideoEngine extends ShortVideoEngine {
  int searchCalls = 0;

  @override
  Future<SourceSearchPage> search(
    CmsSource source,
    String query,
    int page,
  ) async {
    searchCalls++;
    return SourceSearchPage(
      items: [
        MediaItem(
          id: 'real-short-1',
          sourceId: source.id,
          sourceName: source.name,
          title: '平台真实作品',
          poster: 'https://img.example.com/short.jpg',
          category: MediaCategory.short,
        ),
      ],
      hasMore: false,
    );
  }
}

class _DelayedDetailEngine extends SourceEngine {
  _DelayedDetailEngine()
    : super(detailTimeout: const Duration(milliseconds: 40));

  @override
  Future<MediaItem?> getDetail(
    List<CmsSource> sources,
    String sourceId,
    String id,
  ) async {
    await Future<void>.delayed(
      Duration(
        milliseconds:
            sourceId == 'slow' ||
                sourceId == 'builtin-line-b' ||
                sourceId == 'builtin-line-h'
            ? 220
            : 5,
      ),
    );
    return MediaItem(
      id: id,
      sourceId: sourceId,
      sourceName: sourceId == 'slow' ? '慢速源' : '快速源',
      title: '测试剧集',
      poster: '',
      category: MediaCategory.series,
      playLines: [
        PlayLine(
          name: '线路',
          episodes: [Episode(name: '第1集', url: _url)],
        ),
      ],
    );
  }
}

class _DelayedSearchEngine extends SourceEngine {
  _DelayedSearchEngine()
    : super(searchTimeout: const Duration(milliseconds: 40));

  @override
  Future<SourceSearchPage> searchCms(
    CmsSource source,
    String query, [
    int page = 1,
  ]) async {
    await Future<void>.delayed(const Duration(milliseconds: 220));
    return SourceSearchPage(
      items: source.id == 'builtin-line-b'
          ? [
              MediaItem(
                id: 'b-id',
                sourceId: source.id,
                sourceName: source.name,
                title: '测试',
                poster: '',
                category: MediaCategory.series,
              ),
            ]
          : const [],
      hasMore: false,
    );
  }
}

class _BudgetedResolveEngine extends SourceEngine {
  _BudgetedResolveEngine(RouteEngine routes)
    : super(routes: routes, detailTimeout: const Duration(milliseconds: 40));

  @override
  Future<MediaItem?> getDetail(
    List<CmsSource> sources,
    String sourceId,
    String id,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return MediaItem(
      id: id,
      sourceId: sourceId,
      sourceName: '来源 $sourceId',
      title: '测试剧集',
      poster: '',
      category: MediaCategory.series,
      playLines: [
        PlayLine(
          name: '线路',
          episodes: [
            Episode(
              name: '第1集',
              url: 'https://$sourceId.example.com/video.mp4',
            ),
          ],
        ),
      ],
    );
  }
}
