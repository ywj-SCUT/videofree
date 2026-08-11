import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models/models.dart';
import '../services/app_state.dart';
import '../theme/app_theme.dart';
import 'detail_screen.dart';

const _openShorts = <MediaItem>[
  MediaItem(
    id: 'open-tears-of-steel',
    sourceId: 'open-cinema',
    sourceName: '开放影院',
    title: 'Tears of Steel',
    poster: 'assets/shorts/tears-of-steel.jpg',
    backdrop: 'assets/shorts/tears-of-steel.jpg',
    year: '2012',
    remarks: '科幻短片',
    category: MediaCategory.short,
    summary: '真人与视觉特效结合的开放科幻短片。',
    quality: '1080P',
    playLines: [
      PlayLine(
        name: '高清',
        episodes: [
          Episode(
            name: '正片',
            url:
                'https://archive.org/download/Tears-of-Steel/tears_of_steel_1080p.mp4',
          ),
        ],
      ),
    ],
  ),
  MediaItem(
    id: 'open-ai-workflow-demo',
    sourceId: 'open-cinema',
    sourceName: '开放影院',
    title: 'AI 影像工作流演示',
    poster: 'assets/shorts/ai-short-demo.jpg',
    backdrop: 'assets/shorts/ai-short-demo.jpg',
    year: '2025',
    remarks: 'AI 短视频示例',
    category: MediaCategory.aiShort,
    summary: '用于验证 AI 短视频分类、竖向浏览和播放链路的开放素材。',
    quality: '1080P',
    playLines: [
      PlayLine(
        name: '演示',
        episodes: [
          Episode(
            name: '正片',
            url:
                'https://archive.org/download/springopenmovie/springopenmovie.mp4',
          ),
        ],
      ),
    ],
  ),
];

class ShortsScreen extends StatefulWidget {
  final AppState appState;

  const ShortsScreen({super.key, required this.appState});

  @override
  State<ShortsScreen> createState() => _ShortsScreenState();
}

