package dev.personal.musicplayer

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/** Shared helpers so every plugin runs blocking work off the platform thread. */
object Background {
    val pool: ExecutorService = Executors.newFixedThreadPool(4)
    private val main = Handler(Looper.getMainLooper())

    fun post(block: () -> Unit) = main.post(block)

    /** Runs [work] on the pool and reports success or a coded error to Dart. */
    fun run(result: MethodChannel.Result, work: () -> Any?) {
        pool.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: PlatformError) {
                main.post { result.error(e.code, e.message, null) }
            } catch (e: Throwable) {
                main.post { result.error("error", e.message ?: e.toString(), null) }
            }
        }
    }
}

class PlatformError(val code: String, message: String) : Exception(message)
