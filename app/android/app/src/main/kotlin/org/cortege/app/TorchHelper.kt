package org.cortege.app

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager

/**
 * Allume et éteint la lampe arrière, sans autorisation (Android n'en demande pas
 * pour la lampe). Sert à se faire repérer à vue par un medic.
 */
class TorchHelper(context: Context) {
    private val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager

    /** Faux si le téléphone n'a pas de lampe ou la refuse. */
    fun set(on: Boolean): Boolean {
        return try {
            val id = manager.cameraIdList.firstOrNull { cameraId ->
                val characteristics = manager.getCameraCharacteristics(cameraId)
                characteristics.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true &&
                    characteristics.get(CameraCharacteristics.LENS_FACING) ==
                    CameraCharacteristics.LENS_FACING_BACK
            } ?: return false
            manager.setTorchMode(id, on)
            true
        } catch (e: Exception) {
            false
        }
    }
}
