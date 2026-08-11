import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/models.dart';
import '../services/app_state.dart';
import '../services/media_url.dart';
import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
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
      if (!mounted) return;
      if (result != null && result.playLines?.isNotEmpty == true) {
        final resume = widget.appState.getResume(widget.item);
        if (resume != null) {
          final matchLine = result.playLines!.indexWhere(
            (line) => line.name == resume.lineName,
          );
          if (matchLine >= 0) _lineIndex = matchLine;
          final matchEpisode = result.playLines![_lineIndex].episodes
              .indexWhere((episode) => episode.name == resume.episodeName);
          if (matchEpisode >= 0) _episodeIndex = matchEpisode;
        }
      }
      setState(() {
        _detail = result;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  void _play() {
    final lines = _detail?.playLines ?? widget.item.playLines ?? [];
    if (lines.isEmpty || _lineIndex >= lines.length) return;
    final episodes = lines[_lineIndex].episodes;
    if (_episodeIndex >= episodes.length) return;
    HapticFeedback.lightImpact();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          appState: widget.appState,
          item: _detail ?? widget.item,
          playLines: lines,
          lineIndex: _lineIndex,
          episodeIndex: _episodeIndex,
        ),
      ),
    );
  }

  Future<void> _toggleFavorite() async {
    HapticFeedback.selectionClick();
    await widget.appState.toggleFavorite(widget.item);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = _detail ?? widget.item;
    final isFavorite = widget.appState.isFavorite(
      widget.item.sourceId,
      widget.item.id,
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: isFavorite ? '取消收藏' : '收藏',
            onPressed: _toggleFavorite,
            icon: AnimatedSwitcher(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              transitionBuilder: (child, animation) =>
                  ScaleTransition(scale: animation, child: child),
              child: Icon(
                isFavorite
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                key: ValueKey(isFavorite),
                color: isFavorite ? theme.colorScheme.primary : null,
              ),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: AnimatedSwitcher(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 200),
        child: _buildBody(theme, item),
      ),
    );
  }

  Widget _buildBody(ThemeData theme, MediaItem item) {
    if (_loading) {
      return const Center(
        key: ValueKey('loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (_error != null) {
      return EmptyState(
        key: const ValueKey('error'),
        icon: Icons.cloud_off_rounded,
        title: '详情加载失败',
        detail: _error,
        action: FilledButton.icon(
          onPressed: _loadDetail,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('重试'),
        ),
      );
    }

    final lines = item.playLines ?? [];
    final sourceCount = item.alternatives?.length ?? 1;
    final posterUrl = resolveMediaUrl(widget.appState.serverUrl, item.poster);
    final backdropUrl = resolveMediaUrl(
      widget.appState.serverUrl,
      item.backdrop?.isNotEmpty == true ? item.backdrop! : item.poster,
    );
    return ListView(
      key: const ValueKey('content'),
      padding: const EdgeInsets.only(bottom: 34),
      children: [
        SizedBox(
          height: 360,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (backdropUrl.isNotEmpty)
                Image(
                  image: CachedNetworkImageProvider(backdropUrl),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const _DetailBackdropFallback(),
                )
              else
                const _DetailBackdropFallback(),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x220B0D10), Color(0xF50B0D10)],
                    stops: [0.18, 1],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 44, 18, 22),
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SizedBox(
                          width: 118,
                          height: 168,
                          child: posterUrl.isEmpty
                              ? const _DetailPosterFallback()
                              : CachedNetworkImage(
                                  imageUrl: posterUrl,
                                  fit: BoxFit.cover,
                                  placeholder: (_, _) =>
                                      const _DetailPosterFallback(),
                                  errorWidget: (_, _, _) =>
                                      const _DetailPosterFallback(),
                                ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              item.title,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 28,
                                height: 1.08,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                if (item.year?.isNotEmpty == true)
                                  _MetadataChip(item.year!),
                                if (item.area?.isNotEmpty == true)
                                  _MetadataChip(item.area!),
                                if (item.remarks?.isNotEmpty == true)
                                  _MetadataChip(item.remarks!),
                              ],
                            ),
                            const SizedBox(height: 9),
                            Text(
                              '$sourceCount 个来源 · ${item.sourceName}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: theme.colorScheme.secondary,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
          child: FilledButton.icon(
            onPressed: lines.isEmpty ? null : _play,
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(
              lines.isEmpty ? '暂无可播放线路' : '播放 ${_currentEpisodeName(lines)}',
            ),
          ),
        ),
        SizedBox(
          height: 2,
        ),
        if (item.summary?.isNotEmpty == true) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 26, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionHeading(title: '简介'),
                const SizedBox(height: 8),
                Text(
                  item.summary!,
                  style: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.55,
                  ),
                ),
              ],
            ),
          ),
        ],
        if (item.actors?.isNotEmpty == true || item.director?.isNotEmpty == true)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (item.actors?.isNotEmpty == true)
                  _CreditLine(label: '演员', value: item.actors!),
                if (item.director?.isNotEmpty == true)
                  _CreditLine(label: '导演', value: item.director!),
              ],
            ),
          ),
        if (lines.length > 1) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 26, 16, 0),
            child: SectionHeading(title: '线路', detail: '${lines.length} 条可用线路'),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 42,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              scrollDirection: Axis.horizontal,
              itemCount: lines.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) => ChoiceChip(
                label: Text(lines[index].name),
                selected: index == _lineIndex,
                onSelected: (_) {
                  HapticFeedback.selectionClick();
                  setState(() {
                    _lineIndex = index;
                    _episodeIndex = 0;
                  });
                },
              ),
            ),
          ),
        ],
        if (lines.isNotEmpty && _lineIndex < lines.length) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 26, 16, 0),
            child: SectionHeading(
              title: '剧集',
              detail: '${lines[_lineIndex].episodes.length} 集',
            ),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 104,
              mainAxisExtent: 44,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: lines[_lineIndex].episodes.length,
            itemBuilder: (context, index) {
              final episode = lines[_lineIndex].episodes[index];
              final selected = index == _episodeIndex;
              return OutlinedButton(
                onPressed: () {
                  HapticFeedback.selectionClick();
                  setState(() => _episodeIndex = index);
                  _play();
                },
                style: OutlinedButton.styleFrom(
                  backgroundColor: selected
                      ? theme.colorScheme.primaryContainer
                      : AppColors.surface,
                  foregroundColor: selected
                      ? theme.colorScheme.onPrimaryContainer
                      : theme.colorScheme.onSurface,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
                child: Text(
                  episode.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              );
            },
            ),
          ),
        ],
      ],
    );
  }

  String _currentEpisodeName(List<PlayLine> lines) {
    if (_lineIndex >= lines.length ||
        _episodeIndex >= lines[_lineIndex].episodes.length) {
      return '';
    }
    return lines[_lineIndex].episodes[_episodeIndex].name;
  }
}

class _MetadataChip extends StatelessWidget {
  final String label;
  const _MetadataChip(this.label);

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class _CreditLine extends StatelessWidget {
  final String label;
  final String value;
  const _CreditLine({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label  ',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            TextSpan(
              text: value,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _DetailBackdropFallback extends StatelessWidget {
  const _DetailBackdropFallback();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.surfaceHighest, AppColors.background],
        ),
      ),
    );
  }
}

class _DetailPosterFallback extends StatelessWidget {
  const _DetailPosterFallback();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.surfaceRaised,
      child: Center(
        child: Icon(
          Icons.movie_outlined,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          size: 36,
        ),
      ),
    );
  }
}
