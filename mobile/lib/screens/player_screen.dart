import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../models/models.dart';
import '../services/app_state.dart';
import '../services/playback_proxy.dart';
import '../services/quality_selector.dart';
import '../services/route_engine.dart';
import '../services/system_playback_controls.dart';
import '../theme/app_theme.dart';

bool shouldResumePlayback(HistoryItem? resume, String episodeName) {
  if (resume == null ||
      resume.episodeName != episodeName ||
      resume.progress <= 0) {
    return false;
  }
  return resume.duration <= 0 || resume.progress < resume.duration - 15;
}

bool shouldApplyResumeSeek(
  HistoryItem? resume,
  String episodeName,
  Duration duration,
  Duration position,
) {
  return shouldResumePlayback(resume, episodeName) &&
      (duration > Duration.zero || position > Duration.zero);
}

const playbackReadyProgressThreshold = Duration(seconds: 3);
const playbackRouteHealthThreshold = Duration(seconds: 8);
// The release network gate requires cold playback to begin within 20 seconds.
// Keep a small margin for the test harness and make all startup failover
// attempts share one wall-clock budget instead of multiplying per-route waits.
const playbackStartupBudget = Duration(seconds: 18);
const playbackFailoverBudget = Duration(seconds: 18);
const playbackResetPositionThreshold = Duration(seconds: 1);
// A decoder reset after the first frame is a hard route failure on mobile.
// Switch promptly so the next route still has time inside the shared startup
// budget instead of leaving the player on a zero-position buffer.
const playbackResetRecoveryDelay = Duration(seconds: 2);
const playbackBufferRecoveryDelay = Duration(seconds: 6);
const playbackStartupBufferRecoveryDelay = Duration(seconds: 2);
const playbackSlowProgressWindow = Duration(seconds: 6);
const playbackMinimumProgressRatio = 0.5;

Duration continuousPlaybackProgress({
  required Duration accumulated,
  required Duration? previousPosition,
  required Duration position,
  required bool playing,
  required bool buffering,
}) {
  if (!playing || buffering || previousPosition == null) {
    return Duration.zero;
  }
  final delta = position - previousPosition;
  if (delta < Duration.zero || delta > const Duration(seconds: 3)) {
    return Duration.zero;
  }
  return accumulated + delta;
}

bool hasVerifiedPlaybackProgress({
  required Duration duration,
  required bool playing,
  required bool buffering,
  required Duration continuousProgress,
  required Duration threshold,
}) =>
    duration > Duration.zero &&
    playing &&
    !buffering &&
    continuousProgress >= threshold;

bool needsStartupFailover({
  required Duration duration,
  required bool playing,
  required bool buffering,
  required Duration continuousProgress,
}) => !hasVerifiedPlaybackProgress(
  duration: duration,
  playing: playing,
  buffering: buffering,
  continuousProgress: continuousProgress,
  threshold: playbackRouteHealthThreshold,
);

bool isPlaybackPositionReset({
  required bool previouslyProgressed,
  required Duration position,
}) => previouslyProgressed && position < playbackResetPositionThreshold;

Duration bufferingRecoveryDelay({required bool positionReset}) =>
    positionReset ? playbackResetRecoveryDelay : playbackBufferRecoveryDelay;

Duration playbackTimeoutWithin(
  DateTime now,
  DateTime? deadline,
  Duration fallback,
) {
  if (deadline == null) return fallback;
  final remaining = deadline.difference(now);
  if (remaining <= Duration.zero) {
    throw TimeoutException('Playback failover budget exhausted', fallback);
  }
  return remaining < fallback ? remaining : fallback;
}

bool isFatalPlaybackLog(String text) {
  final lower = text.toLowerCase();
  return (lower.contains('avformat_open_input') && lower.contains('failed')) ||
      lower.contains('error when loading first segment') ||
      lower.contains('crypto: unable to open resource');
}

bool isPlaybackProgressTooSlow({
  required Duration elapsed,
  required Duration progress,
  required bool playing,
  required bool buffering,
}) {
  if (!playing || buffering || elapsed < playbackSlowProgressWindow) {
    return false;
  }
  return progress.inMilliseconds <
      elapsed.inMilliseconds * playbackMinimumProgressRatio;
}

// A short stable-playback window prevents background downloads from restarting
// immediately after a buffer event and contending with foreground recovery.
const timelinePrefetchStabilityThreshold = Duration(seconds: 3);
const playbackProgressStallThreshold = Duration(seconds: 5);
const playbackSeekFailoverGrace = Duration(seconds: 25);

bool isPlaybackProgressStalled({
  required Duration baselinePosition,
  required Duration currentPosition,
  required Duration elapsed,
  required bool opened,
  required bool playing,
  required bool buffering,
  required bool nearEnd,
}) {
  if (!opened ||
      !playing ||
      buffering ||
      nearEnd ||
      currentPosition < const Duration(seconds: 1)) {
    return false;
  }
  return currentPosition - baselinePosition <
          const Duration(milliseconds: 500) &&
      elapsed >= playbackProgressStallThreshold;
}

bool isTimelinePositionDiscontinuity(
  Duration? previousPosition,
  Duration position,
) {
  if (previousPosition == null) return false;
  final delta = position - previousPosition;
  return delta < Duration.zero || delta > const Duration(seconds: 3);
}

