package com.mobi.passenger

import java.io.ByteArrayInputStream
import java.io.File
import org.junit.Assert.*
import org.junit.Test
import kotlin.math.abs

class SpatialWarningBankTest {
    private fun bank() = SpatialWarningBank(File("src/main/assets/hrtf/warning_bank.bin").inputStream())

    @Test fun medianFrontAndRearHaveEqualEarsButDifferentWaveforms() {
        val bank = bank()
        var difference = 0.0
        for (frame in 0 until bank.frames) {
            assertEquals(bank.sample(frame, 0, 0.0), bank.sample(frame, 1, 0.0), 0.0)
            assertEquals(bank.sample(frame, 0, 180.0), bank.sample(frame, 1, 180.0), 0.0)
            difference += abs(bank.sample(frame, 0, 0.0) - bank.sample(frame, 0, 180.0))
        }
        assertTrue(difference > 1000)
    }

    @Test fun measuredSideEnergyAndDelayReachTheCorrectEars() {
        val bank = bank()
        fun energy(channel: Int, angle: Double) = (0 until bank.frames).sumOf {
            val s = bank.sample(it, channel, angle); s * s
        }
        assertTrue(energy(1, 90.0) > energy(0, 90.0))
        assertTrue(energy(0, -90.0) > energy(1, -90.0))
        fun peak(channel: Int, angle: Double) = (0 until 5000).maxBy {
            abs(bank.sample(it, channel, angle))
        }
        assertTrue(peak(1, 90.0) < peak(0, 90.0))
        assertTrue(peak(0, -90.0) < peak(1, -90.0))
    }

    @Test fun bankIsBoundedAndWrapsAtRearWithoutFrontJump() {
        val bank = bank()
        for (frame in 0 until bank.frames) {
            assertEquals(bank.sample(frame, 0, 180.0), bank.sample(frame, 0, -180.0), 0.0)
            for (angle in -180..180 step 5) {
                assertTrue(abs(bank.sample(frame, 0, angle.toDouble())) <= 7865)
                assertTrue(abs(bank.sample(frame, 1, angle.toDouble())) <= 7865)
            }
        }
        val renderer = SpatialWarningRenderer(bank, 179.0)
        val pcm = ShortArray(2)
        renderer.render(100, -179.0, pcm, 0)
        assertTrue(renderer.angle > 179.0) // shortest arc through rear, not via front
        assertEquals(0.0, bank.sample(bank.frames, 0, 0.0), 0.0)
    }

    @Test(expected = IllegalArgumentException::class)
    fun truncatedBankIsRejected() {
        SpatialWarningBank(ByteArrayInputStream(byteArrayOf(1, 2)))
    }
}
