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

class SearchScreen extends StatefulWidget {
  final AppState appState;
  const SearchScreen({super.key, required this.appState});

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
      final response = await widget.appState.api.search(
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
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
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
                          'VideoGET',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          '全源聚合',
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
            const SizedBox(height: 10),
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: MediaCategory.values
                    .where((category) => category != MediaCategory.live)
                    .map(
                      (category) => Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: FilterChip(
                          label: Text(category.label),
                          selected: category == _category,
                          showCheckmark: category == _category,
                          onSelected: (_) => _selectCategory(category),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text(
                    '${_results.length} 个结果',
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
        detail: _failures.isEmpty ? '换一个片名或分类试试' : '请检查服务地址和视频源状态',
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
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final item = _results[index];
        return _MediaCard(
          item: item,
          imageUrl: resolveMediaUrl(widget.appState.serverUrl, item.poster),
          onTap: () => _openDetail(item),
        );
      },
    );
  }
}

class _MediaCard extends StatelessWidget {
  final MediaItem item;
  final String imageUrl;
  final VoidCallback onTap;

  const _MediaCard({
    required this.item,
    required this.imageUrl,
    required this.onTap,
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
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(7),
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
                        borderRadius: BorderRadius.circular(6),
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