Duration timelinePrefetchStableDuration({
  required Duration accumulated,
  required Duration? previousPosition,
  required Duration position,
  required bool playing,
  required bool buffering,
}) {
  return continuousPlaybackProgress(
    accumulated: accumulated,
    previousPosition: previousPosition,
    position: position,
    playing: playing,
    buffering: buffering,
  );
}

bool isPlaybackToggleDoubleTap(
  Duration? previousTime,
  Offset? previousPosition,
  Duration currentTime,
  Offset currentPosition,
) {
  if (previousTime == null || previousPosition == null) return false;
  return currentTime - previousTime <= const Duration(milliseconds: 350) &&
      (currentPosition - previousPosition).distance <= 72;
}

bool isPlaybackToggleRegion(Offset position, Size size) {
  final topInset = math.min(72.0, size.height * .22);
  final bottomInset = math.min(96.0, size.height * .24);
  return position.dy >= topInset && position.dy <= size.height - bottomInset;
}

int matchingEpisodeIndex(PlayLine line, String episodeName, int fallbackIndex) {
  if (line.episodes.isEmpty) return -1;
  final exact = line.episodes.indexWhere(
    (episode) => episode.name == episodeName,
  );
  if (exact >= 0) return exact;
  final episodeNumber = int.tryParse(
    RegExp(r'\d+').firstMatch(episodeName)?.group(0) ?? '',
  );
  if (episodeNumber != null) {
    final numbered = line.episodes.indexWhere(
      (episode) =>
          int.tryParse(
            RegExp(r'\d+').firstMatch(episode.name)?.group(0) ?? '',
          ) ==
          episodeNumber,
    );
    if (numbered >= 0) return numbered;
  }
  return fallbackIndex.clamp(0, line.episodes.length - 1).toInt();
}

List<({int lineIndex, int episodeIndex})> failoverTargets(
  List<PlayLine> lines,
  int currentLine,
  Set<int> failedLines,
  String episodeName,
  int fallbackEpisode,
) {
  final targets = <({int lineIndex, int episodeIndex})>[];
  for (var offset = 1; offset < lines.length; offset++) {
    final lineIndex = (currentLine + offset) % lines.length;
    if (failedLines.contains(lineIndex)) continue;
    final episodeIndex = matchingEpisodeIndex(
      lines[lineIndex],
      episodeName,
      fallbackEpisode,
    );
    if (episodeIndex >= 0) {
      targets.add((lineIndex: lineIndex, episodeIndex: episodeIndex));
    }
  }
  return targets;
}

class PlayerScreen extends StatefulWidget {
  final AppState appState;
  final MediaItem item;
  final List<PlayLine> playLines;
  final int lineIndex;
  final int episodeIndex;
  final HistoryItem? resume;

  const PlayerScreen({
    super.key,
    required this.appState,
    required this.item,
    required this.playLines,
    required this.lineIndex,
    required this.episodeIndex,
    this.resume,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final Player _player;
  late final VideoController _videoController;
  late int _lineIndex;
  late int _episodeIndex;
  bool _loading = true;
  String? _error;
  Timer? _saveTimer;
  Timer? _stallTimer;
  Timer? _startupTimer;
  Timer? _prefetchTimer;
  Timer? _progressWatchdogTimer;
  StreamSubscription<Tracks>? _tracksSubscription;
  StreamSubscription<Track>? _trackSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<bool>? _bufferingSubscription;
  StreamSubscription<PlayerLog>? _logSubscription;
  List<VideoTrack> _videoTracks = [VideoTrack.auto()];
  String _selectedTrackId = 'auto';
  bool _preferenceApplied = false;
  bool _opened = false;
  double _playbackRate = 1.0;
  HistoryItem? _resume;
  bool _resumeApplied = false;
  bool _resumeSeekInFlight = false;
  Future<void> _saveQueue = Future.value();
  Duration? _lastPointerDown;
  Offset? _lastPointerPosition;
  bool _allowPop = false;
  bool _autoSwitching = false;
  final Set<int> _failedLines = {};
  int? _healthyLineIndex;
  Uri? _prefetchUrl;
  bool _prefetchStarted = false;
  Duration? _lastPrefetchPosition;
  Duration _stablePrefetchPlayback = Duration.zero;
  Duration? _lastRouteHealthPosition;
  Duration _stableRoutePlayback = Duration.zero;
  bool _previouslyProgressed = false;
  DateTime? _routeProgressWindowStartedAt;
  Duration? _routeProgressWindowStartPosition;
  Duration _watchdogPosition = Duration.zero;
  DateTime _watchdogAdvancedAt = DateTime.now();
  DateTime? _seekGraceUntil;
  DateTime? _startupFailoverDeadline;

  double _brightness = 0.5;
  double _volume = 0.5;
  double? _longPressPreviousRate;

  static const _speedOptions = [0.75, 1.0, 1.25, 1.5, 2.0];

  String _rateLabel(double rate) {
    if (rate == rate.roundToDouble()) return '${rate.round()}x';
    return '$rate x';
  }

  @override
  void initState() {
    super.initState();
    _lineIndex = widget.lineIndex;
    _episodeIndex = widget.episodeIndex;
    _resume = widget.resume;
    _player = Player(
      configuration: const PlayerConfiguration(bufferSize: 96 * 1024 * 1024),
    );
    // libmpv's Android GPU context is not available on the API 35 AVD. Keep
    // the default GPU output on physical devices, but render emulator frames
    // through MediaCodec's Surface so online playback remains testable there.
    _videoController = VideoController(
      _player,
      configuration: widget.appState.isEmulator
          ? const VideoControllerConfiguration(
              vo: 'mediacodec_embed',
              hwdec: 'mediacodec',
            )
          : const VideoControllerConfiguration(),
    );
    _tracksSubscription = _player.stream.tracks.listen(_handleTracks);
    _trackSubscription = _player.stream.track.listen((track) {
      if (mounted) setState(() => _selectedTrackId = track.video.id);
    });
    _durationSubscription = _player.stream.duration.listen((_) {
      _applyResumeIfReady();
    });
    _positionSubscription = _player.stream.position.listen((position) {
      _applyResumeIfReady();
      _observeTimelinePrefetch(position);
      _observeRouteHealth(position);
    });
    _bufferingSubscription = _player.stream.buffering.listen(_handleBuffering);
    _logSubscription = _player.stream.log.listen((event) {
      if (isFatalPlaybackLog(event.text)) {
        unawaited(_tryAutoSwitch('线路媒体打开失败'));
      }
    });
    _progressWatchdogTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _watchPlaybackProgress(),
    );
    _startupFailoverDeadline = DateTime.now().add(playbackStartupBudget);
    unawaited(_loadSystemLevels());
    _openCurrent();
    _saveTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _saveProgress(),
    );
  }

