package com.mobi.passenger

import android.content.Context
import android.media.*
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.PI
import kotlin.math.sin

/** Stereo diagnostic tone. No HRTF rendering, system-volume changes or background playback. */
class ToneTestEngine(context: Context) {
    private val manager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val handler = Handler(Looper.getMainLooper())
    private val workerGeneration = AtomicInteger(0)
    private var track: AudioTrack? = null
    private var focus: AudioFocusRequest? = null
    private var startedAt = 0L
    private var updatedAt = 0L
    private var sensorAt = 0L
    private var beaconAt = 0L
    @Volatile private var intervalMs = 1000
    @Volatile private var pattern = "target"
    private var left = 0.0f
    private var right = 0.0f
    private var reason = "대기 중"
    private val attributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build()
    private val routeListener = AudioRouting.OnRoutingChangedListener { applyRoute() }
    private val watchdog = object : Runnable {
        override fun run() {
            if (track == null) return
            val now = SystemClock.elapsedRealtime()
            when {
                now - startedAt >= 300000 -> stop("5분 안내 종료")
                now - updatedAt > 1200 || now - sensorAt > 1200 -> stop("센서 수신 지연으로 중지")
                beaconAt != 0L && now - beaconAt >= 3000 -> stop("기준 비콘 수신이 끊겨 중지")
                else -> applyRoute()
            }
            if (track != null) handler.postDelayed(this, 100)
        }
    }

    private fun isHeadphone(device: AudioDeviceInfo) = device.type in setOf(
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_BLE_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_USB_HEADSET
    )

    private fun validate(l: Double, r: Double, age: Int, interval: Int, beaconAge: Int, patternName: String) {
        require(patternName == "target" || patternName == "warning") { "잘못된 소리 패턴" }
        require(l.isFinite() && r.isFinite() && l in 0.0..1.0 && r in 0.0..1.0)
        require(age in 0..999) { "새 센서 각도를 수신한 뒤 시작해주세요." }
        require(interval in 220..1400) { "잘못된 테스트음 간격" }
        require(beaconAge == -1 || beaconAge in 0..2999) { "기준 비콘을 다시 스캔해주세요." }
    }

