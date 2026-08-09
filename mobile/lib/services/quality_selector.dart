import 'package:media_kit/media_kit.dart';

List<VideoTrack> selectableVideoTracks(List<VideoTrack> tracks) {
  final result = <VideoTrack>[VideoTrack.auto()];
  final seen = <String>{'auto'};
  for (final track in tracks) {
    if (track.id == 'auto' || track.id == 'no' || !seen.add(track.id)) {
      continue;
    }
    result.add(track);
  }
  return result;
}

VideoTrack choosePreferredVideoTrack(
  List<VideoTrack> tracks,
  String preference,
) {
  final available = selectableVideoTracks(tracks);
  final real = available.where((track) => track.id != 'auto').toList();
  if (preference == 'auto' || real.isEmpty) return VideoTrack.auto();

  int pixels(VideoTrack track) => (track.w ?? 0) * (track.h ?? 0);
  real.sort((left, right) => pixels(right).compareTo(pixels(left)));
  if (preference == 'highest') return real.first;

  final targetHeight = preference == '1080p'
      ? 1080
      : preference == '720p'
      ? 720
      : null;
  if (targetHeight == null) return VideoTrack.auto();
  final underTarget = real
      .where((track) => (track.h ?? 0) > 0 && track.h! <= targetHeight)
      .toList();
  if (underTarget.isNotEmpty) return underTarget.first;
  final withHeight = real.where((track) => (track.h ?? 0) > 0).toList()
    ..sort(
      (left, right) => (left.h! - targetHeight).abs().compareTo(
        (right.h! - targetHeight).abs(),
      ),
    );
  return withHeight.isNotEmpty ? withHeight.first : real.first;
}

String videoTrackLabel(VideoTrack track) {
  if (track.id == 'auto') return '自动';
  final resolution = track.h != null
      ? '${track.h}P${track.w != null ? ' (${track.w}x${track.h})' : ''}'
      : (track.title?.trim().isNotEmpty ?? false)
      ? track.title!.trim()
      : '轨道 ${track.id}';
  final bitrate = track.bitrate != null && track.bitrate! > 0
      ? ' · ${(track.bitrate! / 1000000).toStringAsFixed(1)} Mbps'
      : '';
  return '$resolution$bitrate';
}
