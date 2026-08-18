import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math' as math;

import '../models/models.dart';
import 'net_service.dart';

typedef PlaybackProbe =
    Future<RemoteProbe> Function(
      String url, {
      Map<String, String>? headers,
      Duration timeout,
      int maxBytes,
    });

void _debugRouteLog(String message) {
  assert(() {
    developer.log(message, name: 'VideoGET.RouteEngine.Debug');
    return true;
  }());
}

class RouteEngine {
  RouteEngine({
    NetService? net,
    PlaybackProbe? probe,
    this.probeTimeout = const Duration(milliseconds: 3500),
    this.routeBudget = const Duration(seconds: 10),
  }) : _net = net ?? NetService() {
    _probe = probe;
  }

  static final Map<String, _RouteHealth> _health = {};
  static const Map<String, double> _validatedStabilityPrior = {
    // Historical success is only a tie-breaker. Current latency, throughput,
    // and decoded playback health must dominate when a route degrades later.
    'builtin-line-b': 45,
  };
  static const Map<String, double> _observedUnreliablePenalty = {
    // Current AVD playback can expose a first frame before the source resets
    // its decoder or stalls. Byte-level probes alone therefore over-rank it.
    'builtin-line-a': 1600,
    // The current AVD path repeatedly reaches this route's encrypted media
    // host but fails to decrypt the first segment (port 999). Keep it as a
    // fallback while preventing a fast manifest probe from selecting it.
    'builtin-line-b': 2600,
    'builtin-line-e': 1600,
    'builtin-line-f': 1600,
    // Two real AVD runs produced corrupt AAC frames and a zero-position stall
    // on this route. Keep it available as a last resort, but never let a fast
    // manifest probe put it ahead of a route that can sustain playback.
    'builtin-line-h': 1600,
    // Repeated real playback runs reached a first frame on this route and then
    // reset to zero without making sustained progress.
    'builtin-line-g': 1600,
    'builtin-line-c': 1600,
    // The current AVD run also reaches a first frame on this route and then
    // resets before a stable playback window.
    'builtin-line-i': 1600,
    // J/K/L currently resolve to media hosts on ports 999/18443/65 in the
    // networked AVD and cannot complete the first-segment handshake there.
    'builtin-line-j': 3200,
    'builtin-line-k': 3200,
    'builtin-line-l': 3200,
    'builtin-line-m': 3200,
  };

  static double validatedStabilityPrior(String? sourceId) =>
      _validatedStabilityPrior[sourceId] ?? 0;

  final NetService _net;
  late final PlaybackProbe? _probe;
  final Duration probeTimeout;
  final Duration routeBudget;

  Future<List<PlayLine>> rankLines(
    List<PlayLine> lines, {
    String? preferredLineName,
    String? episodeName,
  }) async {
    if (lines.length < 2) return List.of(lines);
    final candidates = lines
        .asMap()
        .entries
        .map(
          (entry) => _RouteCandidate(
            index: entry.key,
            line: entry.value,
            episode: _representativeEpisode(entry.value, episodeName),
          ),
        )
        .toList();
    final probeCandidates =
        candidates
            .where((candidate) => _isHttp(candidate.episode?.url))
            .toList()
          ..sort((left, right) {
            final rightPriority =
                _historicalScore(right, preferredLineName) -
                _observedUnreliablePenaltyFor(right.episode);
            final leftPriority =
                _historicalScore(left, preferredLineName) -
                _observedUnreliablePenaltyFor(left.episode);
            return rightPriority.compareTo(leftPriority);
          });
    final selected = probeCandidates.take(8).toList();
    final futures = selected.map((candidate) async {
      try {
        return await _probeLine(candidate).timeout(routeBudget);
      } catch (error) {
        if (_isTimeoutError(error)) {
          return _RouteResult.timedOut(candidate.index);
        }
        recordPlaybackFailure(candidate.episode!);
        return _RouteResult.failed(candidate.index);
      }
    });
    final results = <int, _RouteResult>{
      for (final result in await Future.wait(futures)) result.index: result,
    };
    for (final candidate in selected) {
      final result = results[candidate.index];
      _debugRouteLog(
        'candidate=${candidate.line.name} source=${candidate.episode?.sourceId} '
        'success=${result?.success} timedOut=${result?.timedOut} '
        'latencyMs=${result?.latencyMs} '
        'throughputBps=${result?.throughputBps.toStringAsFixed(0)}',
      );
    }
    candidates.sort((left, right) {
      final rightScore = _score(right, results[right.index], preferredLineName);
      final leftScore = _score(left, results[left.index], preferredLineName);
      final comparison = rightScore.compareTo(leftScore);
      return comparison == 0 ? left.index.compareTo(right.index) : comparison;
    });
    return candidates.map((candidate) => candidate.line).toList();
  }

