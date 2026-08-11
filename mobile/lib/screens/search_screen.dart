import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../models/models.dart';
import '../services/app_state.dart';
import '../services/media_url.dart';
import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import 'detail_screen.dart';

enum _LibrarySort { recent, year, title }

extension on _LibrarySort {
  String get label => switch (this) {
    _LibrarySort.recent => '聚合顺序',
    _LibrarySort.year => '年份从新到旧',
    _LibrarySort.title => '片名排序',
  };
}

class SearchScreen extends StatefulWidget {
  final AppState appState;
  final VoidCallback onOpenLibrary;
  const SearchScreen({
    super.key,
    required this.appState,
    required this.onOpenLibrary,
  });

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  List<MediaItem> _results = [];
  List<SourceFailure> _failures = [];
  bool _loading = false;
  String _elapsed = '';
  MediaCategory _category = MediaCategory.all;
  String _sourceId = 'all';
  _LibrarySort _sort = _LibrarySort.recent;

  @override
  void initState() {
    super.initState();
    _performSearch('');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _performSearch(String query) async {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _loading = true;
      _failures = [];
    });
    try {
      final response = await widget.appState.engine.search(
        query.trim(),
        _category,
        widget.appState.sources,
      );
      if (!mounted) return;
      setState(() {
        _results = response.items;
        _failures = response.failures;
        _elapsed = '${(response.elapsedMs / 1000).toStringAsFixed(2)} 秒';
      });
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _failures = [
          SourceFailure(
            sourceId: '',
            sourceName: '',
            message: error.toString(),
          ),
        ],
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _selectCategory(MediaCategory category) {
    if (category == _category) return;
    HapticFeedback.selectionClick();
    setState(() => _category = category);
    _performSearch(_controller.text);
  }

  void _openDetail(MediaItem item) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DetailScreen(appState: widget.appState, item: item),
      ),
    );
  }

  List<MediaItem> get _visibleResults {
    final visible = _results
        .where((item) => _sourceId == 'all' || item.sourceId == _sourceId)
        .toList();
    switch (_sort) {
      case _LibrarySort.recent:
        return visible;
      case _LibrarySort.year:
        visible.sort(
          (a, b) => (int.tryParse(b.year ?? '') ?? 0).compareTo(
            int.tryParse(a.year ?? '') ?? 0,
          ),
        );
      case _LibrarySort.title:
        visible.sort((a, b) => a.title.compareTo(b.title));
    }
    return visible;
  }

  List<MapEntry<String, String>> get _availableSources {
    final sources = <String, String>{};
    for (final item in _results) {
      sources[item.sourceId] = item.sourceName;
    }
    return sources.entries.toList();
  }

  String get _selectedSourceName {
    if (_sourceId == 'all') return '全部片库';
    for (final source in _availableSources) {
      if (source.key == _sourceId) return source.value;
    }
    return '全部片库';
  }

  Future<void> _toggleFavorite(MediaItem item) async {
    await widget.appState.toggleFavorite(item);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                children: [
                  SvgPicture.asset(
                    'assets/videoget-icon.svg',
                    width: 36,
                    height: 28,
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '本地优先 · 多源聚合',
                          style: TextStyle(
                            color: AppColors.secondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            letterSpacing: .4,
                          ),
                        ),
                        Text(
                          '媒体库',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          '浏览、筛选并打开影视内容',
                          style: TextStyle(
                            color: Color(0xFFAAA4AB),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_failures.isNotEmpty)
                    Tooltip(
                      message: _failures
                          .map((failure) => failure.message)
                          .join('\n'),
                      child: Chip(
                        avatar: Icon(
                          Icons.warning_amber_rounded,
                          size: 17,
                          color: theme.colorScheme.error,
                        ),
                        label: Text('${_failures.length} 个源失败'),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: '片名、演员或关键词',
                        prefixIcon: const Icon(Icons.search_rounded),
                        suffixIcon: _controller.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: '清空',
                                onPressed: () {
                                  _controller.clear();
                                  setState(() {});
                                  _performSearch('');
                                },
                                icon: const Icon(Icons.close_rounded),
                              ),
                      ),
                      onChanged: (_) => setState(() {}),
                      onSubmitted: _performSearch,
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton.filled(
                    tooltip: '搜索',
                    onPressed: _loading
                        ? null
                        : () => _performSearch(_controller.text),
                    icon: const Icon(Icons.arrow_forward_rounded),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  PopupMenuButton<String>(
                    tooltip: '选择片库',
                    onSelected: (value) => setState(() => _sourceId = value),
                    itemBuilder: (context) => [
                      CheckedPopupMenuItem(
                        value: 'all',
                        checked: _sourceId == 'all',
                        child: const Text('全部来源'),
                      ),
                      ..._availableSources.map(
                        (source) => CheckedPopupMenuItem(
                          value: source.key,
                          checked: _sourceId == source.key,
                          child: Text(source.value),
                        ),
                      ),
                    ],
                    child: _LibraryFilterButton(
                      icon: Icons.video_library_outlined,
                      label: _selectedSourceName,
                    ),
                  ),
                  const SizedBox(width: 8),
                  PopupMenuButton<MediaCategory>(
                    tooltip: '选择类型',
                    onSelected: _selectCategory,
                    itemBuilder: (context) => MediaCategory.values
                        .map(
                          (category) => CheckedPopupMenuItem(
                            value: category,
                            checked: category == _category,
                            child: Text(category.label),
                          ),
                        )
                        .toList(),
                    child: _LibraryFilterButton(
                      icon: Icons.filter_alt_outlined,
                      label: _category.label,
                    ),
                  ),
                  const SizedBox(width: 8),
                  ActionChip(
                    avatar: const Icon(Icons.favorite_border_rounded, size: 18),
                    label: Text('收藏 ${widget.appState.favorites.length}'),
                    onPressed: widget.onOpenLibrary,
                  ),
                  const SizedBox(width: 8),
                  PopupMenuButton<_LibrarySort>(
                    tooltip: '选择排序方式',
                    onSelected: (value) => setState(() => _sort = value),
                    itemBuilder: (context) => _LibrarySort.values
                        .map(
                          (sort) => CheckedPopupMenuItem(
                            value: sort,
                            checked: sort == _sort,
                            child: Text(sort.label),
                          ),
                        )
                        .toList(),
                    child: _LibraryFilterButton(
                      icon: Icons.swap_vert_rounded,
                      label: _sort.label,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text(
                    '${_visibleResults.length} 部作品',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  if (_elapsed.isNotEmpty)
                    Text(
                      _elapsed,
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 7),
            AnimatedSwitcher(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              child: _loading
                  ? const LinearProgressIndicator(
                      key: ValueKey('loading'),
                      minHeight: 2,
                    )
                  : const SizedBox(key: ValueKey('idle'), height: 2),
            ),
            Expanded(child: _buildResults(theme)),
          ],
        ),
      ),
    );
  }

  Widget _buildResults(ThemeData theme) {
    if (_loading && _results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_results.isEmpty) {
      return EmptyState(
        icon: Icons.manage_search_rounded,
        title: '没有找到内容',
        detail: _failures.isEmpty ? '换一个片名或分类试试' : '请检查视频源状态',
      );
    }

    final visibleResults = _visibleResults;
    if (visibleResults.isEmpty) {
      return const EmptyState(
        icon: Icons.filter_alt_off_rounded,
        title: '当前筛选没有内容',
        detail: '切换片库、类型或排序方式后再试',
      );
    }

    return GridView.builder(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 108),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        childAspectRatio: 0.57,
        crossAxisSpacing: 10,
        mainAxisSpacing: 12,
      ),
      itemCount: visibleResults.length,
      itemBuilder: (context, index) {
        final item = visibleResults[index];
        return _MediaCard(
          item: item,
          imageUrl: resolveMediaUrl(item.poster),
          onTap: () => _openDetail(item),
          isFavorite: widget.appState.isFavorite(item.sourceId, item.id),
          onFavorite: () => _toggleFavorite(item),
        );
      },
    );
  }
}

