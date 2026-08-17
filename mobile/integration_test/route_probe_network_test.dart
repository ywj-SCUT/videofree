import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:videoget_mobile/models/models.dart';
import 'package:videoget_mobile/screens/player_screen.dart';
import 'package:videoget_mobile/services/app_state.dart';
import 'package:videoget_mobile/services/playback_proxy.dart';
import 'package:videoget_mobile/theme/app_theme.dart';

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() predicate,
  Duration timeout,
) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition timed out');
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pumpFor(WidgetTester tester, Duration duration) async {
  final deadline = DateTime.now().add(duration);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Player _player(WidgetTester tester) =>
    tester.widget<Video>(find.byType(Video).last).controller.player;

class _LinePlaybackResult {
  final int lineNumber;
  final String name;
  final int startupMs;
  final int advancementMs;
  final int bufferingEvents;
  final int? seekFiveMs;
  final int? seekTenMs;
  final List<String> errors;
  final String? failure;

  const _LinePlaybackResult({
    required this.lineNumber,
    required this.name,
    required this.startupMs,
    required this.advancementMs,
    required this.bufferingEvents,
    required this.seekFiveMs,
    required this.seekTenMs,
    required this.errors,
    required this.failure,
  });

  bool get qualifies =>
      failure == null &&
      startupMs < 20000 &&
      advancementMs >= 8000 &&
      bufferingEvents == 0 &&
      seekFiveMs != null &&
      seekFiveMs! < 8000 &&
      seekTenMs != null &&
      seekTenMs! < 8000;
}

Future<({int status, String type, String body, int elapsedMs})> _readManifest(
  HttpClient client,
  Uri uri,
) async {
  final timer = Stopwatch()..start();
  final request = await client.getUrl(uri).timeout(const Duration(seconds: 5));
  final response = await request.close().timeout(const Duration(seconds: 20));
  final body = await utf8.decoder
      .bind(response)
      .join()
      .timeout(const Duration(seconds: 20));
  timer.stop();
  return (
    status: response.statusCode,
    type: response.headers.contentType?.mimeType ?? '',
    body: body,
    elapsedMs: timer.elapsedMilliseconds,
  );
}

Future<({int status, String type, int bytes, int elapsedMs})> _readFirstChunk(
  HttpClient client,
  Uri uri,
) async {
  final timer = Stopwatch()..start();
  final request = await client.getUrl(uri).timeout(const Duration(seconds: 5));
  final response = await request.close().timeout(const Duration(seconds: 20));
  final chunk = await response.first.timeout(const Duration(seconds: 20));
  timer.stop();
  return (
    status: response.statusCode,
    type: response.headers.contentType?.mimeType ?? '',
    bytes: chunk.length,
    elapsedMs: timer.elapsedMilliseconds,
  );
}

Uri? _firstMediaUri(String manifest) {
  for (final line in manifest.split(RegExp(r'\r?\n'))) {
    final value = line.trim();
    if (value.isNotEmpty && !value.startsWith('#')) {
      return Uri.tryParse(value);
    }
  }
  return null;
}

Future<bool> _probeLine(PlayLine line, {required bool required}) async {
  final episode = line.episodes.first;
  final source = Uri.parse(episode.url);
  final local = await PlaybackProxy.instance.urlFor(
    episode.url,
    headers: episode.headers,
    filterAds: true,
  );
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  final total = Stopwatch()..start();
  try {
    final root = await _readManifest(client, local);
    expect(
      root.status,
      inInclusiveRange(200, 299),
      reason: '${line.name} master returned HTTP ${root.status}',
    );
    var media = root;
    if (root.body.contains('#EXT-X-STREAM-INF')) {
      final variant = _firstMediaUri(root.body);
      expect(variant, isNotNull, reason: '${line.name} master has no variant');
      media = await _readManifest(client, variant!);
      expect(
        media.status,
        inInclusiveRange(200, 299),
        reason: '${line.name} variant returned HTTP ${media.status}',
      );
    }
    final segment = _firstMediaUri(media.body);
    expect(segment, isNotNull, reason: '${line.name} media has no segment');
    final first = await _readFirstChunk(client, segment!);
    expect(
      first.status,
      anyOf(HttpStatus.ok, HttpStatus.partialContent),
      reason: '${line.name} segment returned HTTP ${first.status}',
    );
    expect(
      first.bytes,
      greaterThan(0),
      reason: '${line.name} segment is empty',
    );
    total.stop();
    debugPrint(
      'ROUTE_PROXY name=${line.name} host=${source.host} '
      'root=${root.status}/${root.elapsedMs}ms '
      'media=${media.status}/${media.elapsedMs}ms '
      'segment=${first.status}/${first.elapsedMs}ms/${first.bytes}B '
      'totalMs=${total.elapsedMilliseconds}',
    );
    return true;
  } catch (error) {
    total.stop();
    debugPrint(
      'ROUTE_PROXY_FAILED name=${line.name} host=${source.host} '
      'elapsedMs=${total.elapsedMilliseconds} error=$error',
    );
    if (required) rethrow;
    return false;
  } finally {
    client.close(force: true);
  }
}

Future<_LinePlaybackResult> _probePlayer(
  WidgetTester tester,
  AppState appState,
  MediaItem detail,
  PlayLine line,
  int lineNumber,
) async {
  final startup = Stopwatch()..start();
  var advancementMs = 0;
  var bufferingEvents = 0;
  int? seekFiveMs;
  int? seekTenMs;
  String? failure;
  final errors = <String>{};
  StreamSubscription<PlayerLog>? logSubscription;
  StreamSubscription<bool>? bufferingSubscription;
  var monitorStablePlayback = false;

  try {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: PlayerScreen(
          appState: appState,
          item: detail,
          playLines: [line],
          lineIndex: 0,
          episodeIndex: 0,
        ),
      ),
    );
    expect(find.byType(Video), findsWidgets);
    final player = _player(tester);
    logSubscription = player.stream.log.listen((event) {
      final lower = event.text.toLowerCase();
      if (event.level == 'error' ||
          lower.contains('avformat') ||
          lower.contains('decoder') ||
          lower.contains('decode') ||
          lower.contains('failed')) {
        errors.add('${event.level}:${event.text.trim()}');
      }
    });
    bufferingSubscription = player.stream.buffering.listen((buffering) {
      if (monitorStablePlayback && buffering) bufferingEvents++;
    });

    await _waitUntil(
      tester,
      () =>
          player.state.duration > const Duration(minutes: 10) &&
          player.state.position > Duration.zero &&
          player.state.playing &&
          !player.state.buffering,
      const Duration(seconds: 75),
    );
    startup.stop();

    await _pumpFor(tester, const Duration(seconds: 8));
    final continuousStart = player.state.position;
    monitorStablePlayback = true;
    await _pumpFor(tester, const Duration(seconds: 10));
    monitorStablePlayback = false;
    advancementMs = (player.state.position - continuousStart).inMilliseconds;

    Future<int> seek(Duration target) async {
      final timer = Stopwatch()..start();
      await player.seek(target);
      await _waitUntil(
        tester,
        () =>
            player.state.position >=
                target + const Duration(milliseconds: 500) &&
            player.state.playing &&
            !player.state.buffering,
        const Duration(seconds: 35),
      );
      timer.stop();
      return timer.elapsedMilliseconds;
    }

    try {
      seekFiveMs = await seek(const Duration(minutes: 5));
    } catch (error) {
      errors.add('seek-5m:$error');
    }
    try {
      seekTenMs = await seek(const Duration(minutes: 10));
    } catch (error) {
      errors.add('seek-10m:$error');
    }
  } catch (error) {
    startup.stop();
    failure = error.toString();
  } finally {
    await logSubscription?.cancel();
    await bufferingSubscription?.cancel();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  }

  final result = _LinePlaybackResult(
    lineNumber: lineNumber,
    name: line.name,
    startupMs: startup.elapsedMilliseconds,
    advancementMs: advancementMs,
    bufferingEvents: bufferingEvents,
    seekFiveMs: seekFiveMs,
    seekTenMs: seekTenMs,
    errors: errors.take(12).toList(),
    failure: failure,
  );
  debugPrint(
    'ROUTE_PLAYER line=$lineNumber name=${line.name} '
    'startupMs=${result.startupMs} advancementMs=${result.advancementMs} '
    'bufferingEvents=${result.bufferingEvents} '
    'seekFiveMs=${result.seekFiveMs} seekTenMs=${result.seekTenMs} '
    'qualifies=${result.qualifies} failure=${result.failure} '
    'errors=${result.errors.join(' || ')}',
  );
  return result;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(MediaKit.ensureInitialized);

  testWidgets(
    'probe routed lines through Android playback proxy',
    (tester) async {
      final appState = AppState();
      await appState.initialize();
      final search = await appState.engine
          .search('怪奇物语', MediaCategory.all, appState.sources)
          .timeout(const Duration(seconds: 20));
      final item = search.items.firstWhere(
        (entry) => entry.title.contains('怪奇物语第五季'),
        orElse: () =>
            search.items.firstWhere((entry) => entry.title.contains('怪奇物语')),
      );
      final detail = await appState.engine
          .resolve(item, appState.sources)
          .timeout(const Duration(seconds: 45));
      expect(detail?.playLines, isNotEmpty);
      final lines = detail!.playLines!;
      debugPrint('ROUTE_ORDER ${lines.map((line) => line.name).join(' | ')}');
      final indexes = List<int>.generate(lines.length, (index) => index);
      expect(indexes, isNotEmpty);
      final results = <_LinePlaybackResult>[];
      for (final index in indexes) {
        await _probeLine(lines[index], required: false);
        results.add(
          await _probePlayer(tester, appState, detail, lines[index], index + 1),
        );
      }
      final qualified = results
          .where((result) => result.qualifies)
          .map((result) => '${result.lineNumber}:${result.name}')
          .join(' | ');
      debugPrint('ROUTE_QUALIFIED ${qualified.isEmpty ? 'none' : qualified}');
      expect(results, hasLength(indexes.length));
      expect(
        results.any((result) => result.qualifies),
        isTrue,
        reason: 'at least one probed route must sustain real network playback',
      );
      debugPrint('All tests passed');
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
