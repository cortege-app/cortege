package org.cortege.app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.core.content.FileProvider
import android.os.Bundle
import android.provider.OpenableColumns
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

class MainActivity : FlutterActivity() {
    private val locationHelper by lazy { LocationHelper(this) }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        locationHelper.onPermissionResult(requestCode)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Pas de capture d'écran ni de miniature dans la liste des applis récentes.
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE,
        )
        // Un fichier ouvert avec Cortège : seulement au démarrage à froid, pas
        // quand Android recrée l'activité avec la même intention.
        if (savedInstanceState == null) handleIncoming(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIncoming(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        registerKeepAlive(flutterEngine)
        registerScreen(flutterEngine)
        registerLocation(flutterEngine)
        registerAlerts(flutterEngine)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, LOCATION_UPDATES_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) =
                    locationHelper.startUpdates(events)

                override fun onCancel(arguments: Any?) = locationHelper.stopUpdates()
            })
        registerFiles(flutterEngine)
        registerShare(flutterEngine)
        val torch = TorchHelper(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, TORCH_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "set") {
                    result.success(torch.set(call.argument<Boolean>("on") ?: false))
                } else {
                    result.notImplemented()
                }
            }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, COMPASS_CHANNEL)
            .setStreamHandler(CompassHelper(applicationContext))
        val hardwareSecret = HardwareSecret(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, HARDWARE_SECRET_CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "loadAll" -> {
                            val slot = call.argument<Int>("slot")
                            if (slot == null) {
                                result.error("bad_args", "slot manquant", null)
                            } else {
                                result.success(
                                    hardwareSecret.loadAll(slot).map {
                                        mapOf("generation" to it.first, "secret" to it.second)
                                    },
                                )
                            }
                        }
                        "store", "rotate" -> {
                            val slot = call.argument<Int>("slot")
                            val secret = call.argument<ByteArray>("secret")
                            if (slot == null || secret == null) {
                                result.error("bad_args", "arguments manquants", null)
                            } else {
                                result.success(
                                    if (call.method == "store") {
                                        hardwareSecret.store(slot, secret)
                                    } else {
                                        hardwareSecret.rotate(slot, secret)
                                    },
                                )
                            }
                        }
                        "keepOnly" -> {
                            val slot = call.argument<Int>("slot")
                            val generation = call.argument<Int>("generation")
                            if (slot == null || generation == null) {
                                result.error("bad_args", "arguments manquants", null)
                            } else {
                                hardwareSecret.keepOnly(slot, generation)
                                result.success(null)
                            }
                        }
                        "erase" -> {
                            hardwareSecret.eraseAll()
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    // Le message d'erreur ne contient jamais le secret.
                    result.error("hardware_secret", e.javaClass.simpleName, null)
                }
            }
    }

    /** Démarre ou arrête le service qui garde le maillage en vie en arrière-plan. */
    private fun registerKeepAlive(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, KEEP_ALIVE_CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "start" -> {
                            askNotificationPermission()
                            val intent = Intent(this, KeepAliveService::class.java)
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            result.success(null)
                        }
                        "stop" -> {
                            stopService(Intent(this, KeepAliveService::class.java))
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("keepalive", e.javaClass.simpleName, null)
                }
            }
    }

    /** Position du téléphone, une fois, à la demande (alerte de blessé). */
    private fun registerLocation(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LOCATION_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "current") {
                    try {
                        locationHelper.current(result, call.argument<Boolean>("accurate") ?: false)
                    } catch (e: Exception) {
                        result.success(null)
                    }
                } else {
                    result.notImplemented()
                }
            }
    }

    private var pendingPick: MethodChannel.Result? = null

    // Le fichier qu'une autre appli a ouvert avec Cortège, copié dans le dossier
    // privé. Il attend que le code ait été saisi : Dart le réclame ensuite.
    private var incoming: Map<String, String>? = null
    private var incomingCopying = false
    private var incomingWaiter: MethodChannel.Result? = null

    private fun handleIncoming(intent: Intent?) {
        if (intent == null) return
        val uri: Uri? = when (intent.action) {
            Intent.ACTION_VIEW -> intent.data
            Intent.ACTION_SEND ->
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_STREAM)
                }
            else -> null
        }
        if (uri == null) return
        // Seulement les fichiers qu'une autre appli prête (content://). Une adresse
        // file:// pourrait viser un fichier privé de cette appli lui-même (le coffre,
        // les secrets) : on la refuse.
        if (uri.scheme != "content") {
            intent.action = null
            intent.data = null
            return
        }
        // L'intention est consommée : elle ne doit pas rejouer l'import.
        intent.action = null
        intent.data = null
        incomingCopying = true
        Thread {
            var found: Map<String, String>? = null
            try {
                var name = uri.lastPathSegment ?: "fichier"
                contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) name = cursor.getString(0) ?: name
                }
                val directory = File(filesDir, "incoming").apply { mkdirs() }
                val target = File(directory, "incoming-" + System.nanoTime() + ".bin")
                var total = 0L
                val input = contentResolver.openInputStream(uri) ?: throw IOException("fichier illisible")
                try {
                    input.use { source ->
                        target.outputStream().use { output ->
                            val buffer = ByteArray(64 * 1024)
                            while (true) {
                                val n = source.read(buffer)
                                if (n < 0) break
                                total += n
                                if (total > MAX_INCOMING) throw IOException("fichier trop gros")
                                output.write(buffer, 0, n)
                            }
                        }
                    }
                } catch (e: Exception) {
                    target.delete()
                    throw e
                }
                found = mapOf("path" to target.absolutePath, "name" to name)
            } catch (e: Exception) {
                found = null
            }
            runOnUiThread {
                incomingCopying = false
                val waiter = incomingWaiter
                if (waiter != null) {
                    incomingWaiter = null
                    waiter.success(found)
                } else {
                    incoming = found
                }
            }
        }.start()
    }

    /**
     * Partage de l'appli de téléphone à téléphone : l'appli copie son propre fichier
     * d'installation (celui d'où elle a été installée) dans un dossier prêté le
     * temps de l'envoi, puis ouvre la feuille de partage d'Android. Rien de ce
     * qu'elle garde (coffre, groupes, messages) n'est dans ce fichier.
     */
    private fun registerShare(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "prepare" -> Thread {
                        try {
                            val info = applicationContext.applicationInfo
                            if (!info.splitSourceDirs.isNullOrEmpty()) {
                                // Installée en plusieurs morceaux : le fichier de base seul
                                // ne s'installerait pas chez l'autre personne.
                                runOnUiThread { result.success(mapOf("error" to "split")) }
                                return@Thread
                            }
                            val directory = File(cacheDir, "share")
                            directory.deleteRecursively()
                            directory.mkdirs()
                            val target = File(directory, "Cortege.apk")
                            File(info.sourceDir).inputStream().use { input ->
                                target.outputStream().use { output -> input.copyTo(output, 64 * 1024) }
                            }
                            runOnUiThread {
                                result.success(mapOf("path" to target.absolutePath, "size" to target.length()))
                            }
                        } catch (e: Exception) {
                            runOnUiThread { result.success(mapOf("error" to "copy")) }
                        }
                    }.start()
                    "send" -> {
                        try {
                            val file = File(File(cacheDir, "share"), "Cortege.apk")
                            if (!file.exists()) {
                                result.success(false)
                            } else {
                                val uri = FileProvider.getUriForFile(this, "$packageName.share", file)
                                val send = Intent(Intent.ACTION_SEND).apply {
                                    type = "application/vnd.android.package-archive"
                                    putExtra(Intent.EXTRA_STREAM, uri)
                                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                }
                                startActivity(Intent.createChooser(send, "Envoyer l'appli"))
                                result.success(true)
                            }
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** Supprime les copies temporaires. Les fichiers reçus récents restent, sauf [all]. */
    private fun cleanFiles(all: Boolean) {
        File(filesDir, "imports").deleteRecursively()
        File(cacheDir, "share").deleteRecursively()
        val received = File(filesDir, "incoming")
        if (all) {
            received.deleteRecursively()
            incoming = null
        } else {
            val limit = System.currentTimeMillis() - 2 * 60 * 60 * 1000
            received.listFiles()?.forEach { if (it.lastModified() < limit) it.delete() }
        }
    }

    /**
     * Choix d'un fichier par le sélecteur du système (aucune autorisation de
     * stockage). Le fichier est copié dans le dossier privé de l'appli : c'est
     * tout ce que l'appli en voit.
     */
    private fun registerFiles(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FILES_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "incoming" -> {
                        val ready = incoming
                        if (ready != null) {
                            incoming = null
                            result.success(ready)
                        } else if (incomingCopying) {
                            incomingWaiter?.success(null)
                            incomingWaiter = result
                        } else {
                            result.success(null)
                        }
                    }
                    "pick" -> {
                        if (pendingPick != null) {
                            result.error("busy", "un choix est déjà en cours", null)
                        } else {
                            pendingPick = result
                            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "*/*"
                            }
                            @Suppress("DEPRECATION")
                            startActivityForResult(intent, PICK_REQUEST)
                        }
                    }
                    "clean" -> {
                        cleanFiles(call.argument<Boolean>("all") ?: false)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != PICK_REQUEST) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingPick ?: return
        pendingPick = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        Thread {
            var target: File? = null
            try {
                var name = "fichier"
                contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) name = cursor.getString(0) ?: name
                }
                val directory = File(filesDir, "imports").apply { mkdirs() }
                val copy = File(directory, "import-" + System.nanoTime() + ".bin")
                target = copy
                var total = 0L
                contentResolver.openInputStream(uri)?.use { input ->
                    copy.outputStream().use { output ->
                        val buffer = ByteArray(64 * 1024)
                        while (true) {
                            val n = input.read(buffer)
                            if (n < 0) break
                            total += n
                            if (total > MAX_INCOMING) throw IOException("fichier trop gros")
                            output.write(buffer, 0, n)
                        }
                    }
                }
                runOnUiThread { result.success(mapOf("path" to copy.absolutePath, "name" to name)) }
            } catch (e: Exception) {
                target?.delete()
                runOnUiThread { result.success(null) }
            }
        }.start()
    }

    /** Vibration : un proche se tait, un blessé est signalé. Aucune notification. */
    private fun registerAlerts(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ALERTS_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "vibrate") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    val pattern = (call.argument<List<Int>>("pattern") ?: emptyList())
                        .map { it.toLong() }
                        .toLongArray()
                    val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        (getSystemService(VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
                    } else {
                        @Suppress("DEPRECATION")
                        getSystemService(VIBRATOR_SERVICE) as Vibrator
                    }
                    if (pattern.isNotEmpty() && vibrator.hasVibrator()) {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            vibrator.vibrate(VibrationEffect.createWaveform(pattern, -1))
                        } else {
                            @Suppress("DEPRECATION")
                            vibrator.vibrate(pattern, -1)
                        }
                    }
                    result.success(null)
                } catch (e: Exception) {
                    result.success(null)
                }
            }
    }

    /** Luminosité maximale tant qu'un QR est affiché : plus facile à scanner. */
    private fun registerScreen(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SCREEN_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "maxBrightness") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val on = call.argument<Boolean>("on") ?: false
                runOnUiThread {
                    val params = window.attributes
                    params.screenBrightness = if (on) {
                        WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_FULL
                    } else {
                        WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                    }
                    window.attributes = params
                }
                result.success(null)
            }
    }

    /**
     * Android 13 et plus cache la notification du service tant que la
     * permission n'est pas accordée. Le service tourne quand même.
     */
    private fun askNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }

    private companion object {
        const val HARDWARE_SECRET_CHANNEL = "org.cortege.app/hardware_secret"
        const val KEEP_ALIVE_CHANNEL = "org.cortege.app/keepalive"
        const val SCREEN_CHANNEL = "org.cortege.app/screen"
        const val LOCATION_CHANNEL = "org.cortege.app/location"
        const val ALERTS_CHANNEL = "org.cortege.app/alerts"
        const val COMPASS_CHANNEL = "org.cortege.app/compass"
        const val LOCATION_UPDATES_CHANNEL = "org.cortege.app/location_updates"
        const val FILES_CHANNEL = "org.cortege.app/files"
        const val SHARE_CHANNEL = "org.cortege.app/share"
        const val PICK_REQUEST = 3
        // Une carte de ville fait quelques Mo, la plus grande que l'outil accepte 150 Mo.
        const val MAX_INCOMING = 300L * 1024 * 1024
        const val TORCH_CHANNEL = "org.cortege.app/torch"
    }
}
