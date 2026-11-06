package com.notevibe.notevibe

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Android filters incoming multicast/broadcast UDP packets unless a
 * MulticastLock is held. The lock is needed for LAN discovery.
 */
class MainActivity : FlutterActivity() {
    private val vaultBiometrics by lazy { VaultBiometrics(this) }
    private var lock: WifiManager.MulticastLock? = null
    private var galleryResult: MethodChannel.Result? = null
    private var notificationResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        if (getSharedPreferences("vault_privacy", Context.MODE_PRIVATE).getBoolean("enabled", false)) {
            window.addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
        }
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 8042) {
            notificationResult?.success(grantResults.firstOrNull() == android.content.pm.PackageManager.PERMISSION_GRANTED)
            notificationResult = null
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 8041) return
        val reply = galleryResult ?: return
        galleryResult = null
        val uri = data?.data
        if (resultCode != android.app.Activity.RESULT_OK || uri == null) {
            reply.success(null)
            return
        }
        // Stream on a worker: never load a full image into the Android UI thread.
        Thread {
            var output: File? = null
            try {
                var name = "Фото"
                contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                    if (it.moveToFirst()) name = it.getString(0) ?: name
                }
                val mime = contentResolver.getType(uri) ?: "image/jpeg"
                require(mime.startsWith("image/")) { "Выберите изображение" }
                val folder = File(cacheDir, "notevibe_gallery").apply { mkdirs() }
                val target = File.createTempFile("photo-", ".tmp", folder)
                output = target
                contentResolver.openInputStream(uri).use { input ->
                    requireNotNull(input) { "Не удалось прочитать фото" }
                    target.outputStream().use { sink ->
                        val buffer = ByteArray(65536)
                        var total = 0L
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            total += count
                            require(total <= 100L * 1024 * 1024) { "Фото больше 100 МБ" }
                            sink.write(buffer, 0, count)
                        }
                    }
                }
                runOnUiThread { reply.success(mapOf("path" to target.absolutePath, "name" to name, "mime" to mime)) }
            } catch (e: Exception) {
                output?.delete()
                runOnUiThread { reply.error("gallery", e.message, null) }
            }
        }.start()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "notevibe/update")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "vaultSecureScreen" -> {
                        val enabled = call.argument<Boolean>("enabled") == true
                        getSharedPreferences("vault_privacy", Context.MODE_PRIVATE).edit().putBoolean("enabled", enabled).commit()
                        if (enabled) {
                            window.addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
                            val reminders = getSharedPreferences("note_reminders", Context.MODE_PRIVATE)
                            val editor = reminders.edit()
                            for ((id, raw) in reminders.all) {
                                try {
                                    val item = org.json.JSONObject(raw as String).put("title", "Заметка")
                                    editor.putString(id, item.toString())
                                } catch (_: Exception) { }
                            }
                            editor.commit()
                        }
                        else window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
                        result.success(null)
                    }
                    "vaultBioStatus", "vaultBioEnable", "vaultBioUnlock", "vaultBioDisable" ->
                        vaultBiometrics.handle(call.method, call.argument<String>("password"), result)
                    "attachmentClipboard" -> {
                        try {
                            val file = java.io.File(call.argument<String>("path") ?: "").canonicalFile
                            val root = java.io.File(cacheDir, "notevibe_clipboard").canonicalFile
                            require(file.parentFile == root && file.isFile) { "Недопустимый файл буфера обмена" }
                            val uri = androidx.core.content.FileProvider.getUriForFile(this, "$packageName.updates", file)
                            val clip = android.content.ClipData.newUri(contentResolver,
                                call.argument<String>("name") ?: "Вложение", uri)
                            (getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager).setPrimaryClip(clip)
                            result.success(null)
                        } catch (e: Exception) { result.error("clipboard", e.message, null) }
                    }
                    "reminderPermission" -> {
                        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                            if (notificationResult != null) result.error("busy", "Запрос разрешения уже открыт", null)
                            else {
                                notificationResult = result
                                requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 8042)
                            }
                        } else result.success(androidx.core.app.NotificationManagerCompat.from(this).areNotificationsEnabled())
                    }
                    "reminderExactAllowed" -> result.success(Build.VERSION.SDK_INT < 31 || (getSystemService(Context.ALARM_SERVICE) as android.app.AlarmManager).canScheduleExactAlarms())
                    "reminderExactSettings" -> {
                        if (Build.VERSION.SDK_INT >= 31) startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:$packageName")))
                        result.success(null)
                    }
                    "reminderSchedule" -> {
                        try {
                            NoteReminderReceiver.schedule(this, call.argument<String>("id")!!, call.argument<String>("title") ?: "Заметка", call.argument<Number>("at")!!.toLong())
                            result.success(null)
                        } catch (e: Exception) { result.error("reminder", e.message, null) }
                    }
                    "reminderCancel" -> {
                        NoteReminderReceiver.cancel(this, call.argument<String>("id")!!)
                        result.success(null)
                    }
                    "reminderGet" -> result.success(getSharedPreferences("note_reminders", Context.MODE_PRIVATE).getString(call.argument<String>("id"), null))
                    "reminderOpenNote" -> {
                        val id = intent?.getStringExtra("reminderNoteId")
                        intent?.removeExtra("reminderNoteId")
                        result.success(id)
                    }
                    "pickPhoto" -> {
                        if (galleryResult != null) {
                            result.error("busy", "Выбор фото уже открыт", null)
                        } else {
                            galleryResult = result
                            try {
                                val intent = if (Build.VERSION.SDK_INT >= 33) {
                                    Intent("android.provider.action.PICK_IMAGES").setType("image/*")
                                } else {
                                    Intent(Intent.ACTION_GET_CONTENT).setType("image/*").addCategory(Intent.CATEGORY_OPENABLE)
                                }
                                startActivityForResult(intent, 8041)
                            } catch (e: Exception) {
                                galleryResult = null
                                result.error("gallery", e.message, null)
                            }
                        }
                    }
                    "abi" -> result.success(Build.SUPPORTED_ABIS.firstOrNull() ?: "")
                    "canInstall" -> result.success(
                        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls()
                    )
                    "openUrl" -> {
                        try {
                            val url = call.argument<String>("url") ?: throw IllegalArgumentException("url")
                            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("open", e.message, null)
                        }
                    }
                    "openInstallSettings" -> {
                        val intent = Intent(
                            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:$packageName")
                        )
                        startActivity(intent)
                        result.success(true)
                    }
                    "installApk" -> {
                        try {
                            val file = File(call.argument<String>("path") ?: throw IllegalArgumentException("path"))
                            require(file.isFile && file.length() > 0) { "Файл обновления отсутствует или пуст" }
                            val archive = packageManager.getPackageArchiveInfo(file.absolutePath, 0)
                            require(archive != null && archive.packageName == packageName) {
                                "APK повреждён или принадлежит другому приложению. Скачайте обновление заново."
                            }
                            val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "application/vnd.android.package-archive")
                                clipData = android.content.ClipData.newRawUri("NoteVibe update", uri)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("install", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "notevibe/net")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquireMulticast" -> {
                        try {
                            if (lock == null) {
                                val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                                lock = wifi.createMulticastLock("notevibe-discovery").apply {
                                    setReferenceCounted(false)
                                }
                            }
                            lock?.acquire()
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("lock", e.message, null)
                        }
                    }
                    "releaseMulticast" -> {
                        lock?.takeIf { it.isHeld }?.release()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        lock?.takeIf { it.isHeld }?.release()
        super.onDestroy()
    }
}
