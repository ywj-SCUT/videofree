class HlsFilterResult {
  final String manifest;
  final int removedSegments;
  final double removedDuration;
  final int removedMarkers;

  const HlsFilterResult({
    required this.manifest,
    required this.removedSegments,
    required this.removedDuration,
    required this.removedMarkers,
  });
}

class _SegmentBlock {
  final List<String> tags;
  final String uri;
  final double duration;

  const _SegmentBlock(this.tags, this.uri, this.duration);
}

final _segmentTag = RegExp(
  r'^(#EXTINF|#EXT-X-(?:BYTERANGE|KEY|MAP|DISCONTINUITY|PROGRAM-DATE-TIME|DATERANGE|CUE-|SCTE35|ASSET)|#EXT-OATCLS-SCTE35)',
  caseSensitive: false,
);
final _markerTag = RegExp(
  r'^(#EXT-X-(?:CUE-|SCTE35|ASSET)|#EXT-OATCLS-SCTE35)',
  caseSensitive: false,
);
final _adUriToken = RegExp(
  r'(?:^|[./_-])(?:ads?|advert|adserver|commercial|preroll|midroll|postroll)(?:[./_-]|$)',
  caseSensitive: false,
);

double _durationFromExtinf(String line) =>
    double.tryParse(
      RegExp(
            r'^#EXTINF:([\d.]+)',
            caseSensitive: false,
          ).firstMatch(line)?.group(1) ??
          '',
    ) ??
    0;

bool _isAdUri(String value) {
  try {
    final uri = Uri.parse(value);
    return _adUriToken.hasMatch('${uri.host}${uri.path}');
  } catch (_) {
    return false;
  }
}

({bool ad, bool external, double duration}) _adDateRange(String line) {
  if (!line.toUpperCase().startsWith('#EXT-X-DATERANGE:')) {
    return (ad: false, external: false, duration: 0);
  }
  final ad =
      RegExp(
        r'(?:CLASS|ID)="[^"]*(?:interstitial|advert|commercial|\bad\b)[^"]*"',
        caseSensitive: false,
      ).hasMatch(line) ||
      RegExp(r'SCTE35-OUT=', caseSensitive: false).hasMatch(line);
  final external = RegExp(
    r'X-ASSET-(?:URI|LIST)=',
    caseSensitive: false,
  ).hasMatch(line);
  final duration =
      double.tryParse(
        RegExp(
              r'(?:PLANNED-)?DURATION=([\d.]+)',
              caseSensitive: false,
            ).firstMatch(line)?.group(1) ??
            '',
      ) ??
      0;
  return (ad: ad, external: external, duration: duration);
}