  void _observeRouteHealth(Duration position) {
    final previousPosition = _lastRouteHealthPosition;
    final playing = _player.state.playing;
    final buffering = _player.state.buffering;
    if (!playing || buffering) {
      _resetRouteProgressWindow();
    } else if (_routeProgressWindowStartedAt == null ||
        _routeProgressWindowStartPosition == null ||
        isTimelinePositionDiscontinuity(previousPosition, position)) {
      _routeProgressWindowStartedAt = DateTime.now();
      _routeProgressWindowStartPosition = position;
    }
    if (position > Duration.zero && playing && !buffering) {
      _previouslyProgressed = true;
    }
    _stableRoutePlayback = continuousPlaybackProgress(
      accumulated: _stableRoutePlayback,
      previousPosition: previousPosition,
      position: position,
      playing: playing,
      buffering: buffering,
    );
    _lastRouteHealthPosition = position;
    if (hasVerifiedPlaybackProgress(
      duration: _player.state.duration,
      playing: _player.state.playing,
      buffering: _player.state.buffering,
      continuousProgress: _stableRoutePlayback,
      threshold: playbackRouteHealthThreshold,
    )) {
      if (_startupTimer != null) {
        _startupTimer?.cancel();
        _startupTimer = null;
      }
      if (_healthyLineIndex != _lineIndex) {
        _healthyLineIndex = _lineIndex;
        _failedLines.remove(_lineIndex);
        RouteEngine.recordPlaybackSuccess(_current);
      }
    }
  }

  Future<void> _configureMpvCache() async {
    final platform = _player.platform;
    if (platform is NativePlayer) {
      await Future.wait([
        platform.setProperty('cache', 'yes'),
        platform.setProperty('cache-on-disk', 'no'),
        platform.setProperty('cache-secs', '240'),
        platform.setProperty('demuxer-readahead-secs', '120'),
        platform.setProperty('demuxer-seekable-cache', 'yes'),
        platform.setProperty('demuxer-max-back-bytes', '33554432'),
        platform.setProperty('cache-pause', 'yes'),
        platform.setProperty('cache-pause-initial', 'yes'),
        platform.setProperty('cache-pause-wait', '1'),
        platform.setProperty('network-timeout', '45'),
        platform.setProperty('stream-buffer-size', '1048576'),
      ]);
    }
  }

  Future<void> _loadSystemLevels() async {
    final values = await Future.wait([
      SystemPlaybackControls.brightness(),
      SystemPlaybackControls.volume(),
    ]);
    _brightness = values[0];
    _volume = values[1];
  }

  void _handleBuffering(bool buffering) {
    if (!buffering) {
      _stallTimer?.cancel();
      _stallTimer = null;
      _seekGraceUntil = null;
      _scheduleTimelinePrefetch();
      return;
    }
    final position = _player.state.position;
    final positionReset = isPlaybackPositionReset(
      previouslyProgressed: _previouslyProgressed,
      position: position,
    );
    if (isTimelinePositionDiscontinuity(_lastPrefetchPosition, position) &&
        !positionReset) {
      _armSeekGrace();
    }
    if (positionReset) {
      // A decoder/source reset after a real first frame is not a user seek;
      // waiting through seek grace leaves the player stuck on a bad route.
      _seekGraceUntil = null;
      _stallTimer?.cancel();
      _stallTimer = null;
    }
    _stableRoutePlayback = Duration.zero;
    _lastRouteHealthPosition = position;
    _stablePrefetchPlayback = Duration.zero;
    _lastPrefetchPosition = position;
    final seekGrace = _seekGraceUntil;
    if (!positionReset &&
        seekGrace != null &&
        DateTime.now().isBefore(seekGrace)) {
      return;
    }
    if (_prefetchTimer != null || _prefetchStarted) {
      _stopTimelinePrefetch(clearSource: false);
    }
    if (!_opened || _stallTimer != null) return;
    final startupDeadline = _startupFailoverDeadline;
    final startupRecovery =
        !positionReset &&
        !_previouslyProgressed &&
        startupDeadline != null &&
        DateTime.now().isBefore(startupDeadline);
    _stallTimer = Timer(
      startupRecovery
          ? playbackStartupBufferRecoveryDelay
          : bufferingRecoveryDelay(positionReset: positionReset),
      _downgradeAfterStall,
    );
  }

