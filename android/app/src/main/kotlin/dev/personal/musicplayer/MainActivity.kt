package dev.personal.musicplayer

import android.content.Intent
import android.os.Bundle
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * Extends AudioServiceActivity so the Flutter engine (and with it the Dart download queue)
 * outlives the activity while the playback/download services are running.
 */
class MainActivity : AudioServiceActivity() {
    private var mediaStore: MediaStorePlugin? = null
    private var system: SystemPlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        val app = applicationContext
        mediaStore = MediaStorePlugin(app, messenger).also { it.activity = this }
        system = SystemPlugin(app, messenger).also { it.activity = this }
        TagsPlugin(app, messenger)
        AudioDecoder(app, messenger)
        YtDlpPlugin(app, messenger)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        system?.handleIntent(intent, fromLaunch = true)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        system?.handleIntent(intent, fromLaunch = false)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (mediaStore?.onActivityResult(requestCode, resultCode, data) == true) return
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        mediaStore?.activity = null
        system?.activity = null
        super.onDestroy()
    }
}
