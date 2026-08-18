import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:videoget_mobile/models/models.dart';
import 'package:videoget_mobile/screens/player_screen.dart';
import 'package:videoget_mobile/services/app_state.dart';
import 'package:videoget_mobile/services/system_playback_controls.dart';
import 'package:videoget_mobile/theme/app_theme.dart';

const _testSourceId = String.fromEnvironment('VIDEOGET_TEST_SOURCE_ID');

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() predicate,
  Duration timeout, {
  required String condition,
  Player? player,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(
        '$condition timed out; position=${player?.state.position}, '
        'duration=${player?.state.duration}, playing=${player?.state.playing}, '
        'buffering=${player?.state.buffering}',
      );
    }
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Player _player(WidgetTester tester) =>
    tester.widget<Video>(find.byType(Video).last).controller.player;

double _visibleFrameRatio(Uint8List pixels) {
  if (pixels.length < 4) return 0;
  var sampled = 0;
  var visible = 0;
  for (var index = 0; index + 2 < pixels.length; index += 64) {
    sampled++;
    if (pixels[index] > 24 ||
        pixels[index + 1] > 24 ||
        pixels[index + 2] > 24) {
      visible++;
    }
  }
  return sampled == 0 ? 0 : visible / sampled;
}

String _normalizedTitle(String value) =>
    value.replaceAll(RegExp(r'[^\u4e00-\u9fffA-Za-z0-9]'), '');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(MediaKit.ensureInitialized);

  testWidgets(
    'network search, playback, seeks, gestures and history',
    (tester) async {
      final appState = AppState();
      await appState.initialize();
      expect(appState.isEmulator, isTrue);
      debugPrint(
        'NETWORK_RENDERER mediacodecEmbed=${appState.isEmulator} '
        'emulator=${appState.isEmulator}',
      );
      await appState.clearHistory();

      final searchTimer = Stopwatch()..start();
      final search = await appState.engine
          .search('怪奇物语第五季', MediaCategory.all, appState.sources)
          .timeout(const Duration(seconds: 20));
      searchTimer.stop();
      expect(search.items, isNotEmpty);
      final item = search.items.firstWhere(
        (entry) => _normalizedTitle(entry.title).contains('怪奇物语第五季'),
      );
      debugPrint(
        'NETWORK_SEARCH title=${item.title} items=${search.items.length} '
        'failures=${search.failures.length} elapsedMs=${searchTimer.elapsedMilliseconds}',
      );

      final detailTimer = Stopwatch()..start();
      final detail = await appState.engine
          .resolve(item, appState.sources)
          .timeout(const Duration(seconds: 45));
      detailTimer.stop();
      expect(detail, isNotNull);
      expect(detail!.playLines, isNotEmpty);
      final lines = detail.playLines!;
      expect(lines.first.episodes, isNotEmpty);
      final selectedLineIndex = _testSourceId.isEmpty
          ? 0
          : lines.indexWhere(
              (line) => line.episodes.any(
                (episode) => episode.sourceId == _testSourceId,
              ),
            );
      expect(
        selectedLineIndex,
        greaterThanOrEqualTo(0),
        reason: 'requested network test source was not resolved',
      );
      debugPrint(
        'NETWORK_DETAIL elapsedMs=${detailTimer.elapsedMilliseconds} '
        'lines=${lines.length} title=${detail.title} '
        'order=${lines.map((line) => line.name).join(' | ')} '
        'selected=${lines[selectedLineIndex].name}',
      );

      final activeLines = _testSourceId.isEmpty
          ? lines
          : <PlayLine>[lines[selectedLineIndex]];

      await SystemPlaybackControls.setBrightness(0.35);
      await SystemPlaybackControls.setVolume(0.33);
      final startupTimer = Stopwatch()..start();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: PlayerScreen(
            appState: appState,
            item: detail,
            playLines: activeLines,
            lineIndex: 0,
            episodeIndex: 0,
          ),
        ),
      );
      expect(find.byType(Video), findsWidgets);
      final player = _player(tester);
      var avformatOpenFailures = 0;
      var monitorStablePlayback = false;
      var stablePlaybackBufferingEvents = 0;
      final logSubscription = player.stream.log.listen((event) {
        if (event.text.contains('avformat_open_input') &&
            event.text.contains('failed')) {
          avformatOpenFailures++;
        }
        if (event.level == 'error' || event.level == 'warn') {
          debugPrint(
            'NETWORK_PLAYER_LOG level=${event.level} text=${event.text}',
          );
        }
      });
      addTearDown(logSubscription.cancel);
      final bufferingSubscription = player.stream.buffering.listen((buffering) {
        if (monitorStablePlayback && buffering) {
          stablePlaybackBufferingEvents++;
        }
      });
      addTearDown(bufferingSubscription.cancel);
      await _waitUntil(
        tester,
        () =>
            player.state.duration > Duration.zero &&
            player.state.position > Duration.zero &&
            player.state.playing &&
            !player.state.buffering,
        const Duration(seconds: 90),
        condition: 'initial network playback',
        player: player,
      );
      startupTimer.stop();
      debugPrint(
        'NETWORK_PLAY startupMs=${startupTimer.elapsedMilliseconds} '
        'durationMs=${player.state.duration.inMilliseconds}',
      );
      // The configured AVD uses the local 7890 proxy and the upstream HLS
      // provider can take up to roughly half a minute to deliver its first
      // encrypted segment. Keep the gate below one minute while still
      // exercising the complete playback, seek, gesture, and history flow.
      expect(
        startupTimer.elapsedMilliseconds,
        lessThan(40000),
        reason: 'cold online playback must start within 40 seconds',
      );
      debugPrint('NETWORK_FRAME_READY');
      if (appState.isEmulator) {
        // MediaCodec renders directly into an Android Surface on the AVD, so
        // libmpv's screenshot-raw command has no CPU frame to return. The
        // release harness captures and checks the composed AVD screen while
        // this stable window is held open.
        debugPrint('NETWORK_FRAME_EXTERNAL_CAPTURE_REQUIRED');
      } else {
        final frame = await player.screenshot(format: null);
        expect(frame, isNotNull, reason: 'mpv did not expose a decoded frame');
        final visibleFrameRatio = _visibleFrameRatio(frame!);
        debugPrint(
          'NETWORK_FRAME_PIXELS bytes=${frame.length} '
          'visibleRatio=${visibleFrameRatio.toStringAsFixed(4)}',
        );
        expect(
          visibleFrameRatio,
          greaterThan(0.02),
          reason: 'decoded video frame is effectively black',
        );
      }
      await Future<void>.delayed(const Duration(seconds: 8));

      final stableStart = player.state.position;
      monitorStablePlayback = true;
      await _waitUntil(
        tester,
        () =>
            player.state.position >=
                stableStart + const Duration(seconds: 10) &&
            player.state.playing &&
            !player.state.buffering,
        const Duration(seconds: 20),
        condition: '10 seconds of stable playback after first frame',
        player: player,
      );
      monitorStablePlayback = false;
      expect(
        stablePlaybackBufferingEvents,
        0,
        reason: 'playback buffered during the first stable 10-second window',
      );
      debugPrint(
        'NETWORK_STABLE advancedMs='
        '${(player.state.position - stableStart).inMilliseconds} '
        'bufferingEvents=$stablePlaybackBufferingEvents',
      );

      Future<int> seekAndMeasure(Duration target) async {
        final timer = Stopwatch()..start();
        await player.seek(target);
        await _waitUntil(
          tester,
          () =>
              player.state.position >=
                  target + const Duration(milliseconds: 500) &&
              player.state.playing &&
              !player.state.buffering,
          const Duration(seconds: 45),
          condition: 'network seek to ${target.inMinutes} minutes',
          player: player,
        );
        timer.stop();
        return timer.elapsedMilliseconds;
      }

      final seekFiveMs = await seekAndMeasure(const Duration(minutes: 5));
      final seekTenMs = await seekAndMeasure(const Duration(minutes: 10));
      debugPrint('NETWORK_SEEK fiveMs=$seekFiveMs tenMs=$seekTenMs');
      expect(
        seekFiveMs,
        lessThan(8000),
        reason: 'seek to five minutes must resume within eight seconds',
      );
      expect(
        seekTenMs,
        lessThan(8000),
        reason: 'seek to ten minutes must resume within eight seconds',
      );
      if (appState.isEmulator) {
        debugPrint('NETWORK_SEEK_FRAME_READY');
        await Future<void>.delayed(const Duration(seconds: 15));
      }

      final videoState = tester.state<VideoState>(find.byType(Video).last);
      await videoState.enterFullscreen();
      await tester.pump(const Duration(seconds: 2));
      expect(videoState.isFullscreen(), isTrue);
      final surface = find.byKey(const ValueKey('player-double-tap-surface'));
      expect(surface, findsOneWidget);
      final rect = tester.getRect(surface);

      await tester.dragFrom(
        Offset(rect.left + rect.width * 0.25, rect.top + rect.height * 0.7),
        Offset(0, -rect.height * 0.35),
      );
      await tester.pump(const Duration(seconds: 1));
      final brightness = await SystemPlaybackControls.brightness();
      expect(brightness, greaterThan(0.35));

      await tester.dragFrom(
        Offset(rect.left + rect.width * 0.75, rect.top + rect.height * 0.7),
        Offset(0, -rect.height * 0.35),
      );
      await tester.pump(const Duration(seconds: 1));
      final volume = await SystemPlaybackControls.volume();
      expect(volume, greaterThan(0.33));

      final hold = await tester.startGesture(rect.center);
      await tester.pump(const Duration(milliseconds: 800));
      await _waitUntil(
        tester,
        () => player.state.rate == 2.0,
        const Duration(seconds: 5),
        condition: 'hold for 2x playback',
        player: player,
      );
      await hold.up();
      await _waitUntil(
        tester,
        () => player.state.rate == 1.0,
        const Duration(seconds: 5),
        condition: 'restore playback rate',
        player: player,
      );
      debugPrint(
        'NETWORK_GESTURES brightness=$brightness volume=$volume rate=2.0',
      );

      await videoState.exitFullscreen();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 3));
      final history = appState.getResume(detail);
      expect(history, isNotNull);
      expect(history!.progress, greaterThanOrEqualTo(599));
      debugPrint('NETWORK_HISTORY progress=${history.progress}');
      debugPrint('NETWORK_AVFORMAT_OPEN_FAILURES count=$avformatOpenFailures');
      expect(
        avformatOpenFailures,
        0,
        reason: 'selected route caused avformat_open_input failures',
      );
      debugPrint('All tests passed');
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
