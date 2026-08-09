import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/models.dart';
import '../services/app_state.dart';
import 'player_screen.dart';

class DetailScreen extends StatefulWidget {
  final AppState appState;
  final MediaItem item;
  const DetailScreen({super.key, required this.appState, required this.item});

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  MediaItem? _detail;
  bool _loading = true;
  int _lineIndex = 0;
  int _episodeIndex = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadDetail();
  }

  Future<void> _loadDetail() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.appState.api.resolve(
        widget.item,
        widget.appState.sources,
      );
      if (result != null &&
          result.playLines != null &&
          result.playLines!.isNotEmpty) {
        final resume = widget.appState.getResume(widget.item);
        if (resume != null) {
          final matchLine = result.playLines!.indexWhere(
            (l) => l.name == resume.lineName,
          );
          if (matchLine >= 0) _lineIndex = matchLine;
          final matchEp = result.playLines![_lineIndex].episodes.indexWhere(
            (e) => e.name == resume.episodeName,
          );
          if (matchEp >= 0) _episodeIndex = matchEp;
        }
      }
      setState(() {
        _detail = result;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _play() {
    final lines = _detail?.playLines ?? widget.item.playLines ?? [];
    if (lines.isEmpty || _lineIndex >= lines.length) return;
    final episodes = lines[_lineIndex].episodes;
    if (_episodeIndex >= episodes.length) return;
    final merged = _detail ?? widget.item;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          appState: widget.appState,
          item: merged,
          playLines: lines,
          lineIndex: _lineIndex,
          episodeIndex: _episodeIndex,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = _detail ?? widget.item;
    final lines = item.playLines ?? [];
    final isFav = widget.appState.isFavorite(
      widget.item.sourceId,
      widget.item.id,
    );

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: Icon(
              isFav ? Icons.favorite : Icons.favorite_border,
              color: isFav ? Colors.red : null,
            ),
            onPressed: () => widget.appState.toggleFavorite(widget.item),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: item.poster.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: item.poster,
                              width: 120,
                              height: 170,
                              fit: BoxFit.cover,
                            )
                          : Container(
                              width: 120,
                              height: 170,
                              color: theme.colorScheme.surfaceContainerHighest,
                            ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.title,
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (item.year != null)
                            Text(
                              item.year!,
                              style: TextStyle(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          if (item.remarks != null)
                            Text(
                              item.remarks!,
                              style: TextStyle(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          if (item.area != null)
                            Text(
                              item.area!,
                              style: TextStyle(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          const SizedBox(height: 4),
                          Text(
                            item.sourceName,
                            style: TextStyle(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                          if (item.alternatives != null &&
                              item.alternatives!.isNotEmpty)
                            Text(
                              '${item.alternatives!.length} 个来源',
                              style: TextStyle(
                                color: theme.colorScheme.primary,
                                fontSize: 12,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (item.summary != null && item.summary!.isNotEmpty)
                  Text(
                    item.summary!,
                    style: TextStyle(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                if (item.actors != null && item.actors!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    '演员: ${item.actors}',
                    style: TextStyle(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                ],
                if (item.director != null && item.director!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    '导演: ${item.director}',
                    style: TextStyle(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: lines.isNotEmpty ? _play : null,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('立即播放'),
                  ),
                ),
                const SizedBox(height: 20),
                if (lines.length > 1) ...[
                  Text(
                    '线路',
                    style: TextStyle(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: lines.asMap().entries.map((entry) {
                      return ChoiceChip(
                        label: Text(entry.value.name),
                        selected: entry.key == _lineIndex,
                        onSelected: (_) => setState(() {
                          _lineIndex = entry.key;
                          _episodeIndex = 0;
                        }),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),
                ],
                if (lines.isNotEmpty && _lineIndex < lines.length) ...[
                  Text(
                    '剧集 (${lines[_lineIndex].episodes.length})',
                    style: TextStyle(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: lines[_lineIndex].episodes.asMap().entries.map((
                      entry,
                    ) {
                      final selected = entry.key == _episodeIndex;
                      return SizedBox(
                        width: 72,
                        child: OutlinedButton(
                          onPressed: () {
                            setState(() => _episodeIndex = entry.key);
                            _play();
                          },
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
                    }).toList(),
                  ),
                ],
              ],
            ),
    );
  }
}
