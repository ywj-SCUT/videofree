import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:videoget_mobile/services/net_service.dart';

void main() {
  setUp(NetService.resetProxyPreferencesForTesting);

  test('代理成功会为同源后续媒体请求记录短期路由提示', () {
    final uri = Uri.parse('https://media.test:9443/path/segment.ts');

    expect(NetService.preferProxyFor(uri), isFalse);
    NetService.recordProxyResult(uri, usedProxy: true);
    expect(NetService.preferProxyFor(uri), isTrue);
    expect(
      NetService.preferProxyFor(
        Uri.parse('https://media.test:9443/another/segment.ts'),
      ),
      isTrue,
    );
  });

  test('同源直连恢复后清除代理路由提示', () {
    final uri = Uri.parse('https://media.test/video.ts');
    NetService.recordProxyResult(uri, usedProxy: true);

    NetService.recordProxyResult(uri, usedProxy: false);

    expect(NetService.preferProxyFor(uri), isFalse);
  });

  test('配置系统代理时仍优先使用直连', () async {
    final direct = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var directRequests = 0;
    direct.listen((request) async {
      directRequests++;
      request.response.write('direct');
      await request.response.close();
    });
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var proxyRequests = 0;
    proxy.listen((request) async {
      proxyRequests++;
      request.response.write('proxy');
      await request.response.close();
    });
    final net = NetService(
      proxyProvider: () async =>
          (host: InternetAddress.loopbackIPv4.address, port: proxy.port),
    );

    try {
      final text = await net.fetchRemoteText(
        'http://${InternetAddress.loopbackIPv4.address}:${direct.port}/video',
      );
      expect(text, 'direct');
      expect(proxyRequests, 0);
      expect(directRequests, 1);
    } finally {
      await direct.close(force: true);
      await proxy.close(force: true);
    }
  });

  test('直连失败后通过配置代理重试 HTTP 请求', () async {
    final unavailable = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final unavailablePort = unavailable.port;
    await unavailable.close(force: true);
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    proxy.listen((request) async {
      requests++;
      request.response
        ..statusCode = HttpStatus.ok
        ..write('proxy-ok');
      await request.response.close();
    });
    final net = NetService(
      proxyProvider: () async =>
          (host: InternetAddress.loopbackIPv4.address, port: proxy.port),
    );

    try {
      final text = await net.fetchRemoteText(
        'http://${InternetAddress.loopbackIPv4.address}:$unavailablePort/video',
      );
      expect(text, 'proxy-ok');
      expect(requests, 1);
      final preferred = await net.fetchRemoteText(
        'http://${InternetAddress.loopbackIPv4.address}:$unavailablePort/video',
      );
      expect(preferred, 'proxy-ok');
      expect(requests, 2);
    } finally {
      await proxy.close(force: true);
    }
  });

  test('短预算内直连超时会为后续播放保留同源代理提示', () async {
    final direct = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final directSubscription = direct.listen((_) {});
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxySubscription = proxy.listen((_) {});
    final net = NetService(
      proxyProvider: () async =>
          (host: InternetAddress.loopbackIPv4.address, port: proxy.port),
    );
    final uri = Uri.parse(
      'http://${InternetAddress.loopbackIPv4.address}:${direct.port}/video',
    );

    try {
      await expectLater(
        net.fetchRemoteText(
          uri.toString(),
          timeout: const Duration(milliseconds: 250),
        ),
        throwsA(anything),
      );
      expect(NetService.preferProxyFor(uri), isTrue);
    } finally {
      await directSubscription.cancel();
      await proxySubscription.cancel();
      await direct.close(force: true);
      await proxy.close(force: true);
    }
  });

  test('显式总超时下直连成功时不会访问代理', () async {
    final direct = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var directRequests = 0;
    direct.listen((request) async {
      directRequests++;
      request.response
        ..statusCode = HttpStatus.ok
        ..write('direct-within-budget');
      await request.response.close();
    });
    final stalledProxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final stalledSubscription = stalledProxy.listen((_) {});
    final net = NetService(
      proxyProvider: () async =>
          (host: InternetAddress.loopbackIPv4.address, port: stalledProxy.port),
    );
    final stopwatch = Stopwatch()..start();

    try {
      final text = await net.fetchRemoteText(
        'http://${InternetAddress.loopbackIPv4.address}:${direct.port}/video',
        timeout: const Duration(milliseconds: 1600),
      );
      stopwatch.stop();
      expect(text, 'direct-within-budget');
      expect(directRequests, 1);
      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 1600)));
    } finally {
      await stalledSubscription.cancel();
      await stalledProxy.close(force: true);
      await direct.close(force: true);
    }
  });

  test('直连优先请求会为代理回退保留预算', () {
    expect(
      networkAttemptTimeout(
        remaining: const Duration(seconds: 5),
        proxyAvailable: true,
        proxyPreferred: false,
        usingProxy: false,
      ),
      const Duration(seconds: 4),
    );
  });
}
