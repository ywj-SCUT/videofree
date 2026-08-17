import 'package:flutter_test/flutter_test.dart';
import 'package:videoget_mobile/services/hls_manifest_filter.dart';
import 'package:videoget_mobile/services/playback_proxy.dart';

String _group(String name, int count, {bool discontinuity = false}) {
  final lines = <String>[if (discontinuity) '#EXT-X-DISCONTINUITY'];
  for (var index = 0; index < count; index++) {
    lines.addAll(['#EXTINF:6,', '$name-$index.ts']);
  }
  return lines.join('\n');
}

String _manifest(List<String> groups) => [
  '#EXTM3U',
  '#EXT-X-MEDIA-SEQUENCE:100',
  ...groups,
  '#EXT-X-ENDLIST',
].join('\n');

void main() {
  test('filters marked and named HLS ad segments without false positives', () {
    const manifest = '''#EXTM3U
#EXT-X-MEDIA-SEQUENCE:10
#EXTINF:5,
preroll/ad-0.ts
#EXTINF:5,
main/1.ts
#EXT-X-CUE-OUT:10
#EXTINF:5,
ads/mid-1.ts
#EXTINF:5,
ads/mid-2.ts
#EXT-X-CUE-IN
#EXTINF:5,
pcdn/main-adsorption.ts
#EXTINF:5,
media/shadow-play.ts
#EXT-X-ENDLIST''';
    final result = filterHlsManifest(manifest);
    expect(result.removedSegments, 3);
    expect(result.removedDuration, 15);
    expect(result.manifest, contains('#EXT-X-MEDIA-SEQUENCE:11'));
    expect(result.manifest, contains('pcdn/main-adsorption.ts'));
    expect(result.manifest, contains('media/shadow-play.ts'));
    expect(result.manifest, isNot(contains('mid-1.ts')));
  });

  test('restores encryption key and init map after a removed ad segment', () {
    const manifest = '''#EXTM3U
#EXT-X-MEDIA-SEQUENCE:3
#EXT-X-KEY:METHOD=AES-128,URI="keys/content.key"
#EXT-X-MAP:URI="init/content.mp4"
#EXTINF:5,
ads/preroll.ts
#EXTINF:5,
main/first.m4s''';
    final result = filterHlsManifest(manifest);
    expect(result.manifest, contains('#EXT-X-KEY:METHOD=AES-128'));
    expect(result.manifest, contains('#EXT-X-MAP:URI="init/content.mp4"'));
    expect(
      result.manifest.indexOf('#EXT-X-KEY:'),
      lessThan(result.manifest.indexOf('main/first.m4s')),
    );
  });

  test('only caches media responses and never manifests or html', () {
    expect(
      isCacheableVideoResponse(
        Uri.parse('https://example.test/segment.ts'),
        'video/mp2t',
      ),
      isTrue,
    );
    expect(
      isCacheableVideoResponse(
        Uri.parse('https://example.test/stream?id=1'),
        'application/octet-stream',
      ),
      isTrue,
    );
    expect(
      isCacheableVideoResponse(
        Uri.parse('https://example.test/master.m3u8'),
        'application/vnd.apple.mpegurl',
      ),
      isFalse,
    );
    expect(
      isCacheableVideoResponse(
        Uri.parse('https://example.test/error'),
        'text/html',
      ),
      isFalse,
    );
  });

  test('A mode removes a short discontinuity island between long groups', () {
    final manifest = _manifest([
      _group('a-main-before', 30),
      _group('a-short', 5, discontinuity: true),
      _group('a-main-after', 30, discontinuity: true),
    ]);

    final result = filterHlsManifest(manifest);

    expect(result.removedSegments, 5);
    expect(result.removedDuration, 30);
    expect(result.manifest, isNot(contains('a-short-0.ts')));
    expect(result.manifest, contains('a-main-before-29.ts'));
    expect(result.manifest, contains('a-main-after-0.ts'));
  });

  test('G mode removes repeated short islands at playlist boundaries', () {
    final manifest = _manifest([
      _group('g-edge-before', 4),
      _group('g-main', 30, discontinuity: true),
      _group('g-edge-after', 4, discontinuity: true),
    ]);

    final result = filterHlsManifest(manifest);

    expect(result.removedSegments, 8);
    expect(result.removedDuration, 48);
    expect(result.manifest, contains('#EXT-X-MEDIA-SEQUENCE:104'));
    expect(result.manifest, isNot(contains('g-edge-before-0.ts')));
    expect(result.manifest, isNot(contains('g-edge-after-0.ts')));
    expect(result.manifest, contains('g-main-0.ts'));
  });

  test('F mode keeps ordinary consecutive short discontinuity groups', () {
    final manifest = _manifest([
      _group('f-part-one', 10),
      _group('f-part-two', 8, discontinuity: true),
      _group('f-part-three', 12, discontinuity: true),
    ]);

    final result = filterHlsManifest(manifest);

    expect(result.removedSegments, 0);
    expect(result.manifest, contains('f-part-one-0.ts'));
    expect(result.manifest, contains('f-part-two-0.ts'));
    expect(result.manifest, contains('f-part-three-0.ts'));
  });

  test('C mode keeps a unique short boundary group beside long content', () {
    final manifest = _manifest([
      _group('c-main', 30),
      _group('c-ending', 7, discontinuity: true),
    ]);

    final result = filterHlsManifest(manifest);

    expect(result.removedSegments, 0);
    expect(result.manifest, contains('c-main-0.ts'));
    expect(result.manifest, contains('c-ending-0.ts'));
  });
}
