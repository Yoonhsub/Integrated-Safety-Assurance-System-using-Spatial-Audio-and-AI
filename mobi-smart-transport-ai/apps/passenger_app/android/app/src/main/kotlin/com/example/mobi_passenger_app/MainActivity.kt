package com.example.mobi_passenger_app

import com.mobi.passenger.HardwareBusActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : HardwareBusActivity() {
    private var audio: LocalStereoCue? = null
    private var phoneHeading: PhoneCameraHeading? = null
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        phoneHeading = PhoneCameraHeading(this)
        EventChannel(engine.dartExecutor.binaryMessenger, "mobi/phone_camera_heading").setStreamHandler(phoneHeading)
        audio = LocalStereoCue(this, MethodChannel(engine.dartExecutor.binaryMessenger, "mobi/local_android_audio"))
    }
    override fun onPause() {
        phoneHeading?.close()
        audio?.suspendOutput()
        super.onPause()
    }
    override fun onDestroy() {
        phoneHeading?.close()
        phoneHeading = null
        audio?.close()
        audio = null
        super.onDestroy()
    }
}
