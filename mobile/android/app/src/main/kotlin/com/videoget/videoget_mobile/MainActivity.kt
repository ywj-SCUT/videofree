package com.videoget.videoget_mobile

import android.content.Context
import android.media.AudioManager
import android.os.Build
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
                    val proxy = readSystemProxy()
                    result.success(proxy)
                }
                "getPlaybackCacheDirectory" -> {
                    val directory = java.io.File(filesDir, "video-cache")
                    directory.mkdirs()
                    result.success(directory.absolutePath)
                }
                "isEmulator" -> result.success(isEmulator())
                else -> result.notImplemented()
            }
        }
    }

    private fun isEmulator(): Boolean {
        return Build.FINGERPRINT.startsWith("generic") ||
            Build.FINGERPRINT.contains("emulator") ||
            Build.FINGERPRINT.contains("sdk_gphone") ||
            Build.MODEL.contains("Emulator") ||
            Build.MODEL.contains("Android SDK built for") ||
            Build.MANUFACTURER.contains("Genymotion") ||
            Build.PRODUCT.contains("sdk") ||
            Build.HARDWARE.contains("goldfish") ||
            Build.HARDWARE.contains("ranchu")
    }

    private fun readSystemProxy(): Map<String, Any>? {
        // Android 15 exposes the emulator proxy through the global setting;
        // the deprecated Proxy API may return an empty value there.
        val configured = Settings.Global.getString(contentResolver, Settings.Global.HTTP_PROXY)
            ?.trim()
            .orEmpty()
        parseProxy(configured)?.let { return it }

        @Suppress("DEPRECATION")
        val host = android.net.Proxy.getHost(this).orEmpty()
        @Suppress("DEPRECATION")
        val port = android.net.Proxy.getPort(this)
        if (host.isNotEmpty() && port > 0) {
            return mapOf("host" to host, "port" to port)
        }
        // Do not synthesize a host proxy on the AVD.  The desktop proxy often
        // listens on 127.0.0.1 only, which is not reachable as 10.0.2.2 from
        // an emulator and would make HLS routes incorrectly proxy-first.  A
        // configured Android proxy is still returned above and Dart retains
        // its explicit direct-first/fallback behavior.
        return null
    }

    private fun parseProxy(value: String): Map<String, Any>? {
        if (value.isBlank() || value.equals(" none", ignoreCase = true) || value.equals("none", ignoreCase = true)) {
            return null
        }
        val normalized = value.removePrefix("http://").removePrefix("https://").trim()
        val separator = normalized.lastIndexOf(':')
        if (separator <= 0 || separator >= normalized.lastIndex) return null
        val host = normalized.substring(0, separator).trim().removePrefix("[").removeSuffix("]")
        val port = normalized.substring(separator + 1).trim().toIntOrNull() ?: return null
        return if (host.isNotEmpty() && port in 1..65535) {
            mapOf("host" to host, "port" to port)
        } else {
            null
        }
    }
}
