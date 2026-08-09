import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/models.dart';
import '../services/app_state.dart';
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

  Widget _mediaList(List<MediaItem> items, {List<HistoryItem>? history}) {
    if (items.isEmpty) return const Center(child: Text('暂无内容'));
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        final h = history != null && index < history.length
            ? history[index]
            : null;
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(
            vertical: 6,
            horizontal: 4,
          ),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: item.poster.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: item.poster,
                    width: 52,
                    height: 74,
                    fit: BoxFit.cover,
                  )
                : Container(
                    width: 52,
                    height: 74,
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                  ),
          ),
          title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                h != null
                    ? '${h.episodeName ?? ''} · ${_formatTime(h.progress)}'
                    : (item.remarks ?? item.sourceName),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (h != null && h.duration > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: LinearProgressIndicator(
                    value: (h.progress / h.duration).clamp(0, 1),
                    minHeight: 2,
                  ),
                ),
            ],
          ),
          trailing: IconButton(
            icon: Icon(history == null ? Icons.favorite : Icons.play_arrow),
            color: history == null ? Colors.red : null,
            onPressed: () {
              if (history == null) {
                widget.appState.toggleFavorite(item);
              } else {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        DetailScreen(appState: widget.appState, item: item),
                  ),
                );
              }
            },
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
    final d = Duration(seconds: seconds.round());
    return '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('我的'),
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            Tab(text: '收藏 ${widget.appState.favorites.length}'),
            Tab(text: '观看记录 ${widget.appState.history.length}'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '清空观看记录',
            onPressed: widget.appState.history.isEmpty
                ? null
                : () => widget.appState.clearHistory(),
          ),
        ],
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _mediaList(widget.appState.favorites),
          _mediaList(
            widget.appState.history.map((h) => h.item).toList(),
            history: widget.appState.history,
          ),
        ],
      ),
    );
  }
}
