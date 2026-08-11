import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../models/models.dart';
import '../services/app_state.dart';
import '../services/quality_selector.dart';
import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';

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
  StreamSubscription<Tracks>? _tracksSubscription;
  StreamSubscription<Track>? _trackSubscription;
  List<VideoTrack> _videoTracks = [VideoTrack.auto()];
  String _selectedTrackId = 'auto';
  bool _preferenceApplied = false;
  double _playbackRate = 1.0;

  @override
  void initState() {
    super.initState();
    _lineIndex = widget.lineIndex;
    _episodeIndex = widget.episodeIndex;
    _player = Player();
    _videoController = VideoController(_player);
    _tracksSubscription = _player.stream.tracks.listen(_handleTracks);
    _trackSubscription = _player.stream.track.listen((track) {
      if (mounted) setState(() => _selectedTrackId = track.video.id);
    });
    _openCurrent();
    _saveTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _saveProgress(),
    );
  }

  Episode get _current => widget.playLines[_lineIndex].episodes[_episodeIndex];

  void _handleTracks(Tracks tracks) {
    final available = selectableVideoTracks(tracks.video);
    if (mounted) setState(() => _videoTracks = available);
    if (!_preferenceApplied && available.length > 1) {
      _preferenceApplied = true;
      final preferred = choosePreferredVideoTrack(
        tracks.video,
        widget.appState.qualityPreference,
      );
      _selectVideoTrack(preferred);
    }
  }

  Future<void> _selectVideoTrack(VideoTrack track) async {
    HapticFeedback.selectionClick();
    await _player.setVideoTrack(track);
    if (mounted) setState(() => _selectedTrackId = track.id);
  }
  Future<void> _setPlaybackRate(double rate) async {
    HapticFeedback.selectionClick();
    await _player.setRate(rate);
    if (mounted) setState(() => _playbackRate = rate);
  }

  Future<void> _openCurrent() async {
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
      await _player.open(Media(url, httpHeaders: headers));
      final resume = widget.appState.getResume(widget.item);
      if (resume != null &&
          resume.episodeName == _current.name &&
          resume.progress > 0 &&
          resume.progress < resume.duration - 15) {
        await _player.seek(
          Duration(milliseconds: (resume.progress * 1000).round()),
        );
      }
      if (mounted) setState(() => _loading = false);
    } catch (error) {
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

  void _selectLine(int index) {
    if (index == _lineIndex) return;
    HapticFeedback.selectionClick();
    setState(() {
      _lineIndex = index;
      _episodeIndex = 0;
    });
    _openCurrent();
  }

  void _selectEpisode(int index) {
    if (index == _episodeIndex) return;
    HapticFeedback.selectionClick();
    setState(() => _episodeIndex = index);
    _openCurrent();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _tracksSubscription?.cancel();
    _trackSubscription?.cancel();
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
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            Text(
              _current.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<VideoTrack>(
            tooltip: '切换清晰度',
            icon: const Icon(Icons.hd_outlined),
            onSelected: _selectVideoTrack,
            itemBuilder: (context) => _videoTracks
                .map(
                  (track) => PopupMenuItem(
                    value: track,
                    child: Row(
                      children: [
                        SizedBox(
                          width: 26,
                          child: track.id == _selectedTrackId
                              ? Icon(
                                  Icons.check_rounded,
                                  size: 18,
                                  color: colors.primary,
                                )
                              : null,
                        ),
                        Expanded(child: Text(videoTrackLabel(track))),
                      ],
                    ),
                  ),
                )
                .toList(),
          ),
          PopupMenuButton<double>(
            tooltip: '倍速播放',
            icon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.speed_rounded, size: 18),
                const SizedBox(width: 2),
                Text(
                    '$_playbackRate' 'x',
                    style: const TextStyle(fontSize: 12)),
              ],
            ),
            onSelected: _setPlaybackRate,
            itemBuilder: (context) => [1.0, 1.5, 2.0]
                .map(
                  (rate) => PopupMenuItem(
                    value: rate,
                    child: Row(
                      children: [
                        SizedBox(
                          width: 26,
                          child: rate == _playbackRate
                              ? Icon(Icons.check_rounded,
                                  size: 18, color: colors.primary)
                              : null,
                        ),
                        Text('${rate.toStringAsFixed(1)}x'),
                      ],
                    ),
                  ),
                )
                .toList(),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final landscape = constraints.maxWidth > constraints.maxHeight;
            final video = _buildVideo(colors);
            final playlist = _buildPlaylist(colors);
            if (landscape) {
              return Row(
                children: [
                  Expanded(child: Center(child: video)),
                  DecoratedBox(
                    decoration: const BoxDecoration(
                      color: AppColors.surface,
                      border: Border(
                        left: BorderSide(color: AppColors.outline),
                      ),
                    ),
                    child: SizedBox(
                      width: math.min(360, constraints.maxWidth * 0.38),
                      child: playlist,
                    ),
                  ),
                ],
              );
            }
            return Column(
              children: [
                video,
                Expanded(child: playlist),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildVideo(ColorScheme colors) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Video(controller: _videoController, controls: MaterialVideoControls),
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

  Widget _buildPlaylist(ColorScheme colors) {
    final episodes = widget.playLines[_lineIndex].episodes;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SectionHeading(
          title: widget.playLines.length > 1 ? '播放线路' : '当前线路',
          detail: widget.playLines[_lineIndex].name,
        ),
        if (widget.playLines.length > 1) ...[
          const SizedBox(height: 10),
          SizedBox(
            height: 42,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: widget.playLines.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) => ChoiceChip(
                label: Text(widget.playLines[index].name),
                selected: index == _lineIndex,
                onSelected: (_) => _selectLine(index),
              ),
            ),
          ),
        ],
        const SizedBox(height: 22),
        SectionHeading(title: '剧集', detail: '${episodes.length} 集'),
        const SizedBox(height: 10),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 104,
            mainAxisExtent: 44,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: episodes.length,
          itemBuilder: (context, index) {
            final selected = index == _episodeIndex;
            return OutlinedButton(
              onPressed: () => _selectEpisode(index),
              style: OutlinedButton.styleFrom(
                backgroundColor: selected
                    ? colors.primaryContainer
                    : AppColors.surfaceRaised,
                foregroundColor: selected
                    ? colors.onPrimaryContainer
                    : colors.onSurface,
                padding: const EdgeInsets.symmetric(horizontal: 6),
              ),
              child: Text(
                episodes[index].name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            );
          },
        ),
      ],
    );
  }
}