  void _resetProgressWatchdog([Duration? position]) {
    _watchdogPosition = position ?? _player.state.position;
    _watchdogAdvancedAt = DateTime.now();
  }

  void _resetRouteProgressWindow() {
    _routeProgressWindowStartedAt = null;
    _routeProgressWindowStartPosition = null;
  }

  void _watchPlaybackProgress() {
    final position = _player.state.position;
    final now = DateTime.now();
    if (position > Duration.zero &&
        _player.state.playing &&
        !_player.state.buffering) {
      _previouslyProgressed = true;
    }
    final resetAfterPlayback = isPlaybackPositionReset(
      previouslyProgressed: _previouslyProgressed,
      position: position,
    );
    if (resetAfterPlayback &&
        _opened &&
        !_isNearEnd &&
        _seekGraceUntil == null &&
        _stallTimer == null) {
      _stallTimer = Timer(playbackResetRecoveryDelay, () {
        _stallTimer = null;
        if (mounted &&
            _opened &&
            !_isNearEnd &&
            isPlaybackPositionReset(
              previouslyProgressed: _previouslyProgressed,
              position: _player.state.position,
            )) {
          unawaited(_tryAutoSwitch('线路解码重置'));
        }
      });
    }
    final progressWindowStartedAt = _routeProgressWindowStartedAt;
    final progressWindowStartPosition = _routeProgressWindowStartPosition;
    if (progressWindowStartedAt != null &&
        progressWindowStartPosition != null &&
        position >= progressWindowStartPosition &&
        isPlaybackProgressTooSlow(
          elapsed: now.difference(progressWindowStartedAt),
          progress: position - progressWindowStartPosition,
          playing: _player.state.playing,
          buffering: _player.state.buffering,
        ) &&
        !_isNearEnd) {
      _resetRouteProgressWindow();
      _resetProgressWatchdog(position);
      unawaited(_tryAutoSwitch('线路播放速度过低'));
      return;
    }
    final advanced =
        position < _watchdogPosition ||
        position - _watchdogPosition >= const Duration(milliseconds: 500);
    if (advanced ||
        !_opened ||
        !_player.state.playing ||
        _player.state.buffering ||
        _isNearEnd) {
      _watchdogPosition = position;
      _watchdogAdvancedAt = now;
      return;
    }
    if (isPlaybackProgressStalled(
      baselinePosition: _watchdogPosition,
      currentPosition: position,
      elapsed: now.difference(_watchdogAdvancedAt),
      opened: _opened,
      playing: _player.state.playing,
      buffering: _player.state.buffering,
      nearEnd: _isNearEnd,
    )) {
      _resetProgressWatchdog(position);
      unawaited(_tryAutoSwitch('线路播放停滞'));
    }
  }

  void _observeTimelinePrefetch(Duration position) {
    final previous = _lastPrefetchPosition;
    final discontinuity = isTimelinePositionDiscontinuity(previous, position);
    _stablePrefetchPlayback = timelinePrefetchStableDuration(
      accumulated: _stablePrefetchPlayback,
      previousPosition: previous,
      position: position,
      playing: _player.state.playing,
      buffering: _player.state.buffering,
    );
    _lastPrefetchPosition = position;
    final positionReset = isPlaybackPositionReset(
      previouslyProgressed: _previouslyProgressed,
      position: position,
    );
    if (discontinuity && !positionReset) _armSeekGrace();
    _scheduleTimelinePrefetch();
  }

  void _armSeekGrace() {
    _seekGraceUntil = DateTime.now().add(playbackSeekFailoverGrace);
    _stallTimer?.cancel();
    _stallTimer = Timer(playbackSeekFailoverGrace, _downgradeAfterStall);
  }

  void _scheduleTimelinePrefetch() {
    final prefetchUrl = _prefetchUrl;
    if (!_opened ||
        _player.state.buffering ||
        prefetchUrl == null ||
        _stablePrefetchPlayback < timelinePrefetchStabilityThreshold ||
        _prefetchStarted ||
        _prefetchTimer != null) {
      return;
    }
    _prefetchTimer = Timer(const Duration(milliseconds: 500), () {
      _prefetchTimer = null;
      if (!mounted ||
          !_opened ||
          _player.state.buffering ||
          _prefetchUrl != prefetchUrl) {
        return;
      }
      _prefetchStarted = true;
      unawaited(PlaybackProxy.instance.prefetchTimeline(prefetchUrl));
    });
  }

  void _stopTimelinePrefetch({required bool clearSource}) {
    _prefetchTimer?.cancel();
    _prefetchTimer = null;
    if (_prefetchStarted) PlaybackProxy.instance.stopPrefetch();
    _prefetchStarted = false;
    if (clearSource) _prefetchUrl = null;
  }

