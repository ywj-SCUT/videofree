import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/models.dart';
import '../services/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';

class SettingsScreen extends StatefulWidget {
  final AppState appState;
  const SettingsScreen({super.key, required this.appState});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _importUrl = TextEditingController();
  final _tikHubToken = TextEditingController();
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    widget.appState.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.appState.removeListener(_refresh);
    _importUrl.dispose();
    _tikHubToken.dispose();
    super.dispose();
  }

  bool get _tikHubConfigured => widget.appState.sources.any(
    (source) =>
        source.provider?.startsWith('tikhub-') == true &&
        RegExp(
          r'^Bearer\s+\S+',
          caseSensitive: false,
        ).hasMatch(source.headers?['Authorization'] ?? ''),
  );

  Future<void> _saveTikHub() async {
    final token = _tikHubToken.text.trim();
    if (token.isEmpty) return;
    final next = widget.appState.sources.map((source) {
      if (source.provider?.startsWith('tikhub-') != true) return source;
      return CmsSource(
        id: source.id,
        name: source.name,
        type: source.type,
        api: source.api,
        enabled: true,
        searchable: source.searchable,
        headers: {...?source.headers, 'Authorization': 'Bearer $token'},
        script: source.script,
        scriptUrl: source.scriptUrl,
        ruleConfig: source.ruleConfig,
        provider: source.provider,
        region: source.region,
      );
    }).toList();
    await widget.appState.updateSources(next);
    _tikHubToken.clear();
    _message('抖音与 YouTube Shorts 平台接口已启用');
  }

  Future<void> _applyImport(ImportResult result) async {
    if (result.sources.isNotEmpty) {
      await widget.appState.mergeImportedSources(result.sources);
    }
    _message(
      '导入 ${result.sources.length} 个点播源${result.failures.isNotEmpty ? '，${result.failures.length} 项失败' : ''}',
    );
  }

  Future<void> _importFromUrl() async {
    final url = _importUrl.text.trim();
    if (url.isEmpty) return;
    setState(() => _importing = true);
    try {
      final result = await widget.appState.engine.importUrl(url);
      await _applyImport(result);
    } catch (error) {
      _message('导入失败：$error');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _importFile() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json', 'txt'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    setState(() => _importing = true);
    try {
      final file = picked.files.first;
      final bytes = file.bytes;
      if (bytes == null) throw Exception('未读取到文件内容');
      final result = await widget.appState.engine.importContent(
        utf8.decode(bytes),
        file.name,
      );
      await _applyImport(result);
    } catch (error) {
      _message('导入失败：$error');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _addSource() async {
    final name = TextEditingController();
    final api = TextEditingController();
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          8,
          20,
          MediaQuery.viewInsetsOf(context).bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '添加 CMS 视频源',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: name,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '来源名称',
                prefixIcon: Icon(Icons.label_outline_rounded),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: api,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'API 地址',
                prefixIcon: Icon(Icons.link_rounded),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('添加来源'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    final sourceName = name.text.trim();
    final sourceApi = api.text.trim();
    name.dispose();
    api.dispose();
    if (result != true) return;
    final uri = Uri.tryParse(sourceApi);
    if (sourceName.isEmpty || uri == null || !uri.hasScheme) {
      _message('来源名称和 API 地址不能为空');
      return;
    }
    final source = CmsSource(
      id: 'mobile-${DateTime.now().millisecondsSinceEpoch}',
      name: sourceName,
      type: 'cms',
      api: sourceApi,
      enabled: true,
      searchable: true,
    );
    await widget.appState.updateSources([...widget.appState.sources, source]);
    _message('已添加来源：$sourceName');
  }

  Future<void> _removeSource(CmsSource source) async {
    final previous = widget.appState.sources;
    await widget.appState.updateSources(
      previous.where((item) => item.id != source.id).toList(),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已移除 ${source.name}'),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () => widget.appState.updateSources(previous),
        ),
      ),
    );
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 112),
        children: [
          const SectionHeading(
            title: '本地引擎',
            detail: '所有搜索、解析、播放与收藏均在手机上完成，不需要连接电脑',
          ),
          const SizedBox(height: 12),
          const ListTile(
            contentPadding: EdgeInsets.symmetric(horizontal: 4),
            leading: Icon(Icons.offline_bolt_rounded),
            title: Text('仅本地模式'),
            subtitle: Text('直接请求已启用的视频源，配置和观看记录保存在本机'),
            trailing: Icon(Icons.check_circle_rounded),
          ),
          const SizedBox(height: 24),
          SectionHeading(
            title: '短视频平台 API',
            detail: _tikHubConfigured
                ? 'TikHub 已配置，TikTok、抖音与 YouTube Shorts 可参与推荐'
                : 'TikTok 公共推荐默认启用，配置 TikHub 后接入抖音与 YouTube Shorts',
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _tikHubToken,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    hintText: _tikHubConfigured
                        ? '输入新 Token 进行更新'
                        : 'TikHub Bearer Token',
                    prefixIcon: const Icon(Icons.key_rounded),
                  ),
                  onSubmitted: (_) => _saveTikHub(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: '保存并启用',
                onPressed: _saveTikHub,
                icon: const Icon(Icons.check_rounded),
              ),
            ],
          ),
          const SizedBox(height: 24),
          SectionHeading(
            title: '视频源',
            detail: '${widget.appState.sources.length} 个来源，开关控制是否参与搜索',
            trailing: IconButton(
              tooltip: '添加来源',
              onPressed: _addSource,
              icon: const Icon(Icons.add_circle_outline_rounded),
            ),
          ),
          const SizedBox(height: 8),
          ...widget.appState.sources.map(
            (source) => _SourceRow(
              source: source,
              onToggle: (enabled) {
                final next = widget.appState.sources
                    .map(
                      (item) => item.id == source.id
                          ? CmsSource(
                              id: item.id,
                              name: item.name,
                              type: item.type,
                              api: item.api,
                              enabled: enabled,
                              searchable: item.searchable,
                              headers: item.headers,
                              script: item.script,
                              scriptUrl: item.scriptUrl,
                              ruleConfig: item.ruleConfig,
                              provider: item.provider,
                              region: item.region,
                            )
                          : item,
                    )
                    .toList();
                widget.appState.updateSources(next);
              },
              onDelete: source.id.startsWith('builtin-')
                  ? null
                  : () => _removeSource(source),
            ),
          ),
          const SizedBox(height: 28),
          const SectionHeading(
            title: 'TVBox 点播配置',
            detail: '支持配置 URL、JSON 文件与 CMS 点播来源',
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _importUrl,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    hintText: 'TVBox 点播配置 URL',
                    prefixIcon: Icon(Icons.link_rounded),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: '从 URL 导入',
                onPressed: _importing ? null : _importFromUrl,
                icon: const Icon(Icons.download_rounded),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _importing ? null : _importFile,
              icon: const Icon(Icons.file_open_outlined),
              label: const Text('从文件导入 JSON 配置'),
            ),
          ),
          if (_importing)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          const SizedBox(height: 28),
          const SectionHeading(title: '播放画质', detail: '播放器首次加载时使用的清晰度偏好'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in const [
                ('auto', '自动'),
                ('highest', '最高'),
                ('1080p', '1080P'),
                ('720p', '720P'),
              ])
                ChoiceChip(
                  label: Text(option.$2),
                  selected: widget.appState.qualityPreference == option.$1,
                  onSelected: (_) {
                    HapticFeedback.selectionClick();
                    widget.appState.updateQualityPreference(option.$1);
                  },
                ),
            ],
          ),
          const SizedBox(height: 18),
          const Text('本地引擎运行中 · 数据仅保存在本机', style: TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}

class _SourceRow extends StatelessWidget {
  final CmsSource source;
  final ValueChanged<bool> onToggle;
  final VoidCallback? onDelete;

  const _SourceRow({
    required this.source,
    required this.onToggle,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(
          children: [
            Icon(Icons.dns_outlined, color: colors.secondary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    source.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    source.type == 'spider'
                        ? 'Spider 规则源'
                        : source.type == 'short-api'
                        ? '平台接口 · ${source.provider}'
                        : (source.api ?? ''),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            Switch(value: source.enabled, onChanged: onToggle),
            if (onDelete != null)
              IconButton(
                tooltip: '移除来源',
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline_rounded),
              ),
          ],
        ),
      ),
    );
  }
}
