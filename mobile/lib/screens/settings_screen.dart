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
  late final TextEditingController _server;
  final _importUrl = TextEditingController();
  bool _importing = false;
  String? _serverError;

  @override
  void initState() {
    super.initState();
    _server = TextEditingController(text: widget.appState.serverUrl);
    widget.appState.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.appState.removeListener(_refresh);
    _server.dispose();
    _importUrl.dispose();
    super.dispose();
  }

  Future<void> _saveServer() async {
    final value = _server.text.trim().replaceAll(RegExp(r'/$'), '');
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      setState(() => _serverError = '请输入有效的 HTTP/HTTPS 地址');
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    await widget.appState.updateServerUrl(value);
    if (mounted) {
      setState(() => _serverError = null);
      _message('服务地址已保存');
    }
  }

  Future<void> _applyImport(ImportResult result) async {
    if (result.sources.isNotEmpty) {
      await widget.appState.mergeImportedSources(result.sources);
    }
    if (result.lives.isNotEmpty) {
      final map = {
        for (var channel in widget.appState.liveChannels) channel.id: channel,
      };
      for (final channel in result.lives) {
        map[channel.id] = channel;
      }
      await widget.appState.setLiveChannels(map.values.toList());
    }
    _message(
      '导入 ${result.sources.length} 个视频源、${result.lives.length} 个频道${result.failures.isNotEmpty ? '，${result.failures.length} 项失败' : ''}',
    );
  }

  Future<void> _importFromUrl() async {
    final url = _importUrl.text.trim();
    if (url.isEmpty) return;
    setState(() => _importing = true);
    try {
      final result = await widget.appState.api.importUrl(url);
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
      allowedExtensions: ['json', 'txt', 'm3u', 'm3u8'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    setState(() => _importing = true);
    try {
      final file = picked.files.first;
      final bytes = file.bytes;
      if (bytes == null) throw Exception('未读取到文件内容');
      final result = await widget.appState.api.importContent(
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
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 112),
        children: [
          const SectionHeading(
            title: '运行模式',
            detail: '本地模式无需电脑，直接在手机上请求视频源；远程模式连接电脑上的 VideoGET 服务',
          ),
          const SizedBox(height: 10),
          SwitchListTile(
            title: const Text('本地模式（不连电脑）'),
            subtitle: Text(
              widget.appState.localMode
                  ? '已开启：手机直接请求 CMS 视频源'
                  : '已关闭：需要电脑运行 VideoGET 服务',
            ),
            value: widget.appState.localMode,
            onChanged: (value) => widget.appState.updateLocalMode(value),
          ),
          const SizedBox(height: 20),
          const SectionHeading(
            title: 'VideoGET 服务',
            detail: '移动端通过这个地址访问聚合 API',
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _server,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _saveServer(),
                  decoration: InputDecoration(
                    hintText: 'http://10.0.2.2:3000',
                    errorText: _serverError,
                    prefixIcon: const Icon(Icons.dns_outlined),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: '保存服务地址',
                onPressed: _saveServer,
                icon: const Icon(Icons.save_outlined),
              ),
            ],
          ),
          if (widget.appState.localMode)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '本地模式已开启，无需填写此地址。切换到远程模式后此地址生效。',
                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
              ),
            ),
          const SizedBox(height: 28),
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
                            )
                          : item,
                    )
                    .toList();
                widget.appState.updateSources(next);
              },
              onDelete: () => _removeSource(source),
            ),
          ),
          const SizedBox(height: 28),
          const SectionHeading(
            title: 'TVBox / IPTV 导入',
            detail: '支持配置 URL、CMS、M3U 和 M3U8 内容',
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _importUrl,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    hintText: '配置或播放列表 URL',
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
              label: const Text('从文件导入 JSON / M3U'),
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
          Text(
            '当前服务：${widget.appState.serverUrl}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _SourceRow extends StatelessWidget {
  final CmsSource source;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;

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
                    source.type == 'spider' ? 'Spider 规则源' : (source.api ?? ''),
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
