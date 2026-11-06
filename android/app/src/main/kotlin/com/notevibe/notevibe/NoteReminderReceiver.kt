package com.notevibe.notevibe

import android.app.*
import android.content.*
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import org.json.JSONObject

/** Local reminders survive process death and are restored after a reboot. */
class NoteReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val prefs = context.getSharedPreferences("note_reminders", Context.MODE_PRIVATE)
        if (intent.action == Intent.ACTION_BOOT_COMPLETED || intent.action == Intent.ACTION_MY_PACKAGE_REPLACED ||
            intent.action == AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED) {
            for ((id, raw) in prefs.all) {
                try {
                    val item = JSONObject(raw as String)
                    val at = item.getLong("at")
                    if (at > System.currentTimeMillis()) schedule(context, id, item.getString("title"), at)
                    else onReceive(context, Intent(context, NoteReminderReceiver::class.java).putExtra("noteId", id).putExtra("at", at))
                } catch (_: Exception) { /* Keep reminder for a later permission grant/retry. */ }
            }
            return
        }
        val id = intent.getStringExtra("noteId") ?: return
        val raw = prefs.getString(id, null) ?: return
        val item = try { JSONObject(raw) } catch (_: Exception) { return }
        // Ignore an alarm superseded by a newer reminder for the same note.
        if (item.getLong("at") != intent.getLongExtra("at", 0)) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "Напоминания о заметках", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Однократные напоминания прочитать заметку"
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            })
        }
        val open = Intent(context, MainActivity::class.java).apply {
            action = "com.notevibe.OPEN_NOTE"
            data = android.net.Uri.parse("notevibe://note/$id")
            putExtra("reminderNoteId", id)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pending = PendingIntent.getActivity(context, 0, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_note_reminder)
            .setContentTitle("Пора прочитать заметку")
            .setContentText(item.optString("title", "Заметка"))
            .setContentIntent(pending).setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .build()
        try {
            NotificationManagerCompat.from(context).notify(id, 0, notification)
            prefs.edit().remove(id).commit()
        } catch (_: SecurityException) { /* Do not discard an undelivered reminder. */ }
    }

    companion object {
        const val CHANNEL = "note_reminders"
        private fun alarmIntent(context: Context, id: String, at: Long = 0): PendingIntent {
            val intent = Intent(context, NoteReminderReceiver::class.java).apply {
                data = android.net.Uri.parse("notevibe://reminder/$id")
                putExtra("noteId", id)
                putExtra("at", at)
            }
            return PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }
        fun cancel(context: Context, id: String) {
            (context.getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(alarmIntent(context, id))
            context.getSharedPreferences("note_reminders", Context.MODE_PRIVATE).edit().remove(id).commit()
            NotificationManagerCompat.from(context).cancel(id, 0)
        }
        fun schedule(context: Context, id: String, title: String, at: Long) {
            require(at > System.currentTimeMillis()) { "Выберите время в будущем" }
            val alarm = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            require(Build.VERSION.SDK_INT < 31 || alarm.canScheduleExactAlarms()) { "Разрешите точные напоминания в настройках Android" }
            val pending = alarmIntent(context, id, at)
            val prefs = context.getSharedPreferences("note_reminders", Context.MODE_PRIVATE)
            val previous = prefs.getString(id, null)
            check(prefs.edit().putString(id, JSONObject().put("title", title).put("at", at).toString()).commit()) {
                "Не удалось сохранить напоминание"
            }
            try {
                // OS-owned alarm: delivery does not depend on the Flutter engine,
                // Activity, application process or an in-app timer being alive.
                // AlarmClock also wakes from Doze without the idle-alarm quota.
                val show = PendingIntent.getActivity(context, 0,
                    Intent(context, MainActivity::class.java).apply {
                        data = android.net.Uri.parse("notevibe://note/$id")
                        putExtra("reminderNoteId", id)
                    }, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                alarm.setAlarmClock(AlarmManager.AlarmClockInfo(at, show), pending)
            } catch (error: Exception) {
                if (previous == null) prefs.edit().remove(id).commit()
                else prefs.edit().putString(id, previous).commit()
                throw error
            }
        }
    }
}