  static void recordPlaybackSuccess(Episode episode, {Duration? latency}) {
    final health = _health.putIfAbsent(_healthKey(episode), _RouteHealth.new);
    health.successRate = health.successRate * .75 + .25;
    health.consecutiveFailures = 0;
    if (latency != null) {
      health.latencyMs = health.latencyMs == null
          ? latency.inMilliseconds.toDouble()
          : health.latencyMs! * .7 + latency.inMilliseconds * .3;
    }
  }

  static void recordPlaybackFailure(Episode episode) {
    final health = _health.putIfAbsent(_healthKey(episode), _RouteHealth.new);
    health.successRate *= .65;
    health.consecutiveFailures++;
  }

  static void resetHealthForTesting() => _health.clear();

  Future<_RouteResult> _probeLine(_RouteCandidate candidate) async {
    final episode = candidate.episode!;
    final deadline = DateTime.now().add(routeBudget);
    final manifestProbe = await _load(
      episode.url,
      headers: episode.headers,
      timeout: _stageTimeout(deadline),
      maxBytes: 384 * 1024,
    );
    final lowerType = manifestProbe.contentType.toLowerCase();
    final isManifest =
        episode.url.toLowerCase().contains('.m3u8') ||
        lowerType.contains('mpegurl') ||
        _looksLikeManifest(manifestProbe.bytes);
    if (!isManifest) {
      if (manifestProbe.bytes.isEmpty) {
        recordPlaybackFailure(episode);
        return _RouteResult.failed(candidate.index);
      }
      recordPlaybackSuccess(episode, latency: manifestProbe.elapsed);
      return _RouteResult(
        index: candidate.index,
        success: true,
        latencyMs: manifestProbe.elapsed.inMilliseconds,
        throughputBps: _throughput(manifestProbe),
        usedProxy: manifestProbe.usedProxy,
      );
    }

    var manifestUrl = manifestProbe.finalUri;
    var manifest = _decode(manifestProbe.bytes);
    var resolutionHeight = 0;
    var bandwidth = 0;
    var manifestLatency = manifestProbe.elapsed;
    var usedProxy = manifestProbe.usedProxy;
    var nonStandardPort = _hasNonStandardPort(manifestUrl);
    var mediaHeaders = _headersWithReferer(episode.headers, manifestUrl);
    final variants = _parseVariants(manifest, manifestUrl);
    if (variants.isNotEmpty) {
      final withinLimit = variants
          .where((variant) => variant.height > 0 && variant.height <= 1080)
          .toList();
      final selectable = withinLimit.isNotEmpty ? withinLimit : variants;
      selectable.sort((left, right) {
        final quality = withinLimit.isNotEmpty
            ? right.height.compareTo(left.height)
            : left.height.compareTo(right.height);
        return quality == 0
            ? right.bandwidth.compareTo(left.bandwidth)
            : quality;
      });
      final selected = selectable.first;
      resolutionHeight = selected.height;
      bandwidth = selected.bandwidth;
      final mediaProbe = await _load(
        selected.url.toString(),
        headers: episode.headers,
        timeout: _stageTimeout(deadline),
        maxBytes: 384 * 1024,
      );
      manifestUrl = mediaProbe.finalUri;
      manifest = _decode(mediaProbe.bytes);
      manifestLatency += mediaProbe.elapsed;
      usedProxy = usedProxy || mediaProbe.usedProxy;
      nonStandardPort = nonStandardPort || _hasNonStandardPort(manifestUrl);
      mediaHeaders = _headersWithReferer(episode.headers, manifestUrl);
    }
    // Probe the opening pair plus distant VOD anchors. Keeping this bounded
    // protects cold playback from route probes consuming the same source
    // bandwidth that the selected player needs for its first frame.
    final segmentUrls = _segmentUrls(manifest, manifestUrl, limit: 2);
    nonStandardPort = nonStandardPort || segmentUrls.any(_hasNonStandardPort);
    if (segmentUrls.isEmpty) {
      recordPlaybackSuccess(episode, latency: manifestLatency);
      return _RouteResult(
        index: candidate.index,
        success: true,
        latencyMs: manifestLatency.inMilliseconds,
        resolutionHeight: resolutionHeight,
        bandwidth: bandwidth,
        usedProxy: usedProxy,
      );
    }
    // Candidate lines are already probed concurrently. Keep each line's
    // opening and seek samples sequential so seven lines do not expand into
    // dozens of competing media downloads and make every route time out.
    final segmentProbes = <RemoteProbe>[];
    for (final segmentUrl in segmentUrls) {
      segmentProbes.add(
        await _load(
          segmentUrl.toString(),
          headers: mediaHeaders,
          timeout: _stageTimeout(deadline),
          maxBytes: 128 * 1024,
        ),
      );
    }
    if (segmentProbes.any(_isInvalidMediaProbe)) {
      recordPlaybackFailure(episode);
      return _RouteResult.failed(candidate.index);
    }
    // Encrypted HLS can expose a healthy manifest and media-sized error page
    // while the key endpoint is blocked. Probe the first key through the same
    // NetService transport so the route is not ranked above a playable line.
    final keyUrls = _keyUrls(manifest, manifestUrl, limit: 1);
    nonStandardPort = nonStandardPort || keyUrls.any(_hasNonStandardPort);
    for (final keyUrl in keyUrls) {
      // Keep key validation on the same transport path as the manifest. A
      // proxy can serve the playlist and media CDN while its TLS path to the
      // key origin is broken; allowing a direct fallback here would rank a
      // route that the Android playback proxy cannot decrypt reliably.
      if (manifestProbe.usedProxy) {
        NetService.recordProxyResult(keyUrl, usedProxy: true);
      }
      final keyProbe = await _load(
        keyUrl.toString(),
        headers: mediaHeaders,
        timeout: _stageTimeout(deadline),
        maxBytes: 16 * 1024,
      );
      if (_isInvalidMediaProbe(keyProbe) ||
          (manifestProbe.usedProxy && !keyProbe.usedProxy)) {
        recordPlaybackFailure(episode);
        return _RouteResult.failed(candidate.index);
      }
    }
    final slowestSegment = segmentProbes
        .map((probe) => probe.elapsed)
        .reduce((left, right) => left > right ? left : right);
    // Rank against the slowest sustained sample so a route that bursts an
    // early byte but stalls afterward cannot displace a responsive route.
    final totalLatency = manifestLatency + slowestSegment;
    final throughputBps = segmentProbes.map(_throughput).reduce(math.min);
    recordPlaybackSuccess(episode, latency: totalLatency);
    return _RouteResult(
      index: candidate.index,
      success: true,
      latencyMs: totalLatency.inMilliseconds,
      resolutionHeight: resolutionHeight,
      bandwidth: bandwidth,
      throughputBps: throughputBps,
      usedProxy: usedProxy || segmentProbes.any((probe) => probe.usedProxy),
      nonStandardPort: nonStandardPort,
    );
  }

