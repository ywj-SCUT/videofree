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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    MediaKit.ensureInitialized();
  });

  testWidgets(
    'offline video remains healthy for 30 minutes',
    (tester) async {
      final item = MediaItem(
        id: 'offline-long-run',
        sourceId: 'offline-test',
        sourceName: 'Offline Test',
        title: '离线 30 分钟观测',
        poster: '',
        category: MediaCategory.movie,
        playLines: const [
          PlayLine(
            name: '本地线路',
            episodes: [Episode(name: '第1集', url: _videoUrl)],
          ),
        ],
      );
      final appState = AppState();
      await appState.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: PlayerScreen(
            appState: appState,
            item: item,
            playLines: item.playLines!,
            lineIndex: 0,
            episodeIndex: 0,
          ),
        ),
      );

      final deadline = DateTime.now().add(const Duration(seconds: 30));
      Player? player;
      while (player == null || player.state.duration == Duration.zero) {
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException('Local video did not open');
        }
        await tester.pump(const Duration(milliseconds: 250));
        if (find.byType(Video).evaluate().isNotEmpty) {
          player = tester
              .widget<Video>(find.byType(Video).last)
              .controller
              .player;
        }
      }

      final videoState = tester.state<VideoState>(find.byType(Video).last);
      await videoState.enterFullscreen();
      await tester.pump(const Duration(seconds: 2));
      expect(videoState.isFullscreen(), isTrue);
      debugPrint('LONG_RUN_STAGE=fullscreen-ready');

      final wallClock = Stopwatch()..start();
      var bufferingEvents = 0;
      Duration? bufferingStartedAt;
      var totalBuffering = Duration.zero;
      final bufferingSubscription = player.stream.buffering.listen((buffering) {
        if (buffering && bufferingStartedAt == null) {
          bufferingEvents++;
          bufferingStartedAt = wallClock.elapsed;
        } else if (!buffering && bufferingStartedAt != null) {
          totalBuffering += wallClock.elapsed - bufferingStartedAt!;
          bufferingStartedAt = null;
        }
      });
      addTearDown(bufferingSubscription.cancel);

      final startedAt = player.state.position;
      var previousPosition = startedAt;
      for (var sample = 1; sample <= 30; sample++) {
        await Future<void>.delayed(const Duration(minutes: 1));
        await tester.pump();
        final position = player.state.position;
        debugPrint(
          'LONG_RUN_SAMPLE=$sample '
          'POSITION_MS=${position.inMilliseconds} '
          'DURATION_MS=${player.state.duration.inMilliseconds} '
          'PLAYING=${player.state.playing} '
          'BUFFERING=${player.state.buffering}',
        );
        expect(player.state.playing, isTrue);
        expect(
          position,
          greaterThan(previousPosition + const Duration(seconds: 50)),
        );
        expect(player.state.buffering, isFalse);
        previousPosition = position;
      }

      if (bufferingStartedAt != null) {
        totalBuffering += wallClock.elapsed - bufferingStartedAt!;
      }
      debugPrint(
        'LONG_RUN_RESULT=complete '
        'POSITION_MS=${player.state.position.inMilliseconds} '
        'BUFFERING_EVENTS=$bufferingEvents '
        'BUFFERING_MS=${totalBuffering.inMilliseconds}',
      );
      expect(
        player.state.position,
        greaterThanOrEqualTo(
          startedAt + const Duration(minutes: 29, seconds: 30),
        ),
      );
      expect(player.state.buffering, isFalse);
      expect(
        totalBuffering,
        lessThan(const Duration(seconds: 10)),
        reason: 'The offline file spent too long buffering during the run.',
      );
    },
    timeout: const Timeout(Duration(minutes: 35)),
  );
}
