import 'package:flutter_test/flutter_test.dart';
import 'package:videoget_mobile/services/live_engine.dart';

void main() {
  final engine = LiveEngine();

  group('parseLivePlaylist', () {
    test('解析 EXTINF 格式 M3U', () {
      const content = '#EXTM3U\n'
          '#EXTINF:-1 tvg-id="cctv1" tvg-name="CCTV1" group-title="央视" tvg-logo="logo.png",CCTV-1 综合\n'
          'https://stream.example.com/cctv1.m3u8\n'
          '#EXTINF:-1 group-title="央视",CCTV-2\n'
          'https://stream.example.com/cctv2.m3u8';
      final channels = engine.parseLivePlaylist(content, 'src1', '测试直播');
      expect(channels, hasLength(2));
      expect(channels[0].name, 'CCTV-1 综合');
      expect(channels[0].group, '央视');
      expect(channels[0].logo, 'logo.png');
      expect(channels[0].url, 'https://stream.example.com/cctv1.m3u8');
      expect(channels[1].name, 'CCTV-2');
    });

    test('解析 txt 格式频道列表', () {
      const content = '央视,#genre#\n'
          'CCTV-1,https://stream.example.com/cctv1.m3u8\n'
          'CCTV-2,https://stream.example.com/cctv2.m3u8';
      final channels = engine.parseLivePlaylist(content, 'src2', 'TXT直播');
      expect(channels, hasLength(2));
      expect(channels[0].group, '央视');
      expect(channels[1].group, '央视');
    });

    test('多 URL 分集合并同名频道', () {
      const content = '#EXTINF:-1 group-title="新闻",CNN\n'
          'https://a.example.com/cnn.m3u8#https://b.example.com/cnn.m3u8';
      final channels = engine.parseLivePlaylist(content, 'src3', '新闻');
      expect(channels, hasLength(1));
      expect(channels.first.urls, hasLength(2));
    });

    test('空内容返回空列表', () {
      expect(engine.parseLivePlaylist('', 'src', '空'), isEmpty);
    });
  });
}