  Future<void> _downgradeAfterStall() async {
    _stallTimer = null;
    _seekGraceUntil = null;
    if (!_player.state.buffering || _isNearEnd) return;
    final real = _videoTracks.where((track) => track.id != 'auto').toList()
      ..sort(
        (left, right) => ((left.w ?? 0) * (left.h ?? 0)).compareTo(
          (right.w ?? 0) * (right.h ?? 0),
        ),
      );
    final currentIndex = real.indexWhere(
      (track) => track.id == _selectedTrackId,
    );
    if (_selectedTrackId != 'auto' && currentIndex > 0) {
      final next = real[currentIndex - 1];
      await _player.setVideoTrack(next);
      if (mounted) {
        setState(() => _selectedTrackId = next.id);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('网络波动，已自动降至 ${videoTrackLabel(next)}')),
        );
      }
      if (_player.state.buffering) {
        _stallTimer = Timer(const Duration(seconds: 7), _switchAfterStall);
      }
      return;
    }
    await _switchAfterStall();
  }

  bool get _isNearEnd {
    final duration = _player.state.duration;
    return duration > Duration.zero &&
        _player.state.position >= duration - const Duration(seconds: 3);
  }

  Future<void> _switchAfterStall() async {
    _stallTimer = null;
    if (!_player.state.buffering || _isNearEnd) return;
    await _tryAutoSwitch('线路持续缓冲');
  }

  Episode get _current => widget.playLines[_lineIndex].episodes[_episodeIndex];

  void _handleTracks(Tracks tracks) {
    final available = selectableVideoTracks(tracks.video);
    if (mounted) setState(() => _videoTracks = available);
    if (!_preferenceApplied && available.length > 1) {
      _preferenceApplied = true;
      final preferred = choosePlaybackStartVideoTrack(
        tracks.video,
        widget.appState.qualityPreference,
      );
      _selectVideoTrack(preferred);
    }
  }

  Future<void> _selectVideoTrack(VideoTrack track) async {
    HapticFeedback.selectionClick();
    final selected = track.id == 'auto'
        ? choosePlaybackStartVideoTrack(_videoTracks, 'auto')
        : track;
    await _player.setVideoTrack(selected);
    if (mounted) setState(() => _selectedTrackId = selected.id);
  }

  Future<void> _setPlaybackRate(double rate) async {
    HapticFeedback.selectionClick();
    await _player.setRate(rate);
    if (mounted) setState(() => _playbackRate = rate);
  }

  Future<void> _applyResumeIfReady() async {
    if (!_opened || _resumeApplied || _resumeSeekInFlight) return;
    final resume = _resume;
    if (!shouldApplyResumeSeek(
      resume,
      _current.name,
      _player.state.duration,
      _player.state.position,
    )) {
      return;
    }
    final target = Duration(milliseconds: (resume!.progress * 1000).round());
    if (_player.state.position >= target - const Duration(seconds: 2)) {
      _resumeApplied = true;
      return;
    }
    _resumeSeekInFlight = true;
    try {
      await _player.seek(target);
    } finally {
      _resumeSeekInFlight = false;
    }
  }

  Future<bool> _openCurrent({
    bool allowAutoSwitch = true,
    bool scheduleStartupCheck = true,
    DateTime? deadline,
  }) async {
    _opened = false;
    _stopTimelinePrefetch(clearSource: true);
    _lastPrefetchPosition = null;
    _stablePrefetchPlayback = Duration.zero;
    _lastRouteHealthPosition = null;
    _stableRoutePlayback = Duration.zero;
    _previouslyProgressed = false;
    _resetRouteProgressWindow();
    _resumeApplied = false;
    _resumeSeekInFlight = false;
    _seekGraceUntil = null;
    _resetProgressWatchdog(Duration.zero);
    _stallTimer?.cancel();
    _stallTimer = null;
    _startupTimer?.cancel();
    _startupTimer = null;
    setState(() {
      _loading = true;
      _error = null;
      _preferenceApplied = false;
      _videoTracks = [VideoTrack.auto()];
      _selectedTrackId = 'auto';
    });
    try {
      // Cancel a previous route before opening a fallback. Without this, a
      // stalled native open can keep its socket alive while the next route is
      // already being selected, serializing both opens behind the bad line.
      try {
        await _player.stop().timeout(const Duration(seconds: 1));
      } catch (_) {}
      var url = _current.url;
      Map<String, String>? headers = _current.headers;
      if (url.startsWith('videoget-rule:') ||
          url.startsWith('videoget-short:')) {
        final resolved = await widget.appState.engine.play(
          _current.sourceId ?? widget.item.sourceId,
          url,
          widget.appState.sources,
        );
        url = resolved.url;
        headers = resolved.headers;
      }
      if (url.startsWith('http://') || url.startsWith('https://')) {
        final proxyUrl = await PlaybackProxy.instance.urlFor(
          url,
          headers: headers,
          filterAds: true,
          maxHeight: widget.appState.isEmulator ? 720 : null,
        );
        _prefetchUrl = proxyUrl;
        final resume = _resume;
        final resumeStart = shouldResumePlayback(resume, _current.name)
            ? Duration(milliseconds: (resume!.progress * 1000).round())
            : null;
        final sourceUri = Uri.tryParse(url);
        final sourcePort = sourceUri?.port ?? 0;
        if (sourceUri?.scheme.toLowerCase() == 'https' &&
            sourcePort > 0 &&
            sourcePort != 443) {
          throw StateError('线路媒体端口不可用');
        }
        // Warm the first segment in the background so mpv can use the local
        // cache when it is ready, while keeping native decoder validation as
        // the source of truth for routes whose upstream is merely slow.
        if (resumeStart == null || resumeStart < const Duration(seconds: 10)) {
          unawaited(PlaybackProxy.instance.warmUpFirstSegment(proxyUrl));
        }
        url = proxyUrl.toString();
        headers = null;
      }
      // mpv properties must be set before opening the URL. Otherwise the
      // first HLS demuxer inherits defaults and the cache never reaches the
      // long-video tuning above.
      await _configureMpvCache();
      final resume = _resume;
      final resumeStart = shouldResumePlayback(resume, _current.name)
          ? Duration(milliseconds: (resume!.progress * 1000).round())
          : null;
      // Media.start is applied by mpv while loading. The stream-driven seek
      // below verifies the resulting position and compensates if a source
      // resets its timeline after open() returns.
      await _player
          .open(Media(url, httpHeaders: headers, start: resumeStart))
          .timeout(
            playbackTimeoutWithin(
              DateTime.now(),
              deadline,
              const Duration(seconds: 8),
            ),
          );
      _opened = true;
      await _player.setRate(_playbackRate);
      await _applyResumeIfReady();
      if (scheduleStartupCheck) {
        // Some encrypted HLS routes need several seconds for the key and first
        // media segment before the decoder exposes duration.  Keep the route
        // alive long enough to verify real progress instead of switching a
        // healthy but slow line while its first frame is still arriving.
        _startupTimer = Timer(const Duration(seconds: 16), () {
          if (_opened &&
              needsStartupFailover(
                duration: _player.state.duration,
                playing: _player.state.playing,
                buffering: _player.state.buffering,
                continuousProgress: _stableRoutePlayback,
              ) &&
              !_isNearEnd) {
            unawaited(_tryAutoSwitch('线路首播超时'));
          }
        });
      }
      if (_player.state.buffering) _handleBuffering(true);
      if (!_player.state.buffering) _scheduleTimelinePrefetch();
      if (mounted) setState(() => _loading = false);
      return true;
    } catch (error) {
      _opened = false;
      if (!_failedLines.contains(_lineIndex)) {
        RouteEngine.recordPlaybackFailure(_current);
        _failedLines.add(_lineIndex);
      }
      if (allowAutoSwitch && await _tryAutoSwitch(error.toString())) {
        return true;
      }
      if (!mounted) return false;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
      return false;
    }
  }

  Future<bool> _tryAutoSwitch(String reason) async {
    if (_autoSwitching || widget.playLines.length < 2) return false;
    _autoSwitching = true;
    final startupDeadline = _startupFailoverDeadline;
    final deadline =
        startupDeadline != null && DateTime.now().isBefore(startupDeadline)
        ? startupDeadline
        : DateTime.now().add(playbackFailoverBudget);
    final originalLine = _lineIndex;
    final episodeName = _current.name;
    final fallbackIndex = _episodeIndex;
    final position = _player.state.position;
    final duration = _player.state.duration;
    var previousLine = originalLine;
    var attemptStartPosition = position;
    try {
      await _saveProgress();
      if (!_failedLines.contains(_lineIndex)) {
        RouteEngine.recordPlaybackFailure(_current);
        _failedLines.add(_lineIndex);
      }
      final targets = failoverTargets(
        widget.playLines,
        originalLine,
        _failedLines,
        episodeName,
        fallbackIndex,
      );
      for (final target in targets) {
        if (!DateTime.now().isBefore(deadline)) break;
        final nextLine = target.lineIndex;
        final nextEpisode = target.episodeIndex;
        final oldLineName = widget.playLines[previousLine].name;
        final newLineName = widget.playLines[nextLine].name;
        if (position > Duration.zero) {
          _resume = HistoryItem(
            item: widget.item,
            lineName: widget.playLines[nextLine].name,
            episodeName: widget.playLines[nextLine].episodes[nextEpisode].name,
            progress: position.inMilliseconds / 1000,
            duration: duration.inMilliseconds / 1000,
            watchedAt: DateTime.now().millisecondsSinceEpoch,
          );
        }
        if (mounted) {
          setState(() {
            _lineIndex = nextLine;
            _episodeIndex = nextEpisode;
          });
        } else {
          _lineIndex = nextLine;
          _episodeIndex = nextEpisode;
        }
        final opened = await _openCurrent(
          allowAutoSwitch: false,
          scheduleStartupCheck: false,
          deadline: deadline,
        );
        final ready = opened && await _waitForPlaybackReady(deadline: deadline);
        final finalPosition = _player.state.position;
        debugPrint(
          'PLAYBACK_FAILOVER reason=$reason old=$oldLineName new=$newLineName '
          'startMs=${attemptStartPosition.inMilliseconds} '
          'finalMs=${finalPosition.inMilliseconds} ready=$ready',
        );
        if (ready) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  '$reason，已切换至 ${widget.playLines[nextLine].name}',
                ),
              ),
            );
          }
          return true;
        }
        previousLine = nextLine;
        attemptStartPosition = finalPosition;
        if (!_failedLines.contains(nextLine)) {
          RouteEngine.recordPlaybackFailure(_current);
          _failedLines.add(nextLine);
        }
      }
      if (mounted) {
        setState(() {
          _error = '所有线路启动超时，请重试';
          _loading = false;
        });
      }
      return false;
    } finally {
      _autoSwitching = false;
    }
  }

  Future<bool> _waitForPlaybackReady({DateTime? deadline}) async {
    final readyDeadline =
        deadline ?? DateTime.now().add(const Duration(seconds: 10));
    Duration? previousPosition;
    var continuousProgress = Duration.zero;
    while (mounted && _opened && DateTime.now().isBefore(readyDeadline)) {
      final position = _player.state.position;
      continuousProgress = continuousPlaybackProgress(
        accumulated: continuousProgress,
        previousPosition: previousPosition,
        position: position,
        playing: _player.state.playing,
        buffering: _player.state.buffering,
      );
      previousPosition = position;
      if (hasVerifiedPlaybackProgress(
        duration: _player.state.duration,
        playing: _player.state.playing,
        buffering: _player.state.buffering,
        continuousProgress: continuousProgress,
        threshold: playbackReadyProgressThreshold,
      )) {
        return true;
      }
      final remaining = readyDeadline.difference(DateTime.now());
      if (remaining <= Duration.zero) break;
      await Future<void>.delayed(
        remaining < const Duration(milliseconds: 200)
            ? remaining
            : const Duration(milliseconds: 200),
      );
    }
    return false;
  }

  Future<void> _saveProgress() async {
    final position = _player.state.position.inMilliseconds / 1000.0;
    final duration = _player.state.duration.inMilliseconds / 1000.0;
    if (position <= 0) return;
    final item = widget.item;
    final lineName = widget.playLines[_lineIndex].name;
    final episodeName = _current.name;
    _saveQueue = _saveQueue.then(
      (_) => widget.appState.updateProgress(
        item,
        position,
        duration,
        lineName,
        episodeName,
      ),
    );
    await _saveQueue;
  }

  Future<void> _selectLine(int index) async {
    if (index == _lineIndex) return;
    final episodeName = _current.name;
    final nextEpisodeIndex = matchingEpisodeIndex(
      widget.playLines[index],
      episodeName,
      _episodeIndex,
    );
    await _saveProgress();
    _resume = null;
    HapticFeedback.selectionClick();
    setState(() {
      _lineIndex = index;
      _episodeIndex = nextEpisodeIndex;
    });
    _failedLines.remove(index);
    _openCurrent();
  }

  Future<void> _selectEpisode(int index) async {
    if (index == _episodeIndex) return;
    await _saveProgress();
    _resume = null;
    HapticFeedback.selectionClick();
    setState(() => _episodeIndex = index);
    _failedLines.remove(_lineIndex);
    _openCurrent();
  }

  void _retryPlayback() {
    _failedLines.clear();
    _openCurrent();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _stallTimer?.cancel();
    _startupTimer?.cancel();
    _progressWatchdogTimer?.cancel();
    _stopTimelinePrefetch(clearSource: true);
    _tracksSubscription?.cancel();
    _trackSubscription?.cancel();
    _durationSubscription?.cancel();
    _positionSubscription?.cancel();
    _bufferingSubscription?.cancel();
    _logSubscription?.cancel();
    // Capture the current position before disposing mpv. Calling dispose
    // first resets the state and used to overwrite history with 0 seconds.
    _saveProgress();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return PopScope<Object?>(
      canPop: _allowPop,
      onPopInvokedWithResult: _handlePop,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          title: const SizedBox.shrink(),
        ),
        body: SafeArea(top: false, child: Center(child: _buildVideo(colors))),
      ),
    );
  }

  Future<void> _handlePop(bool didPop, Object? result) async {
    if (didPop || _allowPop) return;
    await _saveProgress();
    if (!mounted) return;
    setState(() => _allowPop = true);
    Navigator.of(context).pop(result);
  }

  Widget _buildVideo(ColorScheme colors) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        alignment: Alignment.center,
        children: [
          MaterialVideoControlsTheme(
            normal: const MaterialVideoControlsThemeData(
              visibleOnMount: true,
              topButtonBar: [],
              bottomButtonBar: [
                MaterialFullscreenButton(
                  key: ValueKey('player-fullscreen-toggle'),
                ),
              ],
            ),
            fullscreen: MaterialVideoControlsThemeData(
              visibleOnMount: true,
              displaySeekBar: true,
              seekOnDoubleTap: false,
              seekGesture: false,
              volumeGesture: true,
              brightnessGesture: true,
              gesturesEnabledWhileControlsVisible: true,
              speedUpOnLongPress: false,
              initialVolume: _volume,
              initialBrightness: _brightness,
              onVolumeChanged: _setSystemVolume,
              onBrightnessChanged: _setSystemBrightness,
              seekBarMargin: const EdgeInsets.only(
                left: 16,
                right: 16,
                bottom: 42,
              ),
              bottomButtonBarMargin: const EdgeInsets.only(
                left: 16,
                right: 8,
                bottom: 42,
              ),
              topButtonBar: [
                _FullscreenHeader(
                  title: widget.item.title,
                  episode: _current.name,
                ),
              ],
              bottomButtonBar: [
                const MaterialPositionIndicator(),
                const Spacer(),
                MaterialCustomButton(
                  icon: const Icon(Icons.tune_rounded),
                  onPressed: _showFullscreenSettings,
                ),
                const MaterialFullscreenButton(
                  key: ValueKey('player-fullscreen-toggle'),
                ),
              ],
            ),
            child: Video(
              controller: _videoController,
              controls: _buildVideoControls,
            ),
          ),
          AnimatedSwitcher(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 180),
            child: _loading
                ? const DecoratedBox(
                    key: ValueKey('loading'),
                    decoration: BoxDecoration(color: Color(0x66000000)),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : const SizedBox.shrink(key: ValueKey('ready')),
          ),
          if (_error != null)
            Positioned.fill(
              child: ColoredBox(
                color: const Color(0xE6000000),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.error_outline_rounded,
                          color: colors.error,
                          size: 36,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _error!,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: colors.error, fontSize: 12),
                        ),
                        const SizedBox(height: 10),
                        FilledButton.icon(
                          onPressed: _retryPlayback,
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _togglePlayback() async {
    HapticFeedback.selectionClick();
    await _player.playOrPause();
  }

  void _setSystemBrightness(double value) {
    _brightness = value;
    unawaited(SystemPlaybackControls.setBrightness(value));
  }

  void _setSystemVolume(double value) {
    _volume = value;
    unawaited(SystemPlaybackControls.setVolume(value));
  }

  Widget _buildVideoControls(VideoState state) {
    return LayoutBuilder(
      builder: (gestureContext, constraints) => Listener(
        key: const ValueKey('player-double-tap-surface'),
        behavior: HitTestBehavior.translucent,
        onPointerDown: (event) => _handlePointerDown(
          event,
          Size(constraints.maxWidth, constraints.maxHeight),
        ),
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onLongPressStart: _startLongPressSpeedBoost,
          onLongPressEnd: _endLongPressSpeedBoost,
          child: MaterialVideoControls(state),
        ),
      ),
    );
  }

  void _startLongPressSpeedBoost(LongPressStartDetails details) {
    if (_longPressPreviousRate != null) return;
    _longPressPreviousRate = _player.state.rate;
    HapticFeedback.mediumImpact();
    unawaited(_player.setRate(2.0));
  }

  void _endLongPressSpeedBoost(LongPressEndDetails details) {
    final previousRate = _longPressPreviousRate;
    _longPressPreviousRate = null;
    if (previousRate != null) unawaited(_player.setRate(previousRate));
  }

  void _handlePointerDown(PointerDownEvent event, Size size) {
    if (!isPlaybackToggleRegion(event.localPosition, size)) {
      _lastPointerDown = null;
      _lastPointerPosition = null;
      return;
    }
    final now = event.timeStamp;
    final lastTime = _lastPointerDown;
    final lastPosition = _lastPointerPosition;
    _lastPointerDown = now;
    _lastPointerPosition = event.localPosition;
    if (!isPlaybackToggleDoubleTap(
      lastTime,
      lastPosition,
      now,
      event.localPosition,
    )) {
      return;
    }
    _lastPointerDown = null;
    _lastPointerPosition = null;
    _togglePlayback();
  }

  Future<void> _showFullscreenSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: math.min(MediaQuery.sizeOf(sheetContext).height * .72, 620),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(sheetContext),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const _PlayerSettingHeading('倍速'),
                Wrap(
                  spacing: 8,
                  children: _speedOptions
                      .map(
                        (rate) => ChoiceChip(
                          label: Text(_rateLabel(rate)),
                          selected: rate == _playbackRate,
                          onSelected: (_) {
                            Navigator.pop(sheetContext);
                            _setPlaybackRate(rate);
                          },
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 18),
                const _PlayerSettingHeading('清晰度'),
                ..._videoTracks.map(
                  (track) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      track.id == _selectedTrackId
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_off_rounded,
                    ),
                    title: Text(videoTrackLabel(track)),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _selectVideoTrack(track);
                    },
                  ),
                ),
                const SizedBox(height: 8),
                const _PlayerSettingHeading('线路'),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  children: widget.playLines.asMap().entries.map((entry) {
                    return ChoiceChip(
                      label: Text(entry.value.name),
                      selected: entry.key == _lineIndex,
                      onSelected: (_) {
                        Navigator.pop(sheetContext);
                        _selectLine(entry.key);
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 18),
                _PlayerSettingHeading(
                  '选集 · ${widget.playLines[_lineIndex].name}',
                ),
                const SizedBox(height: 8),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 120,
                    mainAxisExtent: 42,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: widget.playLines[_lineIndex].episodes.length,
                  itemBuilder: (_, index) => OutlinedButton(
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      _selectEpisode(index);
                    },
                    style: OutlinedButton.styleFrom(
                      backgroundColor: index == _episodeIndex
                          ? Theme.of(context).colorScheme.primaryContainer
                          : null,
                    ),
                    child: Text(
                      widget.playLines[_lineIndex].episodes[index].name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PlayerSettingHeading extends StatelessWidget {
  final String label;
  const _PlayerSettingHeading(this.label);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
  );
}

class _FullscreenHeader extends StatefulWidget {
  final String title;
  final String episode;
  const _FullscreenHeader({required this.title, required this.episode});

  @override
  State<_FullscreenHeader> createState() => _FullscreenHeaderState();
}

class _FullscreenHeaderState extends State<_FullscreenHeader> {
  final Battery _battery = Battery();
  Timer? _timer;
  int? _batteryLevel;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _readBattery();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  Future<void> _readBattery() async {
    try {
      final level = await _battery.batteryLevel;
      if (mounted) setState(() => _batteryLevel = level);
    } catch (_) {
      // Desktop/web test runners do not expose a battery plugin.
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final time =
        '${_now.hour.toString().padLeft(2, '0')}:${_now.minute.toString().padLeft(2, '0')}';
    final level = _batteryLevel;
    final icon = level == null || level > 80
        ? Icons.battery_full_rounded
        : level > 35
        ? Icons.battery_5_bar_rounded
        : Icons.battery_2_bar_rounded;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          time,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
        const SizedBox(width: 8),
        if (level != null) ...[
          Icon(icon, size: 18),
          const SizedBox(width: 2),
          Text('$level%', style: const TextStyle(fontSize: 12)),
          const SizedBox(width: 14),
        ],
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: Text(
            '${widget.title} · ${widget.episode}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}
