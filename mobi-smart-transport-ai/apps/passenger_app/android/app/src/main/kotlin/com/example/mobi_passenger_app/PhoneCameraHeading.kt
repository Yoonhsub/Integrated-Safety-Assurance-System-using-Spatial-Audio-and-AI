package com.example.mobi_passenger_app

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.SystemClock
import io.flutter.plugin.common.EventChannel
import kotlin.math.atan2
import kotlin.math.hypot

/** Rear camera optical axis (-device Z), projected onto the horizontal world plane. */
class PhoneCameraHeading(context: Context) : EventChannel.StreamHandler, SensorEventListener {
    private val manager = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private var sink: EventChannel.EventSink? = null
    private var accuracy = SensorManager.SENSOR_STATUS_UNRELIABLE
    private var lastSent = 0L
    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        val sensor = manager.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
        if (sensor == null || !manager.registerListener(this, sensor, 20000)) {
            events.error("NO_PHONE_HEADING", "휴대폰 회전 센서를 사용할 수 없습니다.", null)
        }
    }
    override fun onCancel(arguments: Any?) { close() }
    fun close() { manager.unregisterListener(this); sink = null; accuracy = 0 }
    override fun onAccuracyChanged(sensor: Sensor?, value: Int) { accuracy = value }
    override fun onSensorChanged(event: SensorEvent) {
        val now = SystemClock.elapsedRealtime()
        if (now - lastSent < 40) return
        lastSent = now
        val matrix = FloatArray(9)
        SensorManager.getRotationMatrixFromVector(matrix, event.values)
        val east = -matrix[2].toDouble()
        val north = -matrix[5].toDouble()
        val eventAgeMs = (SystemClock.elapsedRealtimeNanos() - event.timestamp) / 1000000
        sink?.success(mapOf("heading" to Math.toDegrees(atan2(east, north)),
            "usable" to (accuracy > SensorManager.SENSOR_STATUS_UNRELIABLE && hypot(east, north) > 0.25 && eventAgeMs in 0L..250L),
            "receivedAtMs" to System.currentTimeMillis(), "accuracy" to accuracy))
    }
}