  Future<RemoteProbe> _load(
    String url, {
    Map<String, String>? headers,
    required Duration timeout,
    required int maxBytes,
  }) {
    final probe = _probe;
    if (probe != null) {
      return probe(url, headers: headers, timeout: timeout, maxBytes: maxBytes);
    }
    return _net.probeRemote(
      url,
      headers: headers,
      timeout: timeout,
      maxBytes: maxBytes,
    );
  }

  Duration _stageTimeout(DateTime deadline) {
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      throw TimeoutException('Route probe budget exhausted', routeBudget);
    }
    return remaining < probeTimeout ? remaining : probeTimeout;
  }

  double _score(
    _RouteCandidate candidate,
    _RouteResult? result,
    String? preferredLineName,
  ) {
    var score = _historicalScore(candidate, preferredLineName);
    score -= _observedUnreliablePenaltyFor(candidate.episode);
    score -= _nonStandardPortPenalty(candidate.episode);
    if (result == null) return score - 80;
    if (result.timedOut) {
      // A timeout is inconclusive, but it must not keep a slow route ahead of
      // a route that is responding now. The small residual prior only breaks
      // ties between otherwise uninformative candidates.
      return score -
          200 +
          math.min(_validatedStabilityPriorFor(candidate.episode), 120);
    }
    if (!result.success) {
      return score - 900 - _validatedStabilityPriorFor(candidate.episode);
    }
    score += 520;
    // The configured system proxy is often the only stable path on Android.
    // Keep a modest cost for the extra hop without allowing it to outweigh
    // sustained-playback evidence from a route that is healthy right now.
    if (result.usedProxy) score -= 150;
    if (result.nonStandardPort) score -= 520;
    score += _validatedStabilityPriorFor(candidate.episode);
    score += math.min(result.resolutionHeight, 1080) / 1080 * 240;
    score -= math.min(result.latencyMs, 8000) / 8000 * 320;
    if (result.throughputBps > 0) {
      if (result.bandwidth > 0) {
        final headroom = result.throughputBps / result.bandwidth;
        if (headroom < 1) {
          score -= 320;
        } else if (headroom < 1.3) {
          score -= 150;
        } else {
          score += math.min((headroom - 1.3) * 100, 150);
        }
      } else {
        score += math.min(result.throughputBps / 100000, 140);
      }
    }
    return score;
  }

  double _historicalScore(
    _RouteCandidate candidate,
    String? preferredLineName,
  ) {
    final episode = candidate.episode;
    final health = episode == null ? null : _health[_healthKey(episode)];
    var score = preferredLineName == candidate.line.name ? 35.0 : 0.0;
    if (health != null) {
      score += health.successRate * 180;
      score -= health.consecutiveFailures * 180;
      if (health.latencyMs != null) {
        score -= math.min(health.latencyMs!, 8000) / 40;
      }
    }
    if (episode != null && _isHttp(episode.url)) score += 20;
    return score;
  }

  // Playback ordering is based on the current route probe and observed
  // health. Historical priors still help search result grouping, but must not
  // displace a route that responds faster in the current session.
  double _validatedStabilityPriorFor(Episode? episode) => 0;

  double _nonStandardPortPenalty(Episode? episode) {
    final uri = episode == null ? null : Uri.tryParse(episode.url);
    if (uri == null || uri.scheme.toLowerCase() != 'https') return 0;
    final port = uri.port;
    return port > 0 && port != 443 ? 520 : 0;
  }

  double _observedUnreliablePenaltyFor(Episode? episode) =>
      episode == null ? 0 : _observedUnreliablePenalty[episode.sourceId] ?? 0;

  bool _isTimeoutError(Object error) =>
      error is TimeoutException ||
      error.toString().toLowerCase().contains('timeout');

  Episode? _representativeEpisode(PlayLine line, String? episodeName) {
    if (line.episodes.isEmpty) return null;
    if (episodeName != null) {
      final exact = line.episodes.where(
        (episode) => episode.name == episodeName,
      );
      if (exact.isNotEmpty) return exact.first;
      final number = int.tryParse(
        RegExp(r'\d+').firstMatch(episodeName)?.group(0) ?? '',
      );
      if (number != null) {
        final numbered = line.episodes.where(
          (episode) =>
              int.tryParse(
                RegExp(r'\d+').firstMatch(episode.name)?.group(0) ?? '',
              ) ==
              number,
        );
        if (numbered.isNotEmpty) return numbered.first;
      }
    }
    return line.episodes.firstWhere(
      (episode) => _isHttp(episode.url),
      orElse: () => line.episodes.first,
    );
  }

  List<_HlsVariant> _parseVariants(String manifest, Uri base) {
    final lines = manifest.split(RegExp(r'\r?\n'));
    final result = <_HlsVariant>[];
    for (var index = 0; index < lines.length - 1; index++) {
      final line = lines[index].trim();
      if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
      var next = index + 1;
      while (next < lines.length && lines[next].trim().startsWith('#')) {
        next++;
      }
      if (next >= lines.length || lines[next].trim().isEmpty) continue;
      final attributes = line.substring(line.indexOf(':') + 1);
      final resolution = RegExp(
        r'RESOLUTION=(\d+)x(\d+)',
      ).firstMatch(attributes);
      final bandwidth = RegExp(
        r'(?:AVERAGE-)?BANDWIDTH=(\d+)',
      ).firstMatch(attributes);
      result.add(
        _HlsVariant(
          url: base.resolve(lines[next].trim()),
          height: int.tryParse(resolution?.group(2) ?? '') ?? 0,
          bandwidth: int.tryParse(bandwidth?.group(1) ?? '') ?? 0,
        ),
      );
    }
    return result;
  }

  List<Uri> _segmentUrls(String manifest, Uri base, {required int limit}) {
    final result = <Uri>[];
    final seen = <String>{};
    final entries = <({Uri uri, double duration})>[];
    double? pendingDuration;
    for (final line in manifest.split(RegExp(r'\r?\n'))) {
      final value = line.trim();
      if (value.toUpperCase().startsWith('#EXTINF:')) {
        pendingDuration =
            double.tryParse(
              RegExp(
                    r'^#EXTINF:([\d.]+)',
                    caseSensitive: false,
                  ).firstMatch(value)?.group(1) ??
                  '',
            ) ??
            0;
        continue;
      }
      if (value.isEmpty || value.startsWith('#')) continue;
      final uri = base.resolve(value);
      entries.add((uri: uri, duration: pendingDuration ?? 0));
      pendingDuration = null;
    }
    void add(Uri uri) {
      if (seen.add(uri.toString())) result.add(uri);
    }

    for (final entry in entries.take(limit)) {
      add(entry.uri);
    }
    if (entries.length <= limit) return result;

    const anchors = [300.0, 600.0];
    var elapsed = 0.0;
    var anchorIndex = 0;
    for (final entry in entries) {
      if (anchorIndex >= anchors.length) break;
      if (elapsed >= anchors[anchorIndex]) {
        add(entry.uri);
        anchorIndex++;
      }
      elapsed += math.max(0, entry.duration);
    }
    return result;
  }

  List<Uri> _keyUrls(String manifest, Uri base, {required int limit}) {
    final result = <Uri>[];
    final seen = <String>{};
    for (final line in manifest.split(RegExp(r'\r?\n'))) {
      if (!line.trim().toUpperCase().startsWith('#EXT-X-KEY:')) continue;
      final method = RegExp(
        r'(?:^|,)METHOD=([^,]+)',
        caseSensitive: false,
      ).firstMatch(line)?.group(1)?.trim().toUpperCase();
      if (method == null || method == 'NONE') continue;
      final value = RegExp(
        r'URI="([^"]+)"',
        caseSensitive: false,
      ).firstMatch(line)?.group(1);
      if (value == null || value.isEmpty) continue;
      final uri = base.resolve(value);
      if ({'http', 'https'}.contains(uri.scheme) && seen.add(uri.toString())) {
        result.add(uri);
        if (result.length >= limit) break;
      }
    }
    return result;
  }

  Map<String, String>? _headersWithReferer(
    Map<String, String>? headers,
    Uri referer,
  ) {
    final result = {...?headers};
    if (!result.keys.any((key) => key.toLowerCase() == 'referer')) {
      result['Referer'] = referer.toString();
    }
    return result;
  }

  bool _isInvalidMediaProbe(RemoteProbe probe) {
    if (probe.bytes.isEmpty) return true;
    final type = probe.contentType.toLowerCase();
    if (type.contains('text/html') || type.contains('application/json')) {
      return true;
    }
    final prefix = utf8
        .decode(
          probe.bytes.sublist(0, math.min(probe.bytes.length, 256)),
          allowMalformed: true,
        )
        .trimLeft()
        .toLowerCase();
    return prefix.startsWith('<!doctype') ||
        prefix.startsWith('<html') ||
        prefix.startsWith('{"error"') ||
        prefix.startsWith('access denied') ||
        prefix.startsWith('request blocked');
  }

  double _throughput(RemoteProbe probe) {
    final seconds = math.max(probe.elapsed.inMilliseconds / 1000, .05);
    return probe.bytes.length * 8 / seconds;
  }

  bool _looksLikeManifest(List<int> bytes) =>
      _decode(bytes).startsWith('#EXTM3U');

  String _decode(List<int> bytes) => utf8.decode(bytes, allowMalformed: true);

  static bool _isHttp(String? value) =>
      value != null &&
      RegExp(r'^https?://', caseSensitive: false).hasMatch(value);

  static String _healthKey(Episode episode) {
    final uri = Uri.tryParse(episode.url);
    if (uri != null && uri.hasScheme && uri.host.isNotEmpty) return uri.origin;
    return '${episode.sourceId ?? ''}:${episode.url}';
  }

  static bool _hasNonStandardPort(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    return scheme == 'https' && uri.port > 0 && uri.port != 443;
  }
}

