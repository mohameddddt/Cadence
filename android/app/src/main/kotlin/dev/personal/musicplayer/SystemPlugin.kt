package dev.personal.musicplayer

import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.NotificationCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Small platform odds and ends: alerts, battery optimisation, shared intents. */
class SystemPlugin(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {

    var activity: Activity? = null
    private val channel = MethodChannel(messenger, "dev.personal.musicplayer/system")
    private var pendingShare: Map<String, Any?>? = null

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "sdkInt" -> result.success(Build.VERSION.SDK_INT)
            "notify" -> {
                notify(
                    call.argument<Int>("id") ?: 1,
                    call.argument<String>("title") ?: "",
                    call.argument<String>("body") ?: "",
                )
                result.success(true)
            }
            "isIgnoringBatteryOptimizations" -> {
                val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
                result.success(pm.isIgnoringBatteryOptimizations(context.packageName))
            }
            "requestIgnoreBatteryOptimizations" -> {
                val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                    .setData(Uri.parse("package:${context.packageName}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                try { context.startActivity(intent); result.success(true) }
                catch (e: Throwable) { result.success(false) }
            }
            "takeInitialShare" -> {
                val s = pendingShare
                pendingShare = null
                result.success(s)
            }
            else -> result.notImplemented()
        }
    }

    /** Called by MainActivity for ACTION_SEND / ACTION_VIEW intents. */
    fun handleIntent(intent: Intent?, fromLaunch: Boolean) {
        val payload: Map<String, Any?> = when (intent?.action) {
            Intent.ACTION_SEND -> {
                val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: return
                mapOf("type" to "text", "value" to text)
            }
            Intent.ACTION_VIEW -> {
                val data = intent.data ?: return
                mapOf("type" to "audio", "value" to data.toString())
            }
            else -> return
        }
        // Avoid re-delivering the same intent after a configuration change.
        intent.action = null
        if (fromLaunch) pendingShare = payload
        else channel.invokeMethod("onShare", payload)
    }

    private fun notify(id: Int, title: String, body: String) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel("alerts") == null) {
            nm.createNotificationChannel(NotificationChannel("alerts", "Alerts", NotificationManager.IMPORTANCE_DEFAULT))
        }
        val open = context.packageManager.getLaunchIntentForPackage(context.packageName)
        val pi = PendingIntent.getActivity(context, 0, open, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val n = NotificationCompat.Builder(context, "alerts")
            .setSmallIcon(R.drawable.ic_stat_music)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(pi)
            .setAutoCancel(true)
            .build()
        try { nm.notify(id, n) } catch (_: SecurityException) { /* POST_NOTIFICATIONS not granted */ }
    }
}
