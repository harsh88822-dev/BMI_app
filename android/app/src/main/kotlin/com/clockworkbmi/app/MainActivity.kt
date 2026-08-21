package com.clockworkbmi.app

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.math.atan

class MainActivity : FlutterActivity() {
    private val channelName = "com.clockworkbmi.app/camera_fov"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getBackCameraVerticalFovDegrees" -> {
                        try {
                            result.success(readBackCameraVerticalFovDegrees())
                        } catch (e: Exception) {
                            result.error("FOV_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun readBackCameraVerticalFovDegrees(): Double {
        val cameraManager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
        for (cameraId in cameraManager.cameraIdList) {
            val characteristics = cameraManager.getCameraCharacteristics(cameraId)
            val facing = characteristics.get(CameraCharacteristics.LENS_FACING)
            if (facing != CameraCharacteristics.LENS_FACING_BACK) continue

            val focalLengths =
                characteristics.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
            val sensorSize =
                characteristics.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
            if (focalLengths == null || focalLengths.isEmpty() || sensorSize == null) {
                continue
            }

            // Shortest focal length ≈ widest field of view (default preview lens).
            val focalLengthMm = focalLengths.minOrNull() ?: focalLengths[0]
            val sensorHeightMm = sensorSize.height
            if (focalLengthMm <= 0f || sensorHeightMm <= 0f) continue

            val halfFovRad = atan((sensorHeightMm / (2f * focalLengthMm)).toDouble())
            return Math.toDegrees(2.0 * halfFovRad)
        }
        throw IllegalStateException("No usable back camera intrinsics found")
    }
}
