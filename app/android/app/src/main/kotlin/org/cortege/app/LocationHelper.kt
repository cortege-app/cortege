package org.cortege.app

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Donne la position du téléphone, une fois, à la demande. Elle vient du système
 * Android (GPS, sinon réseau) : aucune bibliothèque de Google, rien n'est
 * enregistré ici ni ailleurs.
 */
class LocationHelper(private val activity: Activity) {
    private var waitingForPermission: MethodChannel.Result? = null
    private var waitingAccurate = false

    fun current(result: MethodChannel.Result, accurate: Boolean) {
        if (hasPermission()) {
            fetch(result, accurate)
            return
        }
        if (waitingForPermission != null) {
            result.success(null)
            return
        }
        waitingForPermission = result
        waitingAccurate = accurate
        activity.requestPermissions(
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION),
            REQUEST_CODE,
        )
    }

    /** À appeler depuis `onRequestPermissionsResult` de l'activité. */
    fun onPermissionResult(requestCode: Int) {
        if (requestCode != REQUEST_CODE) return
        val result = waitingForPermission ?: return
        waitingForPermission = null
        if (hasPermission()) fetch(result, waitingAccurate) else result.success(null)
    }

    private fun hasPermission(): Boolean =
        activity.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
            activity.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    @SuppressLint("MissingPermission")
    private fun fetch(result: MethodChannel.Result, accurate: Boolean) {
        val manager = activity.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val providers = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
            .filter { manager.isProviderEnabled(it) }
        val gpsOn = providers.contains(LocationManager.GPS_PROVIDER)
        // Pour guider quelqu'un, une position réseau (30 à 100 m d'erreur) ne vaut
        // rien : on ne retient que le GPS, et la dernière position récente doit en
        // venir.
        val strict = accurate && gpsOn
        val last = providers
            .filter { !strict || it == LocationManager.GPS_PROVIDER }
            .mapNotNull { manager.getLastKnownLocation(it) }
            .maxByOrNull { it.time }
        val freshLimit = if (strict) FRESH_GPS_MS else FRESH_MS
        if (last != null && System.currentTimeMillis() - last.time < freshLimit) {
            result.success(describe(last))
            return
        }
        // Une dernière position connue vieille de plusieurs minutes (voire de
        // plusieurs jours) ne doit jamais passer pour la position actuelle : on
        // enverrait les secours au mauvais endroit.
        val recent = last?.takeIf { System.currentTimeMillis() - it.time < STALE_MS }
        if (providers.isEmpty()) {
            result.success(recent?.let { describe(it) })
            return
        }

        // Toutes les sources actives en même temps : la première position reçue est
        // la bonne (une alerte ne doit pas attendre un GPS qui n'accroche pas).
        // En mode précis, le réseau ne sert que de secours si le GPS ne répond pas.
        var done = false
        var fallback: Location? = null
        val signals = mutableListOf<CancellationSignal>()
        val listeners = mutableListOf<LocationListener>()
        val handler = Handler(Looper.getMainLooper())
        fun finish(location: Location?) {
            if (done) return
            done = true
            signals.forEach { it.cancel() }
            listeners.forEach { manager.removeUpdates(it) }
            val best = location ?: recent
            result.success(best?.let { describe(it) })
        }
        fun accept(provider: String, location: Location?) {
            if (location == null) return
            if (strict && provider != LocationManager.GPS_PROVIDER) {
                fallback = location
            } else {
                finish(location)
            }
        }
        for (provider in providers) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val signal = CancellationSignal()
                signals.add(signal)
                manager.getCurrentLocation(provider, signal, activity.mainExecutor) { location ->
                    accept(provider, location)
                }
            } else {
                val listener = object : LocationListener {
                    override fun onLocationChanged(location: Location) = accept(provider, location)

                    @Deprecated("Obsolète")
                    override fun onStatusChanged(provider: String?, status: Int, extras: android.os.Bundle?) {}
                }
                listeners.add(listener)
                @Suppress("DEPRECATION")
                manager.requestSingleUpdate(provider, listener, Looper.getMainLooper())
            }
        }
        handler.postDelayed({ finish(fallback) }, TIMEOUT_MS)
    }

    private var gpsListener: LocationListener? = null
    private var networkListener: LocationListener? = null
    private var lastGpsAt = 0L

    /**
     * Positions en continu pour suivre un déplacement. Le GPS d'abord (une par
     * seconde) ; le réseau ne passe que si le GPS se tait depuis dix secondes.
     * Rien n'est gardé, et tout s'arrête avec [stopUpdates].
     */
    @SuppressLint("MissingPermission")
    fun startUpdates(sink: EventChannel.EventSink) {
        stopUpdates()
        if (!hasPermission()) {
            sink.endOfStream()
            return
        }
        val manager = activity.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val handler = Handler(Looper.getMainLooper())
        lastGpsAt = 0L
        val gps = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                lastGpsAt = System.currentTimeMillis()
                handler.post { sink.success(describe(location)) }
            }

            @Deprecated("Obsolète")
            override fun onStatusChanged(provider: String?, status: Int, extras: android.os.Bundle?) {}
        }
        val network = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                if (System.currentTimeMillis() - lastGpsAt > 10_000) {
                    handler.post { sink.success(describe(location)) }
                }
            }

            @Deprecated("Obsolète")
            override fun onStatusChanged(provider: String?, status: Int, extras: android.os.Bundle?) {}
        }
        try {
            if (manager.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
                manager.requestLocationUpdates(LocationManager.GPS_PROVIDER, 1000L, 0f, gps, Looper.getMainLooper())
                gpsListener = gps
            }
            if (manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) {
                manager.requestLocationUpdates(LocationManager.NETWORK_PROVIDER, 3000L, 0f, network, Looper.getMainLooper())
                networkListener = network
            }
        } catch (e: SecurityException) {
            sink.endOfStream()
        }
    }

    fun stopUpdates() {
        val manager = activity.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        gpsListener?.let { manager.removeUpdates(it) }
        networkListener?.let { manager.removeUpdates(it) }
        gpsListener = null
        networkListener = null
    }

    private fun describe(location: Location): Map<String, Double> = mapOf(
        "lat" to location.latitude,
        "lon" to location.longitude,
        "accuracy" to location.accuracy.toDouble(),
    )

    private companion object {
        const val REQUEST_CODE = 2
        const val FRESH_MS = 60_000L
        const val FRESH_GPS_MS = 10_000L
        const val STALE_MS = 5 * 60_000L
        const val TIMEOUT_MS = 7_000L
    }
}
