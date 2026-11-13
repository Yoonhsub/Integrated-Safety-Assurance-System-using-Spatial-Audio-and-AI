package com.example.mobi_passenger_app

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import kotlin.math.atan
import kotlin.math.min

/** Nominal FOV of the selected rear camera at default zoom, center-crop model. */
object CameraGeometry {
    fun read(context: Context, id: String, width: Int, height: Int, rotation: Int): Map<String, Any> {
        require(width in 1..4096 && height in 1..4096 && rotation in setOf(0,90,180,270))
        val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val c = manager.getCameraCharacteristics(id)
        require(c.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK)
        val size = c.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE) ?: error("카메라 크기 정보 없음")
        val lengths = c.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS) ?: error("렌즈 정보 없음")
        require(lengths.size == 1 && lengths[0].isFinite() && lengths[0] > 0) { "사용 렌즈 화각을 확정할 수 없습니다." }
        require(size.width > 0 && size.height > 0)
        val aspect = width.toDouble() / height
        val cropWidth = min(size.width.toDouble(),size.height * aspect)
        val cropHeight = min(size.height.toDouble(),size.width / aspect)
        val extent = if(rotation == 90 || rotation == 270) cropHeight else cropWidth
        val fov = Math.toDegrees(2 * atan(extent / (2 * lengths[0])))
        require(fov.isFinite() && fov in 20.0..130.0)
        return mapOf("horizontalFovDegrees" to fov, "source" to "camera2-nominal-default-zoom-center-crop", "cameraId" to id)
    }
}
