import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:videoget_mobile/models/models.dart';
import 'package:videoget_mobile/screens/player_screen.dart';
import 'package:videoget_mobile/services/app_state.dart';
import 'package:videoget_mobile/theme/app_theme.dart';

const _videoUrl = 'file:///data/local/tmp/videofree-offline-31m.mp4';

final _item = MediaItem(
  id: 'offline-player-test',
  sourceId: 'offline-test',
  sourceName: 'Offline Test',
  title: '离线长视频测试',
  poster: '',
  category: MediaCategory.movie,
  playLines: const [
    PlayLine(
      name: '本地线路',
      episodes: [Episode(name: '第1集', url: _videoUrl)],
    ),
  ],
);

Player _player(WidgetTester tester) {
  final video = tester.widget<Video>(find.byType(Video).last);
  return video.controller.player;
}

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() predicate,
  Duration timeout, {
  String condition = 'condition',
  Player? player,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(
        '$condition was not met within $timeout; '
        'position=${player?.state.position}, '
        'duration=${player?.state.duration}, '
        'playing=${player?.state.playing}',
      );
    }
    await tester.pump(const Duration(milliseconds: 250));
  }
}

Future<void> _pumpPlayer(
  WidgetTester tester,
  AppState appState, {
  HistoryItem? resume,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark(),
      home: PlayerScreen(
        appState: appState,
        item: _item,
        playLines: _item.playLines!,
        lineIndex: 0,
        episodeIndex: 0,
        resume: resume,
      ),
    ),
  );
  await _waitUntil(
    tester,
    () => _player(tester).state.duration > Duration.zero,
    const Duration(seconds: 30),
    condition: 'media duration',
  );
}

Future<void> _doubleTapCenter(WidgetTester tester) async {
  final surface = find.byKey(const ValueKey('player-double-tap-surface'));
  expect(surface, findsOneWidget);
  final center = tester.getCenter(surface);
  await tester.tapAt(center);
  await tester.pump(const Duration(milliseconds: 140));
  await tester.tapAt(center);
  await tester.pump();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    MediaKit.ensureInitialized();
  });

  testWidgets(
    'seek bar visible, double tap pause/resume, and persisted resume',
    (tester) async {
      final appState = AppState();
      await appState.initialize();
      await appState.clearHistory();
      await _pumpPlayer(tester, appState);
      debugPrint('INTEGRATION_STAGE=player-open');

      final firstPlayer = _player(tester);
      expect(firstPlayer.state.playing, isTrue);

      final videoState = tester.state<VideoState>(find.byType(Video).last);
      await videoState.enterFullscreen();
      await tester.pump(const Duration(seconds: 2));
      expect(videoState.isFullscreen(), isTrue);
      expect(find.text('离线长视频测试 · 第1集'), findsOneWidget);
      expect(find.byType(MaterialSeekBar), findsOneWidget);
      final seekBarGesture = find.descendant(
        of: find.byType(MaterialSeekBar),
        matching: find.byType(GestureDetector),
      );
      expect(seekBarGesture, findsOneWidget);
      final seekBar = tester.getRect(seekBarGesture);
      final screenHeight =
          tester.view.physicalSize.height / tester.view.devicePixelRatio;
      expect(seekBar.bottom, lessThan(screenHeight - 20));
      debugPrint(
        'INTEGRATION_STAGE=fullscreen-progress '
        'SEEK_BOTTOM=${seekBar.bottom.toStringAsFixed(1)} '
        'SCREEN_HEIGHT=${screenHeight.toStringAsFixed(1)}',
      );

      await _doubleTapCenter(tester);
      await _waitUntil(
        tester,
        () => !firstPlayer.state.playing,
        const Duration(seconds: 5),
        condition: 'double-tap pause',
        player: firstPlayer,
      );
      debugPrint('INTEGRATION_STAGE=double-tap-pause');
      await _doubleTapCenter(tester);
      await _waitUntil(
        tester,
        () => firstPlayer.state.playing,
        const Duration(seconds: 5),
        condition: 'double-tap resume',
        player: firstPlayer,
      );
      debugPrint('INTEGRATION_STAGE=double-tap-resume');
      await videoState.exitFullscreen();
      await tester.pump(const Duration(seconds: 1));

      await firstPlayer.seek(const Duration(seconds: 60));
      await tester.pump(const Duration(seconds: 2));
      // Dispose to trigger _saveProgress.
      await tester.pumpWidget(Container());
      await tester.pump(const Duration(seconds: 3));

      final saved = appState.getResume(_item);
      expect(saved, isNotNull);
      expect(saved!.progress, greaterThanOrEqualTo(59));
      debugPrint(
        'INTEGRATION_STAGE=progress-saved '
        'PROGRESS=${saved.progress.toStringAsFixed(3)}',
      );

      await _pumpPlayer(tester, appState, resume: saved);
      debugPrint('INTEGRATION_STAGE=resume-player-open');
      final resumedPlayer = _player(tester);
      await _waitUntil(
        tester,
        () => resumedPlayer.state.position >= const Duration(seconds: 59),
        const Duration(seconds: 30),
        condition: 'persisted resume position',
        player: resumedPlayer,
      );
      expect(
        resumedPlayer.state.position,
        greaterThanOrEqualTo(const Duration(seconds: 59)),
      );
      debugPrint(
        'INTEGRATION_STAGE=resume-applied '
        'POSITION_MS=${resumedPlayer.state.position.inMilliseconds}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
