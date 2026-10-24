package org.cortege.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Ne fait rien d'autre que tenir l'appli en vie quand l'écran est éteint, avec
 * la notification qu'Android exige. La notification reste neutre (aucun nom de
 * l'appli, cachée sur l'écran verrouillé) pour ne rien révéler à quelqu'un qui
 * regarde le téléphone.
 */
class KeepAliveService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_NOT_STICKY
    }

    private fun buildNotification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Service", NotificationManager.IMPORTANCE_LOW).apply {
                    lockscreenVisibility = Notification.VISIBILITY_SECRET
                    setShowBadge(false)
                },
            )
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle("Service actif")
            .setOngoing(true)
            .setVisibility(Notification.VISIBILITY_SECRET)
            .build()
    }

    private companion object {
        const val CHANNEL_ID = "service"
        const val NOTIFICATION_ID = 1
    }
}
