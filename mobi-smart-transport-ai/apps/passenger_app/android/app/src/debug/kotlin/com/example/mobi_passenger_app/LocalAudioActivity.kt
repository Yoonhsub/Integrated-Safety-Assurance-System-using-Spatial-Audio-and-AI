package com.example.mobi_passenger_app

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import kotlin.math.PI
import kotlin.math.min
import kotlin.math.sin

/** Debug-source Activity, exported only in the explicit networkless audio overlay. */
class LocalAudioActivity : FlutterActivity() {
    private var audio: LocalStereoCue? = null
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        check(packageName in setOf(
            "com.example.mobi_passenger_app.localaudio",
            "com.example.mobi_passenger_app.handoff.localaudio") &&
            (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0)
        audio = LocalStereoCue(this, MethodChannel(engine.dartExecutor.binaryMessenger, "mobi/local_android_audio"))
    }
    override fun onPause() {
        audio?.suspendOutput()
        super.onPause()
    }
    override fun onDestroy() {
        audio?.close()
        audio = null
        super.onDestroy()
    }
}
