package com.mobi.passenger

import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.floor

/** Offline-convolved SADIE II horizontal warning, 48 kHz PCM16 stereo.
 * Positive azimuth is right. Front/rear cues come from measured HRIRs.
 */
class SpatialWarningBank(input: InputStream) {
    val rate: Int
    val directionCount: Int
    val frames: Int
    val step: Int
    private val pcm: ShortArray

    init {
        val data = input.use { it.readBytes() }
        require(data.size >= 24 && String(data, 0, 8, Charsets.US_ASCII) == "MOBIHR01")
        val bytes = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN)
        bytes.position(8)
        rate = bytes.int
        directionCount = bytes.int
        frames = bytes.int
        step = bytes.int
        require(rate == 48000 && step == 5 && directionCount == 72 && frames in 11000..13000)
        require(data.size == 24 + directionCount * frames * 4)
        pcm = ShortArray(directionCount * frames * 2)
        bytes.asShortBuffer().get(pcm)
    }

    fun sample(frame: Int, channel: Int, rightAngle: Double): Double {
        require(channel in 0..1 && rightAngle.isFinite())
        if (frame !in 0 until frames) return 0.0
        val position = ((rightAngle % 360 + 360) % 360) / step
        val first = floor(position).toInt() % directionCount
        val next = (first + 1) % directionCount
        val fraction = position - floor(position)
        val a = pcm[(first * frames + frame) * 2 + channel].toDouble()
        val b = pcm[(next * frames + frame) * 2 + channel].toDouble()
        return a + (b - a) * fraction
    }
}

/** Smooth circular head motion over ~20 ms, including the -180/+180 seam. */
class SpatialWarningRenderer(private val bank: SpatialWarningBank, initialAngle: Double) {
    var angle = initialAngle
        private set

    fun render(frame: Int, targetAngle: Double, pcm: ShortArray, offset: Int) {
        val difference = ((targetAngle - angle + 540) % 360 + 360) % 360 - 180
        angle = ((angle + difference / 960 + 540) % 360 + 360) % 360 - 180
        pcm[offset] = bank.sample(frame, 0, angle).toInt().coerceIn(-32768, 32767).toShort()
        pcm[offset + 1] = bank.sample(frame, 1, angle).toInt().coerceIn(-32768, 32767).toShort()
    }
}
