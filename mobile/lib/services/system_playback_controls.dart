import 'package:flutter/services.dart';

class SystemPlaybackControls {
  static const _channel = MethodChannel('com.videoget/system_playback');

  static Future<double> brightness() async {
    try {
      return ((await _channel.invokeMethod<num>('getBrightness')) ?? 0.5)
          .toDouble()
          .clamp(0, 1);
    } catch (_) {
      return 0.5;
    }
  }

  static Future<void> setBrightness(double value) async {
    try {
      await _channel.invokeMethod<void>('setBrightness', value.clamp(0, 1));
    } catch (_) {}
  }

  static Future<double> volume() async {
    try {
      return ((await _channel.invokeMethod<num>('getVolume')) ?? 0.5)
          .toDouble()
          .clamp(0, 1);
    } catch (_) {
      return 0.5;
    }
  }

  static Future<void> setVolume(double value) async {
    try {
      await _channel.invokeMethod<void>('setVolume', value.clamp(0, 1));
    } catch (_) {}
  }

  static Future<({String host, int port})?> networkProxy() async {
    try {
      final value = await _channel.invokeMapMethod<String, Object?>(
        'getNetworkProxy',
      );
      final host = value?['host']?.toString() ?? '';
      final port = int.tryParse(value?['port']?.toString() ?? '') ?? 0;
      return host.isNotEmpty && port > 0 ? (host: host, port: port) : null;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> playbackCacheDirectory() async {
    try {
      return await _channel.invokeMethod<String>('getPlaybackCacheDirectory');
    } catch (_) {
      return null;
    }
  }
}
