package com.mobi.passenger

import android.Manifest
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.location.LocationManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.math.atan

open class HardwareBusActivity : FlutterActivity() {
    private var tone: ToneTestEngine? = null
    private var pending: MethodChannel.Result? = null
    private fun permissions(): Array<String> = if (Build.VERSION.SDK_INT >= 31) arrayOf(
        Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT,
        Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION
    ) else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
    private fun granted() = permissions().all { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
    private fun locationEnabled(): Boolean {
        val location = getSystemService(LOCATION_SERVICE) as LocationManager
        return if (Build.VERSION.SDK_INT >= 28) location.isLocationEnabled
        else location.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
            location.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
    }
    private fun state() = mapOf(
        "granted" to granted(),
        "locationEnabled" to locationEnabled()
    )
    private fun queryCameraHorizontalFov(cameraName: String?, lensDirection: String?): Map<String, Any?> {
        return try {
            val manager = getSystemService(CAMERA_SERVICE) as CameraManager
            val cameraIds = manager.cameraIdList
            if (cameraIds.isEmpty()) {
                return mapOf("horizontalFovDegrees" to null, "reason" to "No cameras available")
            }
            val targetFacing = if (lensDirection == "front") {
                CameraCharacteristics.LENS_FACING_FRONT
            } else {
                CameraCharacteristics.LENS_FACING_BACK
            }
            val cameraId = cameraName?.takeIf { it.isNotBlank() && cameraIds.contains(it) }
                ?: cameraIds.firstOrNull { id ->
                    manager.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING) == targetFacing
                }
                ?: cameraIds.firstOrNull()
                ?: return mapOf("horizontalFovDegrees" to null, "reason" to "Camera ID unavailable")
            val characteristics = manager.getCameraCharacteristics(cameraId)
            val physicalSize = characteristics.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
                ?: return mapOf("horizontalFovDegrees" to null, "reason" to "Physical sensor size unavailable")
            val focalLengths = characteristics.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
                ?: return mapOf("horizontalFovDegrees" to null, "reason" to "Focal lengths unavailable")
            val focalLength = focalLengths.firstOrNull { it > 0f }
                ?: return mapOf("horizontalFovDegrees" to null, "reason" to "Valid focal length unavailable")
            if (physicalSize.width <= 0f) {
                return mapOf("horizontalFovDegrees" to null, "reason" to "Invalid sensor width")
            }
            val fovDegrees = Math.toDegrees(2.0 * atan((physicalSize.width / (2.0 * focalLength)).toDouble()))
            if (!fovDegrees.isFinite() || fovDegrees <= 1.0 || fovDegrees >= 179.0) {
                return mapOf("horizontalFovDegrees" to null, "reason" to "Calculated FOV out of bounds")
            }
            mapOf(
                "horizontalFovDegrees" to fovDegrees,
                "cameraId" to cameraId,
                "sensorWidthMm" to physicalSize.width.toDouble(),
                "sensorHeightMm" to physicalSize.height.toDouble(),
                "focalLengthMm" to focalLength.toDouble()
            )
        } catch (e: Exception) {
            mapOf("horizontalFovDegrees" to null, "reason" to (e.message ?: e::class.java.simpleName))
        }
    }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        tone = ToneTestEngine(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mobi.passenger/hardware-tone").setMethodCallHandler { call, result ->
            try {
                val engine = tone ?: throw IllegalStateException("오디오 준비 중")
                when (call.method) {
                    "start", "update" -> {
                        val left = call.argument<Number>("left")?.toDouble() ?: 0.0
                        val right = call.argument<Number>("right")?.toDouble() ?: 0.0
                        val age = call.argument<Number>("sensorAgeMs")?.toInt() ?: 9999
                        val interval = call.argument<Number>("intervalMs")?.toInt() ?: 1000
                        val beaconAge = call.argument<Number>("beaconAgeMs")?.toInt() ?: -1
                        val pattern = call.argument<String>("pattern") ?: "target"
                        val azimuth = call.argument<Number>("azimuthDegrees")?.toDouble()
                        result.success(if (call.method == "start") engine.start(left, right, age, interval, beaconAge, pattern, azimuth) else engine.update(left, right, age, interval, beaconAge, pattern, azimuth))
                    }
                    "stop" -> {
                        engine.stop()
                        result.success(mapOf("confirmed" to true, "running" to false, "reason" to "중지 확인"))
                    }
                    "status" -> result.success(engine.state())
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                tone?.stop("테스트음 오류로 중지")
                result.error("TONE_ERROR", e.message, null)
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mobi.passenger/hardware-permissions").setMethodCallHandler { call, result ->
            when (call.method) {
                "check" -> result.success(state())
                "request" -> {
                    if (pending != null) result.error("BUSY", "Permission request in progress", null)
                    else if (granted()) result.success(state())
                    else {
                        pending = result
                        requestPermissions(permissions().filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }.toTypedArray(), 7001)
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mobi.passenger/camera-hardware").setMethodCallHandler { call, result ->
            when (call.method) {
                "getCameraFov" -> {
                    val cameraName = call.argument<String>("cameraName")
                    val lensDirection = call.argument<String>("lensDirection")
                    result.success(queryCameraHorizontalFov(cameraName, lensDirection))
                }
                else -> result.notImplemented()
            }
        }
    }
    override fun onPause() {
        tone?.stop("화면을 벗어나 테스트음을 중지했습니다.")
        super.onPause()
    }
    override fun onDestroy() {
        tone?.stop("앱 종료")
        super.onDestroy()
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 7001) {
            pending?.success(state())
            pending = null
        }
    }
}
