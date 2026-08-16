package com.videoget.videoget_mobile

import android.content.Context
import android.media.AudioManager
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.videoget/system_playback",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getBrightness" -> {
                    val windowValue = window.attributes.screenBrightness
                    val value = if (windowValue >= 0f) {
                        windowValue
                    } else {
                        Settings.System.getInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS, 128) / 255f
                    }
                    result.success(value.coerceIn(0f, 1f).toDouble())
                }
                "setBrightness" -> {
                    val value = (call.arguments as? Number)?.toFloat()?.coerceIn(0f, 1f) ?: 0.5f
                    runOnUiThread {
                        window.attributes = window.attributes.apply { screenBrightness = value }
                        result.success(null)
                    }
                }
                "getVolume" -> {
                    val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    val maximum = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
                    result.success(audio.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / maximum)
                }
                "setVolume" -> {
                    val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    val maximum = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
                    val value = (call.arguments as? Number)?.toDouble()?.coerceIn(0.0, 1.0) ?: 0.5
                    audio.setStreamVolume(AudioManager.STREAM_MUSIC, (value * maximum).roundToInt(), 0)
                    result.success(null)
                }
                "getNetworkProxy" -> {
                    @Suppress("DEPRECATION")
                    val host = android.net.Proxy.getHost(this).orEmpty()
                    @Suppress("DEPRECATION")
                    val port = android.net.Proxy.getPort(this)
                    result.success(if (host.isNotEmpty() && port > 0) mapOf("host" to host, "port" to port) else null)
                }
                "getPlaybackCacheDirectory" -> {
                    val directory = java.io.File(filesDir, "video-cache")
                    directory.mkdirs()
                    result.success(directory.absolutePath)
                }
                else -> result.notImplemented()
            }
        }
    }
}
