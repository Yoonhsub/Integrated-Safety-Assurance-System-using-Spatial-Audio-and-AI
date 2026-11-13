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
        MethodChannel(engine.dartExecutor.binaryMessenger, "mobi/camera_geometry").setMethodCallHandler { call, result ->
            if (call.method != "read") result.notImplemented()
            else try {
                result.success(CameraGeometry.read(this,
                    call.argument<String>("cameraId") ?: error("카메라 ID 없음"),
                    call.argument<Number>("width")?.toInt() ?: 0,
                    call.argument<Number>("height")?.toInt() ?: 0,
                    call.argument<Number>("rotation")?.toInt() ?: -1))
            } catch (e: Exception) { result.error("CAMERA_GEOMETRY_UNAVAILABLE", "카메라 방향 환산 정보를 확인할 수 없습니다.", null) }
        }
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
