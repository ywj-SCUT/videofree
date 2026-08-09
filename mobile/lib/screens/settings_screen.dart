import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../models/models.dart';
import '../services/app_state.dart';

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
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      _message('请输入有效的 HTTP/HTTPS 地址');
      return;
    }
    await widget.appState.updateServerUrl(value);
    _message('服务地址已保存');
  }

  Future<void> _applyImport(ImportResult result) async {
    if (result.sources.isNotEmpty) {
      await widget.appState.mergeImportedSources(result.sources);
    }
    if (result.lives.isNotEmpty) {
      final map = {for (var c in widget.appState.liveChannels) c.id: c};
      for (final c in result.lives) {
        map[c.id] = c;
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
    } catch (e) {
      _message('导入失败：$e');
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
      final content = utf8.decode(bytes);
      final result = await widget.appState.api.importContent(
        content,
        file.name,
      );
      await _applyImport(result);
    } catch (e) {
      _message('导入失败：$e');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _addSource() async {
    final name = TextEditingController();
    final api = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加 CMS 视频源'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: '来源名称'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: api,
              decoration: const InputDecoration(labelText: 'API 地址'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (result == true &&
        name.text.trim().isNotEmpty &&
        api.text.trim().startsWith('http')) {
      final source = CmsSource(
        id: 'mobile-${DateTime.now().millisecondsSinceEpoch}',
        name: name.text.trim(),
        type: 'cms',
        api: api.text.trim(),
        enabled: true,
        searchable: true,
      );
      await widget.appState.updateSources([...widget.appState.sources, source]);
    }
  }

  void _message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'VideoGET 服务',
            style: TextStyle(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _server,
                  decoration: const InputDecoration(
                    hintText: 'http://10.0.2.2:3000',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: _saveServer, child: const Text('保存')),
            ],
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Text(
                '视频源 (${widget.appState.sources.length})',
                style: TextStyle(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              IconButton(
                onPressed: _addSource,
                icon: const Icon(Icons.add),
                tooltip: '添加来源',
              ),
            ],
          ),
          ...widget.appState.sources.map(
            (source) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Switch(
                value: source.enabled,
                onChanged: (value) {
                  final next = widget.appState.sources
                      .map(
                        (s) => s.id == source.id
                            ? CmsSource(
                                id: s.id,
                                name: s.name,
                                type: s.type,
                                api: s.api,
                                enabled: value,
                                searchable: s.searchable,
                                headers: s.headers,
                                script: s.script,
                                scriptUrl: s.scriptUrl,
                                ruleConfig: s.ruleConfig,
                              )
                            : s,
                      )
                      .toList();
                  widget.appState.updateSources(next);
                },
              ),
              title: Text(source.name),
              subtitle: Text(
                source.type == 'spider' ? 'Spider 规则源' : (source.api ?? ''),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => widget.appState.updateSources(
                  widget.appState.sources
                      .where((s) => s.id != source.id)
                      .toList(),
                ),
              ),
            ),
          ),
          const Divider(height: 32),
          Text(
            'TVBox / IPTV 导入',
            style: TextStyle(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _importUrl,
                  decoration: const InputDecoration(hintText: '配置或播放列表 URL'),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _importing ? null : _importFromUrl,
                child: const Text('导入'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _importing ? null : _importFile,
            icon: const Icon(Icons.file_open),
            label: const Text('从文件导入 JSON / M3U'),
          ),
          if (_importing)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Center(child: CircularProgressIndicator()),
            ),
          const SizedBox(height: 24),
          Text(
            '播放画质',
            style: TextStyle(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'auto', label: Text('自动')),
              ButtonSegment(value: 'highest', label: Text('最高')),
              ButtonSegment(value: '1080p', label: Text('1080P')),
              ButtonSegment(value: '720p', label: Text('720P')),
            ],
            selected: {widget.appState.qualityPreference},
            onSelectionChanged: (value) =>
                widget.appState.updateQualityPreference(value.first),
          ),
        ],
      ),
    );
  }
}
