import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/models.dart';
import '../services/app_state.dart';
import '../services/media_url.dart';
import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
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
  String _group = '全部';
  bool _syncing = false;

  List<String> get _groups {
    final values =
        widget.appState.liveChannels
            .map((channel) => channel.group.trim())
            .where((group) => group.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    return ['全部', ...values];
  }

  List<LiveChannel> get _filtered {
    final query = _query.trim().toLowerCase();
    return widget.appState.liveChannels.where((channel) {
      final matchesGroup = _group == '全部' || channel.group == _group;
      final matchesQuery =
          query.isEmpty ||
          channel.name.toLowerCase().contains(query) ||
          channel.group.toLowerCase().contains(query);
      return matchesGroup && matchesQuery;
    }).toList();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _sync() async {
    HapticFeedback.selectionClick();
    setState(() => _syncing = true);
    try {
      final result = await widget.appState.api.importIptv();
      if (result.lives.isNotEmpty) {
        await widget.appState.setLiveChannels(result.lives);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('同步完成：${result.lives.length} 个频道')),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('同步失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  void _play(LiveChannel channel) {
    HapticFeedback.lightImpact();
    final urls = channel.urls?.isNotEmpty == true
        ? channel.urls!
        : [channel.url];
    final lines = urls
        .asMap()
        .entries
        .map(
          (entry) => PlayLine(
            name: '线路 ${entry.key + 1}',
            episodes: [Episode(name: channel.name, url: entry.value)],
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
    final colors = Theme.of(context).colorScheme;
    final groups = _groups;
    if (!groups.contains(_group)) _group = '全部';
    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('直播'),
            Text(
              'M3U / IPTV',
              style: TextStyle(color: Color(0xFFAAA4AB), fontSize: 12),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '同步 IPTV',
            onPressed: _syncing ? null : _sync,
            icon: _syncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
            child: TextField(
              controller: _search,
              onChanged: (value) => setState(() => _query = value),
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                hintText: '搜索频道或分组',
                prefixIcon: Icon(Icons.search_rounded),
              ),
            ),
          ),
          if (groups.length > 1)
            SizedBox(
              height: 40,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: groups.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) => ChoiceChip(
                  label: Text(groups[index]),
                  selected: groups[index] == _group,
                  onSelected: (_) {
                    HapticFeedback.selectionClick();
                    setState(() => _group = groups[index]);
                  },
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Row(
              children: [
                Text(
                  '${_filtered.length} 个频道',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (_group != '全部')
                  Text(
                    _group,
                    style: TextStyle(color: colors.secondary, fontSize: 12),
                  ),
              ],
            ),
          ),
          Expanded(
            child: _filtered.isEmpty
                ? EmptyState(
                    icon: Icons.live_tv_outlined,
                    title: '暂无频道',
                    detail: '从设置导入 M3U / IPTV 播放列表',
                    action: FilledButton.icon(
                      onPressed: _syncing ? null : _sync,
                      icon: const Icon(Icons.sync_rounded),
                      label: const Text('同步 IPTV'),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 108),
                    separatorBuilder: (_, _) => const Divider(indent: 68),
                    itemCount: _filtered.length,
                    itemBuilder: (context, index) {
                      final channel = _filtered[index];
                      final lineCount = channel.urls?.length ?? 1;
                      final logo = channel.logo == null
                          ? ''
                          : resolveMediaUrl(
                              widget.appState.serverUrl,
                              channel.logo!,
                            );
                      return PressableScale(
                        onTap: () => _play(channel),
                        semanticLabel: channel.name,
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 5,
                          ),
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: SizedBox(
                              width: 48,
                              height: 48,
                              child: logo.isEmpty
                                  ? const _ChannelFallback()
                                  : CachedNetworkImage(
                                      imageUrl: logo,
                                      fit: BoxFit.cover,
                                      errorWidget: (_, _, _) =>
                                          const _ChannelFallback(),
                                      placeholder: (_, _) =>
                                          const _ChannelFallback(),
                                    ),
                            ),
                          ),
                          title: Text(
                            channel.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          subtitle: Text(
                            '${channel.group} · ${channel.sourceName}${lineCount > 1 ? ' · $lineCount 条线路' : ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: const Icon(
                            Icons.play_circle_outline_rounded,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _ChannelFallback extends StatelessWidget {
  const _ChannelFallback();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.surfaceRaised,
      child: Icon(
        Icons.live_tv_rounded,
        color: Theme.of(context).colorScheme.secondary,
      ),
    );
  }
}
