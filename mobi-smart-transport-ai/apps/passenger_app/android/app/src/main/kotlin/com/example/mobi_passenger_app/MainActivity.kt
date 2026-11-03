package com.example.mobi_passenger_app

import com.mobi.passenger.HardwareBusActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : HardwareBusActivity() {
    private var audio: LocalStereoCue? = null
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
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
