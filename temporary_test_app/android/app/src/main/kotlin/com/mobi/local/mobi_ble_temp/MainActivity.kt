package com.mobi.local.mobi_ble_temp

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.location.LocationManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var tone: ToneTestEngine? = null
    private var pending: MethodChannel.Result? = null
    private fun permissions(): Array<String> = if (Build.VERSION.SDK_INT >= 31) arrayOf(
        Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT,
        Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION
    ) else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
    private fun granted() = permissions().all { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
    private fun state() = mapOf(
        "granted" to granted(),
        "locationEnabled" to (getSystemService(LOCATION_SERVICE) as LocationManager).isLocationEnabled
    )
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        tone = ToneTestEngine(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mobi.temp/tone").setMethodCallHandler { call, result ->
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
                        result.success(if (call.method == "start") engine.start(left, right, age, interval, beaconAge, pattern) else engine.update(left, right, age, interval, beaconAge, pattern))
                    }
                    "stop" -> { engine.stop(); result.success(null) }
                    "status" -> result.success(engine.state())
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                tone?.stop("테스트음 오류로 중지")
                result.error("TONE_ERROR", e.message, null)
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mobi.temp/permissions").setMethodCallHandler { call, result ->
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
