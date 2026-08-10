import 'dart:convert';

import '../models/models.dart';
import 'net_service.dart';

class IptvCatalog {
  IptvCatalog({NetService? net}) : _net = net ?? NetService();

  final NetService _net;

  static const _channelsUrl = 'https://iptv-org.github.io/api/channels.json';
  static const _streamsUrl = 'https://iptv-org.github.io/api/streams.json';
  static const _includedCountries = {'CN', 'HK', 'MO', 'TW'};
  static const _countryNames = {
    'CN': '中国大陆',
    'HK': '中国香港',
    'MO': '中国澳门',
    'TW': '中国台湾',
  };

  Future<List<LiveChannel>> fetchIptvCatalog() async {
    final values = await Future.wait([
      _net.fetchRemoteText(
        _channelsUrl,
        timeout: const Duration(seconds: 30),
        maxBytes: 15 * 1024 * 1024,
      ),
      _net.fetchRemoteText(
        _streamsUrl,
        timeout: const Duration(seconds: 30),
        maxBytes: 8 * 1024 * 1024,
      ),
    ]);
    return buildIptvCatalog(
      jsonDecode(values[0]) as List<dynamic>,
      jsonDecode(values[1]) as List<dynamic>,
    );
  }

  List<LiveChannel> buildIptvCatalog(
    List<dynamic> channels,
    List<dynamic> streams,
  ) {
    final metadata = <String, Map<String, dynamic>>{};
    for (final raw in channels) {
      final channel = _map(raw);
      final id = _text(channel['id']);
      final name = _text(channel['name']);
      final country = _text(channel['country']);
      if (id.isEmpty ||
          name.isEmpty ||
          !_includedCountries.contains(country) ||
          channel['is_nsfw'] == true) {
        continue;
      }
      metadata[id] = channel;
    }
    final result = <String, LiveChannel>{};
    for (final raw in streams) {
      final stream = _map(raw);
      final channelId = _text(stream['channel']);
      final url = _text(stream['url']);
      final channel = metadata[channelId];
      if (channel == null ||
          !RegExp(r'^https?://', caseSensitive: false).hasMatch(url)) {
        continue;
      }
      final existing = result[channelId];
      if (existing != null) {
        final urls = <String>{...(existing.urls ?? [existing.url]), url}.toList();
        result[channelId] = LiveChannel(
          id: existing.id,
          sourceId: existing.sourceId,
          sourceName: existing.sourceName,
          name: existing.name,
          group: existing.group,
          url: urls.first,
          urls: urls,
          logo: existing.logo,
        );
        continue;
      }
      final categories = channel['categories'] is List
          ? channel['categories'] as List<dynamic>
          : const <dynamic>[];
      final country = _text(channel['country']);
      final category = categories.isNotEmpty ? _text(categories.first) : '综合';
      result[channelId] = LiveChannel(
        id: _channelId(channelId),
        sourceId: 'iptv-org',
        sourceName: 'IPTV.org',
        name: _text(channel['name']),
        group: '${_countryNames[country] ?? country} · $category',
        logo: _text(channel['logo']).isEmpty ? null : _text(channel['logo']),
        url: url,
        urls: [url],
      );
    }
    final output = result.values.toList();
    output.sort((left, right) {
      final group = left.group.compareTo(right.group);
      return group != 0 ? group : left.name.compareTo(right.name);
    });
    return output;
  }

  String _channelId(String id) {
    final encoded = base64Url.encode(utf8.encode(id)).replaceAll('=', '');
    return 'iptv-${encoded.substring(0, encoded.length.clamp(0, 16))}';
  }

  String _text(dynamic value) => value?.toString().trim() ?? '';
  Map<String, dynamic> _map(dynamic value) => value is Map
      ? value.map((key, item) => MapEntry(key.toString(), item))
      : <String, dynamic>{};
}
