import 'package:flutter/material.dart';
import '../models/models.dart';
import '../services/app_state.dart';
import 'player_screen.dart';

class LiveScreen extends StatefulWidget {
  final AppState appState;
  const LiveScreen({super.key, required this.appState});

  @override
  State<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends State<LiveScreen> {
  final _search = TextEditingController();
  String _query = '';
  bool _syncing = false;

  List<LiveChannel> get _filtered {
    if (_query.trim().isEmpty) return widget.appState.liveChannels;
    final q = _query.toLowerCase();
    return widget.appState.liveChannels
        .where(
          (c) =>
              c.name.toLowerCase().contains(q) ||
              c.group.toLowerCase().contains(q),
        )
        .toList();
  }

  Future<void> _sync() async {
    setState(() => _syncing = true);
    try {
      final result = await widget.appState.api.importIptv();
      if (result.lives.isNotEmpty) {
        await widget.appState.setLiveChannels(result.lives);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('同步完成：${result.lives.length} 个频道')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('同步失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  void _play(LiveChannel channel) {
    final urls = channel.urls?.isNotEmpty == true
        ? channel.urls!
        : [channel.url];
    final lines = urls
        .asMap()
        .entries
        .map(
          (e) => PlayLine(
            name: '线路 ${e.key + 1}',
            episodes: [Episode(name: channel.name, url: e.value)],
          ),
        )
        .toList();
    final item = MediaItem(
      id: channel.id,
      sourceId: channel.sourceId,
      sourceName: channel.sourceName,
      title: channel.name,
      poster: channel.logo ?? '',
      category: MediaCategory.live,
      remarks: channel.group,
      playLines: lines,
    );
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          appState: widget.appState,
          item: item,
          playLines: lines,
          lineIndex: 0,
          episodeIndex: 0,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('直播'),
        actions: [
          IconButton(
            onPressed: _syncing ? null : _sync,
            icon: _syncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: TextField(
              controller: _search,
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                hintText: '搜索频道',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${_filtered.length} 个频道',
                style: TextStyle(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 13,
                ),
              ),
            ),
          ),
          Expanded(
            child: _filtered.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.live_tv, size: 48),
                        const SizedBox(height: 12),
                        const Text('暂无频道'),
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          onPressed: _sync,
                          icon: const Icon(Icons.sync),
                          label: const Text('同步 IPTV'),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(12),
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemCount: _filtered.length,
                    itemBuilder: (context, index) {
                      final channel = _filtered[index];
                      final lineCount = channel.urls?.length ?? 1;
                      return ListTile(
                        leading: const CircleAvatar(
                          child: Icon(Icons.live_tv, size: 20),
                        ),
                        title: Text(
                          channel.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${channel.group} · ${channel.sourceName}${lineCount > 1 ? ' · $lineCount 条线路' : ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.play_arrow),
                        onTap: () => _play(channel),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
