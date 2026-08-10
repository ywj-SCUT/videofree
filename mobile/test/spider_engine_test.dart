import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:videoget_mobile/models/models.dart';
import 'package:videoget_mobile/services/spider_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'flutter_js 执行完整 Spider search/detail/play 合约',
    () async {
      final engine = FlutterJsSpiderEngine();
      const source = CmsSource(
        id: 'inline-spider',
        name: '内联规则',
        type: 'spider',
        enabled: true,
        searchable: true,
        ruleConfig: {'suffix': '资源'},
        script: r'''
        module.exports = {
          async search(input, context) {
            return [{
              id: 'js-1',
              title: input.query + context.config.suffix,
              category: 'movie',
              poster: 'https://example.com/poster.jpg'
            }];
          },
          async detail(input) {
            return {
              id: input.id,
              title: 'JS 详情',
              category: 'movie',
              playLines: [{
                name: 'JS 线路',
                episodes: [{name: '正片', token: {key: 'play-1'}}]
              }]
            };
          },
          async play(input) {
            return {
              url: 'https://example.com/video.m3u8',
              headers: {'Referer': 'https://example.com/'}
            };
          }
        };
      ''',
      );

      final search = await engine.search(source, '测试');
      expect(search, isA<List<dynamic>>());
      expect((search as List).single['title'], '测试资源');

      final detail = await engine.detail(source, 'js-1');
      expect(detail['playLines'], hasLength(1));

      final play = await engine.play(source, {'key': 'play-1'});
      expect(play['url'], 'https://example.com/video.m3u8');
    },
    skip: !Platform.isAndroid ? 'QuickJS 原生运行时在 Android 真机测试中执行' : false,
  );
}