class _ShortsScreenState extends State<ShortsScreen>
    with WidgetsBindingObserver {
  late final Player _player;
  late final VideoController _videoController;
  final PageController _pageController = PageController();
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<bool>? _bufferingSubscription;
  StreamSubscription<String>? _errorSubscription;

  List<MediaItem> _items = [..._openShorts];
  int _currentIndex = 0;
  int _requestId = 0;
  bool _playing = false;
  bool _buffering = true;
  bool _refreshing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _player = Player();
    _videoController = VideoController(_player);
    _player.setPlaylistMode(PlaylistMode.single);
    _playingSubscription = _player.stream.playing.listen((value) {
      if (mounted) setState(() => _playing = value);
    });
    _bufferingSubscription = _player.stream.buffering.listen((value) {
      if (mounted) setState(() => _buffering = value);
    });
    _errorSubscription = _player.stream.error.listen((value) {
      if (mounted && value.isNotEmpty) setState(() => _error = value);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _activate(0));
    unawaited(_refreshFeed());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _player.pause();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _playingSubscription?.cancel();
    _bufferingSubscription?.cancel();
    _errorSubscription?.cancel();
    _pageController.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _refreshFeed() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      final responses = await Future.wait([
        widget.appState.engine.search(
          '',
          MediaCategory.short,
          widget.appState.sources,
        ),
        widget.appState.engine.search(
          '',
          MediaCategory.aiShort,
          widget.appState.sources,
        ),
      ]);
      if (!mounted) return;
      final byId = <String, MediaItem>{
        for (final item in _openShorts) '${item.sourceId}:${item.id}': item,
      };
      for (final item in responses.expand((response) => response.items)) {
        byId['${item.sourceId}:${item.id}'] = item;
      }
      setState(() => _items = byId.values.toList());
      _precacheNeighbors(_currentIndex);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _activate(int index) async {
    if (index < 0 || index >= _items.length) return;
    final requestId = ++_requestId;
    setState(() {
      _currentIndex = index;
      _buffering = true;
      _error = null;
    });
    await _player.stop();
    try {
      var item = _items[index];
      var lines = item.playLines ?? const <PlayLine>[];
      if (lines.isEmpty) {
        final detail = await widget.appState.engine.resolve(
          item,
          widget.appState.sources,
        );
        if (detail != null) {
          item = detail;
          lines = detail.playLines ?? const <PlayLine>[];
        }
      }
      final episodes = lines.expand((line) => line.episodes);
      if (episodes.isEmpty) throw Exception('该短视频暂无可用播放地址');
      final episode = episodes.first;
      var url = episode.url;
      var headers = episode.headers;
      if (url.startsWith('videoget-rule:')) {
        final resolved = await widget.appState.engine.play(
          episode.sourceId ?? item.sourceId,
          url,
          widget.appState.sources,
        );
        url = resolved.url;
        headers = resolved.headers;
      }
      if (!mounted || requestId != _requestId) return;
      await _player.open(Media(url, httpHeaders: headers), play: true);
    } catch (error) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _buffering = false;
        _error = error.toString().replaceFirst('Exception: ', '');
      });
    }
    _precacheNeighbors(index);
  }

  void _precacheNeighbors(int index) {
    for (final neighbor in [index - 1, index + 1]) {
      if (neighbor < 0 || neighbor >= _items.length) continue;
      final provider = _posterProvider(_items[neighbor].poster);
      if (provider != null) precacheImage(provider, context);
    }
  }

  ImageProvider<Object>? _posterProvider(String value) {
    if (value.isEmpty) return null;
    if (value.startsWith('assets/')) return AssetImage(value);
    return CachedNetworkImageProvider(value);
  }

  Future<void> _togglePlayback() async {
    HapticFeedback.selectionClick();
    if (_playing) {
      await _player.pause();
    } else if (_error == null) {
      await _player.play();
    } else {
      await _activate(_currentIndex);
    }
  }

  Future<void> _toggleFavorite(MediaItem item) async {
    HapticFeedback.selectionClick();
    await widget.appState.toggleFavorite(item);
    if (mounted) setState(() {});
  }

  Future<void> _openDetail(MediaItem item) async {
    await _player.pause();
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DetailScreen(appState: widget.appState, item: item),
      ),
    );
    if (mounted) await _activate(_currentIndex);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            controller: _pageController,
            scrollDirection: Axis.vertical,
            itemCount: _items.length,
            onPageChanged: (index) {
              HapticFeedback.selectionClick();
              unawaited(_activate(index));
            },
            itemBuilder: (context, index) => _ShortPage(
              item: _items[index],
              index: index,
              total: _items.length,
              active: index == _currentIndex,
              player: _videoController,
              playing: _playing,
              buffering: _buffering,
              error: _error,
              favorite: widget.appState.isFavorite(
                _items[index].sourceId,
                _items[index].id,
              ),
              onTogglePlayback: _togglePlayback,
              onFavorite: () => _toggleFavorite(_items[index]),
              onDetail: () => _openDetail(_items[index]),
            ),
          ),
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 12, 0),
              child: Row(
                children: [
                  const Text(
                    '短视频',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                  ),
                  const Spacer(),
                  IconButton.filledTonal(
                    tooltip: '刷新短视频',
                    onPressed: _refreshing ? null : _refreshFeed,
                    icon: _refreshing
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ShortPage extends StatelessWidget {
  final MediaItem item;
  final int index;
  final int total;
  final bool active;
  final VideoController player;
  final bool playing;
  final bool buffering;
  final String? error;
  final bool favorite;
  final VoidCallback onTogglePlayback;
  final VoidCallback onFavorite;
  final VoidCallback onDetail;

  const _ShortPage({
    required this.item,
    required this.index,
    required this.total,
    required this.active,
    required this.player,
    required this.playing,
    required this.buffering,
    required this.error,
    required this.favorite,
    required this.onTogglePlayback,
    required this.onFavorite,
    required this.onDetail,
  });

  @override
  Widget build(BuildContext context) {
    final poster = item.poster.startsWith('assets/')
        ? Image.asset(item.poster, fit: BoxFit.cover)
        : CachedNetworkImage(
            imageUrl: item.poster,
            fit: BoxFit.cover,
            errorWidget: (_, _, _) => const ColoredBox(
              color: AppColors.surfaceRaised,
              child: Icon(Icons.movie_filter_outlined, size: 56),
            ),
          );
    return Stack(
      fit: StackFit.expand,
      children: [
        poster,
        if (active)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTogglePlayback,
            child: Video(
              controller: player,
              controls: NoVideoControls,
              fit: BoxFit.cover,
            ),
          ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x55000000), Color(0x11000000), Color(0xE6000000)],
              stops: [0, .48, 1],
            ),
          ),
        ),
        Positioned(
          top: MediaQuery.paddingOf(context).top + 62,
          right: 16,
          child: Text(
            '${index + 1} / $total',
            style: const TextStyle(
              color: Color(0xCCFFFFFF),
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (active && (buffering || error != null))
          Center(
            child: error == null
                ? const CircularProgressIndicator(color: Colors.white)
                : FilledButton.tonalIcon(
                    onPressed: onTogglePlayback,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('重试播放'),
                  ),
          ),
        if (active && !buffering && !playing && error == null)
          Center(
            child: IconButton.filled(
              tooltip: '播放',
              onPressed: onTogglePlayback,
              iconSize: 34,
              icon: const Icon(Icons.play_arrow_rounded),
            ),
          ),
        Positioned(
          left: 18,
          right: 92,
          bottom: 104,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                item.sourceName,
                style: const TextStyle(
                  color: AppColors.secondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 26,
                  height: 1.06,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 9),
              Text(
                item.summary ?? item.remarks ?? '精选短视频',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFFD7DDE1),
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 7,
                children: [
                  _MetaChip(item.category.label),
                  _MetaChip(item.quality ?? '自动画质'),
                ],
              ),
            ],
          ),
        ),
        Positioned(
          right: 12,
          bottom: 100,
          child: Column(
            children: [
              _ActionButton(
                icon: favorite
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                label: favorite ? '已收藏' : '收藏',
                selected: favorite,
                onPressed: onFavorite,
              ),
              const SizedBox(height: 10),
              _ActionButton(
                icon: Icons.info_outline_rounded,
                label: '详情',
                onPressed: onDetail,
              ),
              const SizedBox(height: 10),
              _ActionButton(
                icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                label: playing ? '暂停' : '播放',
                onPressed: onTogglePlayback,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onPressed;

  const _ActionButton({
    required this.icon,
    required this.label,
    this.selected = false,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 66,
      height: 62,
      child: Material(
        color: const Color(0x99101519),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                color: selected ? AppColors.primary : Colors.white,
                size: 25,
              ),
              const SizedBox(height: 2),
              Text(label, style: const TextStyle(fontSize: 10)),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  final String label;

  const _MetaChip(this.label);

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0x66101519),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0x33FFFFFF)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Text(label, style: const TextStyle(fontSize: 10)),
      ),
    );
  }
}