    fun start(l: Double, r: Double, age: Int, interval: Int, beaconAge: Int, patternName: String): Map<String, Any> {
        stop("새 테스트 준비")
        validate(l, r, age, interval, beaconAge, patternName)
        val outputs = manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).filter { isHeadphone(it) }
        val output = outputs.firstOrNull { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP || it.type == AudioDeviceInfo.TYPE_BLE_HEADSET }
            ?: outputs.firstOrNull()
            ?: throw IllegalStateException("골전도 이어폰을 블루투스로 연결한 뒤 시작해주세요.")
        val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            .setAudioAttributes(attributes)
            .setOnAudioFocusChangeListener({ change ->
                if (change != AudioManager.AUDIOFOCUS_GAIN) stop("오디오 사용권이 변경되어 중지")
            }, handler).build()
        if (manager.requestAudioFocus(request) != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
            throw IllegalStateException("다른 오디오 재생을 종료한 뒤 다시 시도해주세요.")
        }
        focus = request
        try {
            val rate = 48000
            val minBuffer = AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT)
            val audio = AudioTrack.Builder().setAudioAttributes(attributes)
                .setAudioFormat(AudioFormat.Builder().setSampleRate(rate)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).build())
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setBufferSizeInBytes(maxOf(minBuffer, 480 * 4 * 4)).build()
            track = audio
            check(audio.state == AudioTrack.STATE_INITIALIZED) { "오디오 장치 초기화 실패" }
            check(audio.setPreferredDevice(output)) { "이어폰 출력 경로 선택 실패" }
            audio.setStereoVolume(0f, 0f)
            left = l.toFloat()
            right = r.toFloat()
            intervalMs = interval
            pattern = patternName
            startedAt = SystemClock.elapsedRealtime()
            updatedAt = startedAt
            sensorAt = startedAt - age
            beaconAt = if (beaconAge < 0) 0L else startedAt - beaconAge
            reason = "이어폰 경로 확인 중"
            audio.addOnRoutingChangedListener(routeListener, handler)
            audio.play()
            startWorker(audio, rate)
            handler.post(watchdog)
            return state()
        } catch (e: Exception) {
            stop("테스트음 시작 실패")
            throw e
        }
    }

    private fun startWorker(audio: AudioTrack, rate: Int) {
        val generation = workerGeneration.incrementAndGet()
        Thread({
            Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
            val chunkFrames = 480
            val pcm = ShortArray(chunkFrames * 2)
            val targetPulseFrames = (rate * 0.12).toInt()
            val warningPulseFrames = (rate * 0.08).toInt()
            val warningSecondStart = (rate * 0.16).toInt()
            var frame = 0L
            var pulseStart = 0L
            try {
                while (workerGeneration.get() == generation) {
                    for (i in 0 until chunkFrames) {
                        if (frame - pulseStart >= intervalMs.toLong() * rate / 1000) pulseStart = frame
                        val phase = (frame - pulseStart).toInt()
                        val warning = pattern == "warning"
                        val pulseFrames = if (warning) warningPulseFrames else targetPulseFrames
                        val localPhase = if (warning && phase >= warningSecondStart) phase - warningSecondStart else phase
                        val sample = if (localPhase in 0 until pulseFrames) {
                            val envelope = minOf(1.0, localPhase / 480.0, (pulseFrames - 1 - localPhase) / 480.0)
                            val frequency = if (warning) 1100 else 700
                            (sin(2 * PI * frequency * localPhase / rate) * envelope * 0.12 * Short.MAX_VALUE).toInt().toShort()
                        } else 0.toShort()
                        pcm[i * 2] = sample
                        pcm[i * 2 + 1] = sample
                        frame++
                    }
                    var offset = 0
                    while (offset < pcm.size && workerGeneration.get() == generation) {
                        val written = audio.write(pcm, offset, pcm.size - offset, AudioTrack.WRITE_BLOCKING)
                        check(written > 0) { "오디오 스트림 출력 실패: $written" }
                        offset += written
                    }
                }
            } catch (e: Exception) {
                handler.post { if (workerGeneration.get() == generation) stop("오디오 스트림 오류로 중지") }
            }
        }, "MobiDiagnosticTone").apply { isDaemon = true; start() }
    }

    fun update(l: Double, r: Double, age: Int, interval: Int, beaconAge: Int, patternName: String): Map<String, Any> {
        if (track == null) return state()
        try {
            validate(l, r, age, interval, beaconAge, patternName)
            left = l.toFloat()
            right = r.toFloat()
            intervalMs = interval
            pattern = patternName
            updatedAt = SystemClock.elapsedRealtime()
            sensorAt = updatedAt - age
            beaconAt = if (beaconAge < 0) 0L else updatedAt - beaconAge
            applyRoute()
            return state()
        } catch (e: Exception) {
            stop("각도 또는 간격 갱신 실패")
            throw e
        }
    }

    private fun applyRoute() {
        val audio = track ?: return
        val route = audio.routedDevice
        if (route != null && isHeadphone(route)) {
            audio.setStereoVolume(left, right)
            reason = "방향/간격 테스트음 재생 중"
        } else {
            audio.setStereoVolume(0f, 0f)
            if (SystemClock.elapsedRealtime() - startedAt > 1500) stop("이어폰 출력이 연결되지 않아 중지")
        }
    }

    fun state(): Map<String, Any> = mapOf(
        "running" to (track != null), "reason" to reason, "pattern" to pattern,
        "route" to (track?.routedDevice?.productName?.toString() ?: "이어폰 확인 중")
    )

    fun stop(message: String = "사용자가 테스트음을 중지했습니다.") {
        handler.removeCallbacks(watchdog)
        workerGeneration.incrementAndGet()
        val audio = track
        track = null
        reason = message
        if (audio != null) {
            audio.removeOnRoutingChangedListener(routeListener)
            try { audio.pause(); audio.flush(); audio.stop() } catch (_: Exception) { }
            audio.release()
        }
        val request = focus
        focus = null
        if (request != null) manager.abandonAudioFocusRequest(request)
    }
}