class _RouteCandidate {
  final int index;
  final PlayLine line;
  final Episode? episode;

  const _RouteCandidate({
    required this.index,
    required this.line,
    required this.episode,
  });
}

class _RouteResult {
  final int index;
  final bool success;
  final bool timedOut;
  final int latencyMs;
  final int resolutionHeight;
  final int bandwidth;
  final double throughputBps;
  final bool usedProxy;
  final bool nonStandardPort;

  const _RouteResult({
    required this.index,
    required this.success,
    required this.latencyMs,
    this.resolutionHeight = 0,
    this.bandwidth = 0,
    this.throughputBps = 0,
    this.usedProxy = false,
    this.nonStandardPort = false,
  }) : timedOut = false;

  const _RouteResult.failed(this.index)
    : success = false,
      timedOut = false,
      latencyMs = 4000,
      resolutionHeight = 0,
      bandwidth = 0,
      throughputBps = 0,
      usedProxy = false,
      nonStandardPort = false;

  const _RouteResult.timedOut(this.index)
    : success = false,
      timedOut = true,
      latencyMs = 7500,
      resolutionHeight = 0,
      bandwidth = 0,
      throughputBps = 0,
      usedProxy = false,
      nonStandardPort = false;
}

class _HlsVariant {
  final Uri url;
  final int height;
  final int bandwidth;

  const _HlsVariant({
    required this.url,
    required this.height,
    required this.bandwidth,
  });
}

class _RouteHealth {
  double successRate = .8;
  double? latencyMs;
  int consecutiveFailures = 0;
}
