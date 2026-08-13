import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../models/models.dart';
import '../services/app_state.dart';
import '../services/quality_selector.dart';
import '../theme/app_theme.dart';

bool shouldResumePlayback(HistoryItem? resume, String episodeName) {
  if (resume == null ||
      resume.episodeName != episodeName ||
      resume.progress <= 0) {
    return false;
  }
  return resume.duration <= 0 || resume.progress < resume.duration - 15;
}

class PlayerScreen extends StatefulWidget {
  final AppState appState;
  final MediaItem item;
  final List<PlayLine> playLines;
  final int lineIndex;
  final int episodeIndex;

  const PlayerScreen({
    super.key,
    required this.appState,
    required this.item,
    required this.playLines,
    required this.lineIndex,
    required this.episodeIndex,
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
  StreamSubscription<Tracks>? _tracksSubscription;
  StreamSubscription<Track>? _trackSubscription;
  StreamSubscription<bool>? _bufferingSubscription;
  List<VideoTrack> _videoTracks = [VideoTrack.auto()];
  String _selectedTrackId = 'auto';
  bool _preferenceApplied = false;
  bool _opened = false;
  double _playbackRate = 1.0;

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
    _player = Player(
      configuration: const PlayerConfiguration(bufferSize: 128 * 1024 * 1024),
    );
    _videoController = VideoController(_player);
    _tracksSubscription = _player.stream.tracks.listen(_handleTracks);
    _trackSubscription = _player.stream.track.listen((track) {
      if (mounted) setState(() => _selectedTrackId = track.video.id);
    });
    _bufferingSubscription = _player.stream.buffering.listen(_handleBuffering);
    _openCurrent();
    _saveTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _saveProgress(),
    );
  }

  Future<void> _configureMpvCache() async {
    final platform = _player.platform;
    if (platform is NativePlayer) {
      await Future.wait([
        platform.setProperty('cache-secs', '90'),
        platform.setProperty('demuxer-readahead-secs', '45'),
        platform.setProperty('cache-pause', 'yes'),
        platform.setProperty('cache-pause-wait', '3'),
        platform.setProperty('network-timeout', '20'),
      ]);
    }
  }

  void _handleBuffering(bool buffering) {
    if (!buffering) {
      _stallTimer?.cancel();
      _stallTimer = null;
      return;
    }
    if (!_opened || _stallTimer != null) return;
    _stallTimer = Timer(const Duration(seconds: 4), _downgradeAfterStall);
  }

  Future<void> _downgradeAfterStall() async {
    _stallTimer = null;
    if (!_player.state.buffering || _selectedTrackId == 'auto') return;
    final real = _videoTracks.where((track) => track.id != 'auto').toList()
      ..sort(
        (left, right) => ((left.w ?? 0) * (left.h ?? 0)).compareTo(
          (right.w ?? 0) * (right.h ?? 0),
        ),
      );
    final currentIndex = real.indexWhere(
      (track) => track.id == _selectedTrackId,
    );
    final next = currentIndex > 0 ? real[currentIndex - 1] : VideoTrack.auto();
    await _player.setVideoTrack(next);
    if (mounted) {
      setState(() => _selectedTrackId = next.id);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            next.id == 'auto'
                ? '网络波动，已恢复自动画质'
                : '网络波动，已自动降至 ${videoTrackLabel(next)}',
          ),
        ),
      );
    }
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

  Future<void> _openCurrent() async {
    _opened = false;
    _stallTimer?.cancel();
    _stallTimer = null;
    setState(() {
      _loading = true;
      _error = null;
      _preferenceApplied = false;
      _videoTracks = [VideoTrack.auto()];
      _selectedTrackId = 'auto';
    });
    try {
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
      // mpv properties must be set before opening the URL. Otherwise the
      // first HLS demuxer inherits defaults and the cache never reaches the
      // long-video tuning above.
      await _configureMpvCache();
      await _player.open(Media(url, httpHeaders: headers));
      _opened = true;
      await _player.setRate(_playbackRate);
      final resume = widget.appState.getResume(widget.item);
      if (resume != null && shouldResumePlayback(resume, _current.name)) {
        await _player.seek(
          Duration(milliseconds: (resume.progress * 1000).round()),
        );
      }
      if (mounted) setState(() => _loading = false);
    } catch (error) {
      _opened = false;
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _saveProgress() async {
    final position = _player.state.position.inMilliseconds / 1000.0;
    final duration = _player.state.duration.inMilliseconds / 1000.0;
    if (position <= 0) return;
    await widget.appState.updateProgress(
      widget.item,
      position,
      duration,
      widget.playLines[_lineIndex].name,
      _current.name,
    );
  }

  Future<void> _selectLine(int index) async {
    if (index == _lineIndex) return;
    await _saveProgress();
    HapticFeedback.selectionClick();
    setState(() {
      _lineIndex = index;
      _episodeIndex = 0;
    });
    _openCurrent();
  }

  Future<void> _selectEpisode(int index) async {
    if (index == _episodeIndex) return;
    await _saveProgress();
    HapticFeedback.selectionClick();
    setState(() => _episodeIndex = index);
    _openCurrent();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _stallTimer?.cancel();
    _tracksSubscription?.cancel();
    _trackSubscription?.cancel();
    _bufferingSubscription?.cancel();
    // Capture the current position before disposing mpv. Calling dispose
    // first resets the state and used to overwrite history with 0 seconds.
    _saveProgress();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const SizedBox.shrink(),
      ),
      body: SafeArea(top: false, child: Center(child: _buildVideo(colors))),
    );
  }

  Widget _buildVideo(ColorScheme colors) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        alignment: Alignment.center,
        children: [
          MaterialVideoControlsTheme(
            normal: const MaterialVideoControlsThemeData(
              topButtonBar: [],
              bottomButtonBar: [MaterialFullscreenButton()],
            ),
            fullscreen: MaterialVideoControlsThemeData(
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
                const MaterialFullscreenButton(),
              ],
            ),
            child: Video(
              controller: _videoController,
              controls: MaterialVideoControls,
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
                          onPressed: _openCurrent,
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
        Expanded(
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