HlsFilterResult filterHlsManifest(String manifest) {
  final entries = <Object>[];
  var tags = <String>[];
  var duration = 0.0;
  for (final line in manifest.split(RegExp(r'\r?\n'))) {
    final trimmed = line.trim();
    if (trimmed.toUpperCase().startsWith('#EXTINF:')) {
      tags.add(line);
      duration = _durationFromExtinf(trimmed);
      continue;
    }
    if (tags.isNotEmpty && trimmed.isNotEmpty && !trimmed.startsWith('#')) {
      entries.add(_SegmentBlock(tags, line, duration));
      tags = <String>[];
      duration = 0;
      continue;
    }
    if (_segmentTag.hasMatch(trimmed)) {
      tags.add(line);
      continue;
    }
    if (tags.isNotEmpty) {
      entries.addAll(tags);
      tags = <String>[];
      duration = 0;
    }
    entries.add(line);
  }
  entries.addAll(tags);

  final output = <Object>[];
  var inCue = false;
  var timedAdRemaining = 0.0;
  var removedSegments = 0;
  var removedDuration = 0.0;
  var removedMarkers = 0;
  var removedBeforeFirstKept = 0;
  var keptSegments = 0;
  var needsDiscontinuity = false;
  String? activeKey;
  String? activeMap;
  String? emittedKey;
  String? emittedMap;

  for (final entry in entries) {
    if (entry is String) {
      final range = _adDateRange(entry.trim());
      if (range.ad) {
        removedMarkers++;
        if (!range.external && range.duration > 0) {
          timedAdRemaining = timedAdRemaining < range.duration
              ? range.duration
              : timedAdRemaining;
        }
        continue;
      }
      output.add(entry);
      continue;
    }

    final block = entry as _SegmentBlock;
    for (final tag in block.tags) {
      final trimmed = tag.trim().toUpperCase();
      if (trimmed.startsWith('#EXT-X-KEY:')) activeKey = tag;
      if (trimmed.startsWith('#EXT-X-MAP:')) activeMap = tag;
    }
    final hasCueIn = block.tags.any(
      (tag) => tag.trim().toUpperCase().startsWith('#EXT-X-CUE-IN'),
    );
    final hasCueOut = block.tags.any(
      (tag) => tag.trim().toUpperCase().startsWith('#EXT-X-CUE-OUT'),
    );
    if (hasCueIn) inCue = false;
    if (hasCueOut) inCue = true;
    for (final tag in block.tags) {
      final range = _adDateRange(tag.trim());
      if (range.ad) {
        removedMarkers++;
        if (!range.external && range.duration > 0) {
          timedAdRemaining = timedAdRemaining < range.duration
              ? range.duration
              : timedAdRemaining;
        }
      }
      if (_markerTag.hasMatch(tag.trim())) removedMarkers++;
    }

    final drop = inCue || timedAdRemaining > 0 || _isAdUri(block.uri.trim());
    if (drop) {
      removedSegments++;
      removedDuration += block.duration;
      if (keptSegments == 0) removedBeforeFirstKept++;
      timedAdRemaining = (timedAdRemaining - block.duration)
          .clamp(0, double.infinity)
          .toDouble();
      needsDiscontinuity = keptSegments > 0;
      continue;
    }

    final keptTags = block.tags
        .where(
          (tag) =>
              !_markerTag.hasMatch(tag.trim()) && !_adDateRange(tag.trim()).ad,
        )
        .toList();
    final hasKey = keptTags.any(
      (tag) => tag.trim().toUpperCase().startsWith('#EXT-X-KEY:'),
    );
    final hasMap = keptTags.any(
      (tag) => tag.trim().toUpperCase().startsWith('#EXT-X-MAP:'),
    );
    keptTags.insertAll(0, [
      if (!hasKey && activeKey != null && activeKey != emittedKey) activeKey,
      if (!hasMap && activeMap != null && activeMap != emittedMap) activeMap,
    ]);
    if (needsDiscontinuity &&
        !keptTags.any(
          (tag) => tag.trim().toUpperCase().startsWith('#EXT-X-DISCONTINUITY'),
        )) {
      keptTags.insert(0, '#EXT-X-DISCONTINUITY');
    }
    output.add(_SegmentBlock(keptTags, block.uri, block.duration));
    for (final tag in keptTags) {
      final trimmed = tag.trim().toUpperCase();
      if (trimmed.startsWith('#EXT-X-KEY:')) emittedKey = tag;
      if (trimmed.startsWith('#EXT-X-MAP:')) emittedMap = tag;
    }
    keptSegments++;
    needsDiscontinuity = false;
  }

  final lines = <String>[];
  for (final entry in output) {
    if (entry is String) {
      lines.add(entry);
    } else {
      final block = entry as _SegmentBlock;
      lines.addAll(block.tags);
      lines.add(block.uri);
    }
  }
  if (removedBeforeFirstKept > 0) {
    final sequence = RegExp(r'(MEDIA-SEQUENCE:)(\d+)', caseSensitive: false);
    final index = lines.indexWhere(
      (line) => line.trim().toUpperCase().startsWith('#EXT-X-MEDIA-SEQUENCE:'),
    );
    if (index >= 0) {
      lines[index] = lines[index].replaceFirstMapped(
        sequence,
        (match) =>
            '${match.group(1)}${int.parse(match.group(2)!) + removedBeforeFirstKept}',
      );
    }
  }
  return HlsFilterResult(
    manifest: lines.join('\n'),
    removedSegments: removedSegments,
    removedDuration: removedDuration,
    removedMarkers: removedMarkers,
  );
}
