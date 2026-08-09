import 'dart:async';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../models/models.dart';
import '../services/app_state.dart';
import '../services/quality_selector.dart';

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
    await _player.setVideoTrack(track);
    if (mounted) setState(() => _selectedTrackId = track.id);
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
      if (url.startsWith('videoget-rule:')) {
        final resolved = await widget.appState.api.play(
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
      setState(() => _loading = false);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _saveProgress() async {
    final position = _player.state.position.inMilliseconds / 1000.0;
    final duration = _player.state.duration.inMilliseconds / 1000.0;
    if (position > 0) {
      await widget.appState.updateProgress(
        widget.item,
        position,
        duration,
        widget.playLines[_lineIndex].name,
        _current.name,
      );
    }
  }

  void _selectLine(int index) {
    setState(() {
      _lineIndex = index;
      _episodeIndex = 0;
    });
    _openCurrent();
  }

  void _selectEpisode(int index) {
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
    final theme = Theme.of(context);
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
              style: const TextStyle(fontSize: 16),
            ),
            Text(
              _current.name,
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<VideoTrack>(
            tooltip: '切换清晰度',
            icon: const Icon(Icons.high_quality),
            onSelected: _selectVideoTrack,
            itemBuilder: (context) => _videoTracks.map((track) {
              return PopupMenuItem(
                value: track,
                child: Row(
                  children: [
                    SizedBox(
                      width: 24,
                      child: track.id == _selectedTrackId
                          ? const Icon(Icons.check, size: 18)
                          : null,
                    ),
                    Expanded(child: Text(videoTrackLabel(track))),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Video(
                    controller: _videoController,
                    controls: MaterialVideoControls,
                  ),
                  if (_loading) const CircularProgressIndicator(),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.error_outline,
                            color: theme.colorScheme.error,
                            size: 40,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: theme.colorScheme.error,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 8),
                          FilledButton(
                            onPressed: _openCurrent,
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (widget.playLines.length > 1) ...[
                    Text(
                      '播放线路',
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: widget.playLines.asMap().entries.map((entry) {
                        return ChoiceChip(
                          label: Text(entry.value.name),
                          selected: entry.key == _lineIndex,
                          onSelected: (_) => _selectLine(entry.key),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 16),
                  ],
                  Text(
                    '剧集',
                    style: TextStyle(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: widget.playLines[_lineIndex].episodes
                        .asMap()
                        .entries
                        .map((entry) {
                          final selected = entry.key == _episodeIndex;
                          return SizedBox(
                            width: 72,
                            child: OutlinedButton(
                              onPressed: () => _selectEpisode(entry.key),
                              style: OutlinedButton.styleFrom(
                                backgroundColor: selected
                                    ? theme.colorScheme.primaryContainer
                                    : null,
                                foregroundColor: selected
                                    ? theme.colorScheme.onPrimaryContainer
                                    : null,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 8,
                                ),
                                textStyle: const TextStyle(fontSize: 12),
                              ),
                              child: Text(
                                entry.value.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          );
                        })
                        .toList(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
