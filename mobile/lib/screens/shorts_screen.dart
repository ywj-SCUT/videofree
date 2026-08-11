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

class _ResolvedShort {
  final String url;
  final Map<String, String>? headers;
  const _ResolvedShort({required this.url, this.headers});
}

class ShortsScreen extends StatefulWidget {
  final AppState appState;
  final VoidCallback onOpenSettings;

  const ShortsScreen({
    super.key,
    required this.appState,
    required this.onOpenSettings,
  });

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

  List<MediaItem> _items = [];
  List<SourceFailure> _failures = [];
  int _currentIndex = 0;
  int _feedRequestId = 0;
  int _requestId = 0;
  bool _playing = false;
  bool _buffering = false;
  bool _refreshing = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 1;
  String? _error;
  String? _feedError;
  late String _sourceSignature;
  final Map<String, _ResolvedShort> _resolved = {};
  final Map<String, Future<_ResolvedShort>> _resolving = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _player = Player();
    _videoController = VideoController(_player);
    _sourceSignature = _shortSourceSignature();
    widget.appState.addListener(_handleAppStateChanged);
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
    unawaited(_refreshFeed());
  }

  String _shortSourceSignature() => widget.appState.sources
      .where((source) => source.type == 'short-api')
      .map(
        (source) =>
            '${source.id}|${source.enabled}|${source.searchable}|${source.provider}|${source.headers?['Authorization'] ?? ''}',
      )
      .join(';');

  void _handleAppStateChanged() {
    final next = _shortSourceSignature();
    if (next == _sourceSignature) return;
    _sourceSignature = next;
    unawaited(_refreshFeed());
  }

  bool _isPlatformItem(MediaItem item) => widget.appState.sources.any(
    (source) => source.id == item.sourceId && source.type == 'short-api',
  );

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
    widget.appState.removeListener(_handleAppStateChanged);
    _pageController.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _refreshFeed() async {
    if (_refreshing) return;
    final feedRequestId = ++_feedRequestId;
    await _player.stop();
    setState(() {
      _refreshing = true;
      _playing = false;
      _buffering = false;
      _error = null;
      _feedError = null;
    });
    try {
      final response = await widget.appState.engine.search(
        '',
        MediaCategory.short,
        widget.appState.sources,
        1,
      );
      if (!mounted || feedRequestId != _feedRequestId) return;
      final byId = <String, MediaItem>{};
      for (final item in response.items.where(_isPlatformItem)) {
        byId['${item.sourceId}:${item.id}'] = item;
      }
      _resolved.clear();
      _resolving.clear();
      setState(() {
        _items = byId.values.toList();
        _failures = response.failures;
        _page = 1;
        _hasMore = response.hasMore && _items.isNotEmpty;
        _currentIndex = 0;
      });
      if (_pageController.hasClients) _pageController.jumpToPage(0);
      if (_items.isNotEmpty) {
        await _activate(0);
        _precacheNeighbors(_currentIndex);
      }
    } catch (error) {
      if (!mounted || feedRequestId != _feedRequestId) return;
      setState(() {
        _items = [];
        _failures = [];
        _hasMore = false;
        _feedError = error.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      if (mounted && feedRequestId == _feedRequestId) {
        setState(() => _refreshing = false);
      }
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    var nextPage = _page;
    var hasMore = _hasMore;
    final fresh = <MediaItem>[];
    final known = _items.map((item) => '${item.sourceId}:${item.id}').toSet();
    try {
      for (
        var attempt = 0;
        attempt < 4 && hasMore && fresh.isEmpty;
        attempt++
      ) {
        nextPage++;
        final response = await widget.appState.engine.search(
          '',
          MediaCategory.short,
          widget.appState.sources,
          nextPage,
        );
        hasMore = response.hasMore;
        for (final item in response.items.where(_isPlatformItem)) {
          if (known.add('${item.sourceId}:${item.id}')) fresh.add(item);
        }
        for (final failure in response.failures) {
          if (!_failures.any((value) => value.sourceId == failure.sourceId)) {
            _failures.add(failure);
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _page = nextPage;
        _hasMore = hasMore;
        if (fresh.isNotEmpty) _items = [..._items, ...fresh];
      });
      _precacheNeighbors(_currentIndex);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  String _itemKey(MediaItem item) => '${item.sourceId}:${item.id}';

  Future<_ResolvedShort> _resolveShort(MediaItem original) {
    final key = _itemKey(original);
    final cached = _resolved[key];
    if (cached != null) return Future.value(cached);
    return _resolving
        .putIfAbsent(key, () async {
          var item = original;
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
          if (url.startsWith('videoget-rule:') ||
              url.startsWith('videoget-short:')) {
            final resolved = await widget.appState.engine.play(
              episode.sourceId ?? item.sourceId,
              url,
              widget.appState.sources,
            );
            url = resolved.url;
            headers = resolved.headers;
          }
          final result = _ResolvedShort(url: url, headers: headers);
          _resolved[key] = result;
          return result;
        })
        .whenComplete(() => _resolving.remove(key));
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
      final playback = await _resolveShort(_items[index]);
      if (!mounted || requestId != _requestId) return;
      await _player.open(
        Media(playback.url, httpHeaders: playback.headers),
        play: true,
      );
    } catch (error) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _buffering = false;
        _error = error.toString().replaceFirst('Exception: ', '');
      });
    }
    _precacheNeighbors(index);
    unawaited(_preloadNext(index));
  }

  Future<void> _preloadNext(int index) async {
    final next = index + 1;
    if (next >= _items.length) return;
    try {
      await _resolveShort(_items[next]);
    } catch (_) {
      // 当前播放不应被下一条预加载失败打断。
    }
    final keep = <String>{
      for (final value in [index - 1, index, index + 1, index + 2])
        if (value >= 0 && value < _items.length) _itemKey(_items[value]),
    };
    _resolved.removeWhere((key, _) => !keep.contains(key));
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
    final enabledPlatforms = widget.appState.sources.where(
      (source) =>
          source.type == 'short-api' && source.enabled && source.searchable,
    );
    final hasConfiguredPlatform = enabledPlatforms.any(
      (source) => RegExp(
        r'^Bearer\s+\S+',
        caseSensitive: false,
      ).hasMatch(source.headers?['Authorization'] ?? ''),
    );
    final failureText =
        _feedError ??
        (_failures.isEmpty
            ? null
            : _failures
                  .take(2)
                  .map((failure) => '${failure.sourceName}：${failure.message}')
                  .join('\n'));
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_items.isNotEmpty)
            PageView.builder(
              controller: _pageController,
              scrollDirection: Axis.vertical,
              itemCount: _items.length,
              onPageChanged: (index) {
                HapticFeedback.selectionClick();
                unawaited(_activate(index));
                if (index >= _items.length - 3) unawaited(_loadMore());
              },
              itemBuilder: (context, index) => _ShortPage(
                item: _items[index],
                index: index,
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
            )
          else
            ColoredBox(
              color: Colors.black,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(28, 110, 28, 118),
                child: Center(
                  child: _ShortsEmptyState(
                    loading: _refreshing,
                    hasConfiguredPlatform: hasConfiguredPlatform,
                    failureText: failureText,
                    onRefresh: _refreshFeed,
                    onOpenSettings: widget.onOpenSettings,
                  ),
                ),
              ),
            ),
          if (_loadingMore)
            const Positioned(
              left: 0,
              right: 0,
              bottom: 18,
              child: Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Color(0xCC101519),
                    borderRadius: BorderRadius.all(Radius.circular(8)),
                  ),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 8),
                        Text('正在载入'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          SafeArea(
            bottom: false,
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 12, 0),
                child: Row(
                  children: [
                    const Text(
                      '短视频',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
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
          ),
        ],
      ),
    );
  }
}

class _ShortPage extends StatelessWidget {
  final MediaItem item;
  final int index;
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
            '第 ${index + 1} 条',
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

class _ShortsEmptyState extends StatelessWidget {
  final bool loading;
  final bool hasConfiguredPlatform;
  final String? failureText;
  final VoidCallback onRefresh;
  final VoidCallback onOpenSettings;

  const _ShortsEmptyState({
    required this.loading,
    required this.hasConfiguredPlatform,
    required this.failureText,
    required this.onRefresh,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('正在连接短视频平台'),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.smart_display_outlined,
          size: 58,
          color: AppColors.secondary,
        ),
        const SizedBox(height: 18),
        Text(
          hasConfiguredPlatform ? '平台短视频加载失败' : '还没有配置短视频平台',
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          failureText ??
              '在设置中填写 TikHub Bearer Token，即可加载 TikTok、抖音与 YouTube Shorts 的真实作品。',
          textAlign: TextAlign.center,
          maxLines: 5,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Color(0xFFB8C0C5), height: 1.5),
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: onOpenSettings,
          icon: const Icon(Icons.tune_rounded),
          label: const Text('配置平台接口'),
        ),
        if (hasConfiguredPlatform) ...[
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('重新加载'),
          ),
        ],
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
