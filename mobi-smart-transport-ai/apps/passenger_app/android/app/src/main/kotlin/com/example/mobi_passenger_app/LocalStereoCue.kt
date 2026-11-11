package com.example.mobi_passenger_app

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioDeviceCallback
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

/** Shared existing Stereo Cue engine; no automatic playback. */
internal class LocalStereoCue(private val context: Context, private val channel: MethodChannel) {
    private val handler = Handler(Looper.getMainLooper())
    private val manager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val attributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build()
    private val prepared = mutableSetOf<String>()
    private val headphoneOnly = mutableSetOf<String>()
    private val retired = mutableSetOf<String>()
    private var current: Run? = null
    private var closed = false
    // Unconfirmed native release must also block a newly-created Activity.
    // Only a process restart (which retires its AudioTracks) clears this latch.
    companion object { private var poisoned = false }
    private var lastRoute: Map<String, Any>? = null
    private class Run(val owner: String, val id: Int, val track: AudioTrack) {
        var focus: AudioFocusRequest? = null
        var watchdog: Runnable? = null
    }
    private fun isHeadphone(device: AudioDeviceInfo) = device.isSink && device.type in setOf(
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_BLE_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_USB_HEADSET)
    private fun headphonesAvailable() = manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any(::isHeadphone)
    private fun headphoneEvent(available: Boolean) {
        if (closed) return
        if (!available) current?.takeIf { it.owner in headphoneOnly }?.let { finish(it, false, "HEADPHONE_LOST") }
        record("HEADPHONE_STATE", mapOf("available" to available))
        channel.invokeMethod("headphonesChanged", mapOf("available" to available))
    }
    private val deviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesRemoved(devices: Array<out AudioDeviceInfo>) {
            // Losing any headphone endpoint disarms this local rehearsal even if
            // another endpoint remains. Reconnection is never an auto-start.
            if (devices.any(::isHeadphone)) headphoneEvent(false)
        }
        override fun onAudioDevicesAdded(devices: Array<out AudioDeviceInfo>) {
            headphoneEvent(headphonesAvailable())
        }
    }
    init {
        channel.setMethodCallHandler(::call)
        manager.registerAudioDeviceCallback(deviceCallback, handler)
    }
    private fun record(phase: String, extra: Map<String, Any?> = emptyMap()) {
        Log.i("MobiLocalAudio", JSONObject(mapOf("phase" to phase, "activeTracks" to (if (current == null) 0 else 1)) + extra).toString())
    }
    private fun route(device: AudioDeviceInfo): Map<String, Any> = mapOf("id" to device.id, "type" to device.type)
    private fun snapshot(): Map<String, Any?> = mapOf(
        "active" to (current != null), "activeTracks" to (if (current == null) 0 else 1),
        "sampleRate" to 48000, "channels" to 2, "cueDurationMs" to 600, "pcmPeak" to 0.10,
        "availableOutputs" to manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).filter { it.isSink }.map(::route),
        "cueRoutedDevice" to lastRoute, "ttsRoute" to "NOT_VERIFIED",
        "headphonesAvailable" to headphonesAvailable(),
        "musicVolume" to manager.getStreamVolume(AudioManager.STREAM_MUSIC),
        "ttsEngines" to context.packageManager.queryIntentServices(Intent("android.intent.action.TTS_SERVICE"), 0).map { it.serviceInfo.packageName },
        "bluetoothDeviceModel" to "NOT_VERIFIED", "hrtf" to false)
    private fun owner(call: MethodCall): String {
        val value = call.argument<String>("owner") ?: error("Owner required")
        require(value.length in 1..100 && value.all { it.isLetterOrDigit() || it == '-' })
        return value
    }
    private fun call(call: MethodCall, result: MethodChannel.Result) {
        try {
            check(!closed) { "Activity closed" }
            val owner = owner(call)
            when (call.method) {
                "headphones" -> result.success(mapOf("available" to headphonesAvailable()))
                "prepare" -> {
                    if (call.argument<Boolean>("headphonesOnly") == true) {
                        check(headphonesAvailable()) { "Headphones required" }
                        headphoneOnly.add(owner)
                    }
                    check(!poisoned && owner !in retired && retired.size < 128)
                    check(current == null || current?.owner == owner)
                    prepared.add(owner)
                    record("PREPARE")
                    result.success(snapshot())
                }
                "play" -> {
                    if (owner in headphoneOnly) check(headphonesAvailable()) { "Headphones required" }
                    check(!poisoned && owner in prepared && owner !in retired && current == null)
                    val id = call.argument<Int>("id") ?: error("Run id required")
                    val direction = call.argument<String>("direction") ?: error("Direction required")
                    require(direction in setOf("LEFT", "CENTER", "RIGHT"))
                    play(owner, id, direction)
                    result.success(snapshot())
                }
                "stop", "dispose" -> {
                    if (call.method == "dispose") { prepared.remove(owner); headphoneOnly.remove(owner); retired.add(owner) }
                    val run = current
                    // A stale page is never allowed to stop a new owner's track.
                    if (run != null && run.owner == owner) finish(run, false, "USER_STOP")
                    check(!poisoned) { "Audio release unconfirmed" }
                    record(if (call.method == "stop") "STOP_CONFIRMED" else "DISPOSE_CONFIRMED")
                    result.success(snapshot() + mapOf("confirmed" to true))
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            record("METHOD_FAILED", mapOf("method" to call.method, "type" to error.javaClass.simpleName))
            result.error("NATIVE_AUDIO_BLOCKED", error.javaClass.simpleName, null)
        }
    }
    private fun pcm(direction: String): ShortArray {
        val frames = 28800
        val pcm = ShortArray(frames * 2)
        val left = if (direction == "RIGHT") 0.0 else if (direction == "CENTER") 0.70710678 else 1.0
        val right = if (direction == "LEFT") 0.0 else if (direction == "CENTER") 0.70710678 else 1.0
        for (i in 0 until frames) {
            val fade = min(1.0, min(i / 480.0, (frames - 1 - i) / 480.0))
            val sample = 32767.0 * 0.10 * fade * sin(2.0 * PI * 440.0 * i / 48000.0)
            pcm[2 * i] = (sample * left).toInt().toShort()
            pcm[2 * i + 1] = (sample * right).toInt().toShort()
        }
        return pcm
    }
    private fun play(owner: String, id: Int, direction: String) {
        val data = pcm(direction)
        val track = AudioTrack.Builder().setAudioAttributes(attributes)
            .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(48000).setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).build())
            .setTransferMode(AudioTrack.MODE_STATIC).setBufferSizeInBytes(data.size * 2).build()
        val run = Run(owner, id, track)
        current = run
        try {
            record("STATIC_BEFORE_WRITE", mapOf("state" to track.state))
            check(track.state == AudioTrack.STATE_NO_STATIC_DATA || track.state == AudioTrack.STATE_INITIALIZED)
            check(track.write(data, 0, data.size) == data.size)
            check(track.state == AudioTrack.STATE_INITIALIZED)
            record("STATIC_PCM_READY", mapOf("state" to track.state, "samples" to data.size))
            run.focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(attributes).setAcceptsDelayedFocusGain(false)
                .setOnAudioFocusChangeListener({ focus ->
                    if (focus < 0 && current === run) finish(run, false, "FOCUS_LOSS")
                }, handler).build()
            check(manager.requestAudioFocus(run.focus!!) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED)
            track.setPlaybackPositionUpdateListener(object : AudioTrack.OnPlaybackPositionUpdateListener {
                override fun onMarkerReached(value: AudioTrack) {
                    if (current === run) finish(run, true, "MARKER_COMPLETED")
                }
                override fun onPeriodicNotification(value: AudioTrack) {}
            }, handler)
            check(track.setNotificationMarkerPosition(28800) == AudioTrack.SUCCESS)
            track.play()
            check(track.playState == AudioTrack.PLAYSTATE_PLAYING)
            lastRoute = track.routedDevice?.let(::route)
            val watchdog = Runnable { if (current === run) finish(run, false, "CUE_CALLBACK_TIMEOUT", true) }
            run.watchdog = watchdog; handler.postDelayed(watchdog, 3600)
            record("CUE_STARTED", mapOf("id" to id, "direction" to direction))
        } catch (error: Exception) {
            finish(run, false, "START_FAILED", true, false)
            throw error
        }
    }
    private fun finish(run: Run, completed: Boolean, reason: String, failure: Boolean = false, notify: Boolean = true) {
        if (current !== run) return
        run.watchdog?.let { handler.removeCallbacks(it) }
        try { lastRoute = run.track.routedDevice?.let(::route) ?: lastRoute }
        catch (error: Exception) { record("ROUTE_UNAVAILABLE", mapOf("type" to error.javaClass.simpleName)) }
        val errors = mutableListOf<String>()
        fun attempt(action: () -> Unit) { try { action() } catch (e: Exception) { errors.add(e.javaClass.simpleName) } }
        attempt { run.track.setPlaybackPositionUpdateListener(null) }
        attempt { if (run.track.playState != AudioTrack.PLAYSTATE_STOPPED) run.track.stop() }
        attempt { check(run.track.playState == AudioTrack.PLAYSTATE_STOPPED) }
        attempt { run.track.release() }
        run.focus?.let { focus -> attempt { manager.abandonAudioFocusRequest(focus) } }
        current = null
        if (errors.isNotEmpty() || failure) poisoned = true
        val failed = errors.isNotEmpty() || failure
        record(if (failed) "CUE_FAILED" else if (completed) "CUE_COMPLETED" else "CUE_CANCELLED",
            mapOf("id" to run.id, "reason" to reason, "cleanupErrors" to errors))
        if (notify && !closed) try { channel.invokeMethod("cueFinished", mapOf(
            "owner" to run.owner, "id" to run.id, "completed" to (completed && !failed),
            "error" to failed, "reason" to reason)) }
        catch (error: Exception) { record("CALLBACK_DELIVERY_FAILED", mapOf("type" to error.javaClass.simpleName)) }
    }
    fun suspendOutput() {
        current?.let { finish(it, false, "ACTIVITY_PAUSE") }
        record("ACTIVITY_PAUSE")
    }
    fun close() {
        if (closed) return
        current?.let { finish(it, false, "ACTIVITY_DESTROY") }
        closed = true
        manager.unregisterAudioDeviceCallback(deviceCallback)
        prepared.clear()
        headphoneOnly.clear()
        channel.setMethodCallHandler(null)
        record("ACTIVITY_CLOSED")
    }
}
