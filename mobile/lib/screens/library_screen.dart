import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/models.dart';
import '../services/app_state.dart';
import '../services/media_url.dart';
import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import 'detail_screen.dart';

class LibraryScreen extends StatefulWidget {
  final AppState appState;
  const LibraryScreen({super.key, required this.appState});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    widget.appState.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.appState.removeListener(_refresh);
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _removeFavorite(MediaItem item) async {
    HapticFeedback.selectionClick();
    await widget.appState.toggleFavorite(item);
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已移除“${item.title}”'),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () => widget.appState.toggleFavorite(item),
        ),
      ),
    );
  }

  Future<void> _clearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空观看记录？'),
        content: const Text('所有断点和播放进度都会被移除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.appState.clearHistory();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('观看记录已清空')));
      }
    }
  }

  Widget _mediaList(List<MediaItem> items, {List<HistoryItem>? history}) {
    if (items.isEmpty) {
      return EmptyState(
        icon: history == null
            ? Icons.favorite_border_rounded
            : Icons.history_rounded,
        title: history == null ? '还没有收藏' : '还没有观看记录',
        detail: history == null ? '在详情页收藏喜欢的内容' : '播放后会在这里保留断点',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 108),
      separatorBuilder: (_, _) => const Divider(indent: 70, height: 1),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        final h = history == null ? null : history[index];
        return ListTile(
          tileColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
          ),
          contentPadding: const EdgeInsets.symmetric(
            vertical: 9,
            horizontal: 10,
          ),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 52,
              height: 74,
              child: item.poster.isEmpty
                  ? const _LibraryPosterFallback()
                  : CachedNetworkImage(
                      imageUrl: resolveMediaUrl(
                        widget.appState.serverUrl,
                        item.poster,
                      ),
                      fit: BoxFit.cover,
                      placeholder: (_, _) => const _LibraryPosterFallback(),
                      errorWidget: (_, _, _) => const _LibraryPosterFallback(),
                    ),
            ),
          ),
          title: Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 3),
              Text(
                h != null
                    ? '${h.episodeName ?? ''} · ${_formatTime(h.progress)}'
                    : (item.remarks ?? item.sourceName),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (h != null && h.duration > 0) ...[
                const SizedBox(height: 7),
                LinearProgressIndicator(
                  value: (h.progress / h.duration).clamp(0, 1),
                  minHeight: 3,
                  borderRadius: BorderRadius.circular(2),
                ),
              ],
            ],
          ),
          trailing: IconButton(
            tooltip: history == null ? '移除收藏' : '继续播放',
            icon: Icon(
              history == null
                  ? Icons.favorite_rounded
                  : Icons.play_circle_outline_rounded,
            ),
            color: history == null
                ? Theme.of(context).colorScheme.primary
                : null,
            onPressed: history == null
                ? () => _removeFavorite(item)
                : () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          DetailScreen(appState: widget.appState, item: item),
                    ),
                  ),
          ),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  DetailScreen(appState: widget.appState, item: item),
            ),
          ),
        );
      },
    );
  }

  String _formatTime(double seconds) {
    final duration = Duration(seconds: seconds.round());
    return '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('片库'),
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            Tab(text: '收藏 ${widget.appState.favorites.length}'),
            Tab(text: '观看记录 ${widget.appState.history.length}'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '清空观看记录',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: widget.appState.history.isEmpty ? null : _clearHistory,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _mediaList(widget.appState.favorites),
          _mediaList(
            widget.appState.history.map((history) => history.item).toList(),
            history: widget.appState.history,
          ),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: widget.appState.history.isNotEmpty
          ? Semantics(
              label: '最近播放 ${widget.appState.history.first.item.title}',
              child: FloatingActionButton.extended(
                onPressed: () {
                  final item = widget.appState.history.first.item;
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          DetailScreen(appState: widget.appState, item: item),
                    ),
                  );
                },
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(
                  '继续 · ${widget.appState.history.first.item.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                backgroundColor: colors.primaryContainer,
                foregroundColor: colors.onPrimaryContainer,
              ),
            )
          : null,
    );
  }
}

class _LibraryPosterFallback extends StatelessWidget {
  const _LibraryPosterFallback();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.surfaceRaised,
      child: Icon(
        Icons.movie_outlined,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        size: 24,
      ),
    );
  }
}