class _MediaCard extends StatelessWidget {
  final MediaItem item;
  final String imageUrl;
  final VoidCallback onTap;
  final bool isFavorite;
  final VoidCallback onFavorite;

  const _MediaCard({
    required this.item,
    required this.imageUrl,
    required this.onTap,
    required this.isFavorite,
    required this.onFavorite,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final altCount = item.alternatives?.length ?? 1;
    return PressableScale(
      onTap: onTap,
      semanticLabel: '$altCount 个来源',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppColors.surfaceRaised,
                    borderRadius: BorderRadius.circular(13),
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x30000000),
                        blurRadius: 16,
                        offset: Offset(0, 8),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: imageUrl.isEmpty
                        ? const _PosterFallback()
                        : CachedNetworkImage(
                            imageUrl: imageUrl,
                            fit: BoxFit.cover,
                            fadeInDuration: const Duration(milliseconds: 160),
                            placeholder: (_, _) => const _PosterFallback(),
                            errorWidget: (_, _, _) => const _PosterFallback(),
                          ),
                  ),
                ),
                if (altCount > 1)
                  Positioned(
                    top: 7,
                    right: 7,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xD908090B),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0x44343941)),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 4,
                        ),
                        child: Text(
                          '$altCount 源',
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  left: 7,
                  bottom: 7,
                  child: IconButton.filledTonal(
                    tooltip: isFavorite ? '取消收藏' : '收藏',
                    visualDensity: VisualDensity.compact,
                    style: IconButton.styleFrom(
                      minimumSize: const Size(36, 36),
                      backgroundColor: const Color(0xD90B0D10),
                      foregroundColor: isFavorite
                          ? AppColors.primary
                          : Colors.white,
                    ),
                    onPressed: onFavorite,
                    icon: Icon(
                      isFavorite
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      size: 19,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 7),
          Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          Text(
            item.remarks ?? item.sourceName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _PosterFallback extends StatelessWidget {
  const _PosterFallback();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.surfaceRaised,
      child: Center(
        child: Icon(
          Icons.movie_outlined,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          size: 34,
        ),
      ),
    );
  }
}

class _LibraryFilterButton extends StatelessWidget {
  final IconData icon;
  final String label;

  const _LibraryFilterButton({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: 7),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 118),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 3),
            const Icon(Icons.expand_more_rounded, size: 17),
          ],
        ),
      ),
    );
  }
}
