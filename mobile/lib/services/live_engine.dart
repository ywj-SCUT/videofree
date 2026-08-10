import 'dart:convert';

import '../models/models.dart';

class LiveEngine {
  List<LiveChannel> parseLivePlaylist(
    String content,
    String sourceId,
    String sourceName,
  ) {
    final normalized = content.isNotEmpty && content.codeUnitAt(0) == 0xFEFF
        ? content.substring(1)
        : content;
    final lines = normalized
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    final channels = <LiveChannel>[];
    var group = sourceName.isEmpty ? '未分组' : sourceName;

    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      if (line.startsWith('#EXTINF:')) {
        final attrs = _attributes(line);
        final commaAt = line.lastIndexOf(',');
        final name = (commaAt >= 0
                ? line.substring(commaAt + 1)
                : attrs['tvg-name'] ?? '')
            .trim();
        final next = index + 1 < lines.length ? lines[index + 1] : '';
        final urls = next.isNotEmpty && !next.startsWith('#')
            ? _validStreamUrls(next)
            : <String>[];
        if (name.isNotEmpty && urls.isNotEmpty) {
          final channelGroup = attrs['group-title'] ?? group;
          _addChannel(
            channels,
            LiveChannel(
              id: _stableId(sourceId, channelGroup, name),
              sourceId: sourceId,
              sourceName: sourceName,
              name: name,
              group: channelGroup,
              logo: attrs['tvg-logo'],
              url: urls.first,
              urls: urls,
            ),
          );
          index++;
        }
        continue;
      }
      if (line.startsWith('#')) continue;
      final commaAt = line.indexOf(',');
      if (commaAt < 0) continue;
      final name = line.substring(0, commaAt).trim();
      final value = line.substring(commaAt + 1).trim();
      if (RegExp(r'^#genre#$', caseSensitive: false).hasMatch(value)) {
        if (name.isNotEmpty) group = name;
        continue;
      }
      final urls = _validStreamUrls(value);
      if (name.isEmpty || urls.isEmpty) continue;
      _addChannel(
        channels,
        LiveChannel(
          id: _stableId(sourceId, group, name),
          sourceId: sourceId,
          sourceName: sourceName,
          name: name,
          group: group,
          url: urls.first,
          urls: urls,
        ),
      );
    }
    return channels;
  }

  Map<String, String> _attributes(String line) {
    final result = <String, String>{};
    for (final match in RegExp(r'([\w-]+)="([^"]*)"').allMatches(line)) {
      result[match.group(1)!.toLowerCase()] = match.group(2)!;
    }
    return result;
  }

  List<String> _validStreamUrls(String value) => value
      .split(RegExp(r'#(?=https?://)', caseSensitive: false))
      .map((entry) => entry.trim().replaceFirst(RegExp(r'^#'), ''))
      .where((entry) => RegExp(r'^https?://', caseSensitive: false).hasMatch(entry))
      .toList();

  void _addChannel(List<LiveChannel> channels, LiveChannel channel) {
    final index = channels.indexWhere(
      (entry) => entry.group == channel.group && entry.name == channel.name,
    );
    if (index < 0) {
      channels.add(channel);
      return;
    }
    final existing = channels[index];
    final urls = <String>{
      ...(existing.urls ?? [existing.url]),
      ...(channel.urls ?? [channel.url]),
    }.toList();
    channels[index] = LiveChannel(
      id: existing.id,
      sourceId: existing.sourceId,
      sourceName: existing.sourceName,
      name: existing.name,
      group: existing.group,
      url: urls.first,
      urls: urls,
      logo: existing.logo?.isNotEmpty == true ? existing.logo : channel.logo,
    );
  }

  String _stableId(String sourceId, String group, String name) {
    final encoded = base64Url.encode(utf8.encode('$sourceId\n$group\n$name'));
    return 'live-${encoded.replaceAll('=', '').substring(0, encoded.length.clamp(0, 22))}';
  }
}
