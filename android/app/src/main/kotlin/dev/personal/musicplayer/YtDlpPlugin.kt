package dev.personal.musicplayer

import android.content.Context
import com.yausername.aria2c.Aria2c
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Thin bridge to youtubedl-android (yt-dlp + ffmpeg + aria2c bundled on-device).
 * Dart builds the argument lists; this class only executes them and reports progress.
 */
class YtDlpPlugin(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private var sink: EventChannel.EventSink? = null
    @Volatile private var initialised = false
    private val initLock = Any()

    init {
        MethodChannel(messenger, "dev.personal.musicplayer/ytdlp").setMethodCallHandler(this)
        EventChannel(messenger, "dev.personal.musicplayer/ytdlp_events").setStreamHandler(this)
    }

    private fun ensureInit() {
        if (initialised) return
        synchronized(initLock) {
            if (initialised) return
            try {
                YoutubeDL.getInstance().init(context.applicationContext)
                FFmpeg.getInstance().init(context.applicationContext)
                try { Aria2c.init(context.applicationContext) } catch (_: Throwable) { /* optional */ }
            } catch (e: Throwable) {
                throw PlatformError("init_failed", e.message ?: e.toString())
            }
            initialised = true
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> Background.run(result) {
                ensureInit()
                YoutubeDL.getInstance().version(context)
            }
            "version" -> Background.run(result) {
                ensureInit()
                YoutubeDL.getInstance().versionName(context)
            }
            "update" -> {
                val channel = call.argument<String>("channel") ?: "stable"
                Background.run(result) {
                    ensureInit()
                    val ch = when (channel) {
                        "nightly" -> YoutubeDL.UpdateChannel._NIGHTLY
                        "master" -> YoutubeDL.UpdateChannel._MASTER
                        else -> YoutubeDL.UpdateChannel._STABLE
                    }
                    val status = YoutubeDL.getInstance().updateYoutubeDL(context.applicationContext, ch)
                    mapOf("status" to (status?.name ?: "DONE"), "version" to YoutubeDL.getInstance().versionName(context))
                }
            }
            "run" -> {
                val args = call.argument<List<String>>("args") ?: return result.error("args", "args", null)
                val processId = call.argument<String>("processId")
                Background.run(result) {
                    ensureInit()
                    val resp = YoutubeDL.getInstance().execute(newRequest(args), processId)
                    mapOf("exitCode" to resp.exitCode, "out" to resp.out, "err" to resp.err)
                }
            }
            "download" -> {
                val args = call.argument<List<String>>("args") ?: return result.error("args", "args", null)
                val jobId = call.argument<String>("jobId") ?: return result.error("args", "jobId", null)
                Background.pool.execute {
                    try {
                        ensureInit()
                        val resp = YoutubeDL.getInstance().execute(newRequest(args), jobId) { progress, eta, line ->
                            Background.post {
                                sink?.success(
                                    mapOf("jobId" to jobId, "progress" to progress.toDouble(), "eta" to eta, "line" to line),
                                )
                            }
                        }
                        Background.post {
                            result.success(mapOf("exitCode" to resp.exitCode, "out" to resp.out, "err" to resp.err))
                        }
                    } catch (e: YoutubeDL.CanceledException) {
                        Background.post { result.error("cancelled", "Cancelled", null) }
                    } catch (e: PlatformError) {
                        Background.post { result.error(e.code, e.message, null) }
                    } catch (e: Throwable) {
                        Background.post { result.error("ytdlp_failed", e.message ?: e.toString(), null) }
                    }
                }
            }
            "cancel" -> {
                val jobId = call.argument<String>("jobId") ?: return result.error("args", "jobId", null)
                result.success(YoutubeDL.getInstance().destroyProcessById(jobId))
            }
            "setForeground" -> {
                DownloadService.update(
                    context,
                    active = call.argument<Boolean>("active") ?: false,
                    title = call.argument<String>("title") ?: "Downloading",
                    text = call.argument<String>("text") ?: "",
                    progress = call.argument<Int>("progress") ?: -1,
                )
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun newRequest(args: List<String>): YoutubeDLRequest =
        YoutubeDLRequest(emptyList<String>()).addCommands(args)

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { sink = events }
    override fun onCancel(arguments: Any?) { sink = null }
}
