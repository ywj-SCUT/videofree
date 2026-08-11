import 'package:flutter_test/flutter_test.dart';
import 'package:videoget_mobile/models/models.dart';
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

  @override
  Future<dynamic> search(
    CmsSource source,
    String query, [
    int page = 1,
  ]) async => [
    {
      'id': 'spider-1',
      'title': query,
      'category': 'series',
      'poster': 'https://img.example.com/spider.jpg',
    },
  ];

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
