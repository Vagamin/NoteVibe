package com.notevibe.notevibe

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Android filters incoming multicast/broadcast UDP packets unless a
 * MulticastLock is held. The lock is needed for LAN discovery.
 */
class MainActivity : FlutterActivity() {
    private var lock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "notevibe/net")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquireMulticast" -> {
                        try {
                            if (lock == null) {
                                val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                                lock = wifi.createMulticastLock("notevibe-discovery").apply {
                                    setReferenceCounted(false)
                                }
                            }
                            lock?.acquire()
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("lock", e.message, null)
                        }
                    }
                    "releaseMulticast" -> {
                        lock?.takeIf { it.isHeld }?.release()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        lock?.takeIf { it.isHeld }?.release()
        super.onDestroy()
    }
}
