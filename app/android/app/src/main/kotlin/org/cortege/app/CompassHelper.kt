package org.cortege.app

import android.content.Context
import android.hardware.GeomagneticField
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import io.flutter.plugin.common.EventChannel

/**
 * Orientation du téléphone, une dizaine de fois par seconde tant que l'écran de
 * la boussole est ouvert : la matrice de rotation (9 nombres) et la déclinaison
 * magnétique du lieu. Elles viennent des capteurs du téléphone, sans
 * bibliothèque tierce et sans autorisation.
 */
class CompassHelper(context: Context) : EventChannel.StreamHandler, SensorEventListener {
    private val sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private var sink: EventChannel.EventSink? = null
    private var declination = 0f
    private var lastSentMillis = 0L
    private val rotation = FloatArray(9)

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        val sensor = sensorManager.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
        if (sensor == null) {
            events.error("no_sensor", "Pas de capteur d'orientation", null)
            events.endOfStream()
            return
        }
        // La position sert à passer du nord magnétique au nord géographique.
        val args = arguments as? Map<*, *>
        val lat = (args?.get("lat") as? Number)?.toFloat()
        val lon = (args?.get("lon") as? Number)?.toFloat()
        declination = if (lat != null && lon != null) {
            GeomagneticField(lat, lon, 0f, System.currentTimeMillis()).declination
        } else {
            0f
        }
        sink = events
        sensorManager.registerListener(this, sensor, SensorManager.SENSOR_DELAY_UI)
    }

    override fun onCancel(arguments: Any?) {
        sensorManager.unregisterListener(this)
        sink = null
    }

    override fun onSensorChanged(event: SensorEvent) {
        if (event.sensor.type != Sensor.TYPE_ROTATION_VECTOR) return
        val nowMillis = event.timestamp / 1_000_000L
        if (nowMillis - lastSentMillis < 100) return
        lastSentMillis = nowMillis

        // Le cap se calcule côté Dart (testé) : on envoie la matrice de rotation et
        // la déclinaison magnétique du lieu.
        SensorManager.getRotationMatrixFromVector(rotation, event.values)
        val values = ArrayList<Double>(10)
        for (value in rotation) values.add(value.toDouble())
        values.add(declination.toDouble())
        sink?.success(values)
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
}
