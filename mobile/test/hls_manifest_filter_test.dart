import 'package:flutter_test/flutter_test.dart';
import 'package:videoget_mobile/services/hls_manifest_filter.dart';
import 'package:videoget_mobile/services/playback_proxy.dart';

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
}
