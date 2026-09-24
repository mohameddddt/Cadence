package dev.personal.musicplayer

import android.app.Activity
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.ContentObserver
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.MediaStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Library access: MediaStore queries, Storage Access Framework folders, inserting downloads
 * into the shared Music collection, delete/write requests, and change notifications.
 */
class MediaStorePlugin(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    var activity: Activity? = null

    private var pickResult: MethodChannel.Result? = null
    private var writeResult: MethodChannel.Result? = null
    private var observer: ContentObserver? = null

    init {
        MethodChannel(messenger, "dev.personal.musicplayer/mediastore").setMethodCallHandler(this)
        EventChannel(messenger, "dev.personal.musicplayer/mediastore_events").setStreamHandler(this)
    }

    private val audioCollection: Uri
        get() = if (Build.VERSION.SDK_INT >= 29) MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        else MediaStore.Audio.Media.EXTERNAL_CONTENT_URI

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "queryAudio" -> Background.run(result) { queryAudio() }
            "pickFolder" -> pickFolder(result)
            "persistedFolders" -> Background.run(result) { persistedFolders() }
            "releaseFolder" -> {
                val uri = call.argument<String>("uri") ?: return result.error("args", "uri", null)
                try {
                    context.contentResolver.releasePersistableUriPermission(
                        Uri.parse(uri), Intent.FLAG_GRANT_READ_URI_PERMISSION,
                    )
                } catch (_: Throwable) {}
                result.success(true)
            }
            "scanTree" -> {
                val uri = call.argument<String>("uri") ?: return result.error("args", "uri", null)
                Background.run(result) { scanTree(Uri.parse(uri)) }
            }
            "insertAudio" -> {
                val src = call.argument<String>("src") ?: return result.error("args", "src", null)
                val name = call.argument<String>("displayName") ?: return result.error("args", "name", null)
                val dir = call.argument<String>("relativeDir") ?: ""
                val mime = call.argument<String>("mime") ?: "audio/mpeg"
                Background.run(result) { insertAudio(File(src), name, dir, mime) }
            }
            "moveAudio" -> {
                val uri = call.argument<String>("uri") ?: return result.error("args", "uri", null)
                val name = call.argument<String>("displayName") ?: return result.error("args", "name", null)
                val dir = call.argument<String>("relativeDir") ?: ""
                Background.run(result) { moveAudio(uri, dir, name) }
            }
            "deleteAudio" -> {
                val uri = call.argument<String>("uri") ?: return result.error("args", "uri", null)
                Background.run(result) { deleteAudio(uri) }
            }
            "requestWrite" -> {
                val uris = call.argument<List<String>>("uris") ?: emptyList()
                requestWrite(uris, result)
            }
            "rescan" -> {
                val path = call.argument<String>("path") ?: return result.error("args", "path", null)
                MediaScannerConnection.scanFile(context, arrayOf(path), null, null)
                result.success(true)
            }
            "musicDirectory" -> result.success(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MUSIC).absolutePath,
            )
            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------ MediaStore

    private fun queryAudio(): List<Map<String, Any?>> {
        val projection = mutableListOf(
            MediaStore.Audio.Media._ID, MediaStore.Audio.Media.DATA, MediaStore.Audio.Media.DISPLAY_NAME,
            MediaStore.Audio.Media.TITLE, MediaStore.Audio.Media.ARTIST, MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.TRACK, MediaStore.Audio.Media.YEAR, MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.SIZE, MediaStore.Audio.Media.DATE_MODIFIED, MediaStore.Audio.Media.DATE_ADDED,
            MediaStore.Audio.Media.MIME_TYPE,
        )
        if (Build.VERSION.SDK_INT >= 29) projection += MediaStore.Audio.Media.RELATIVE_PATH
        if (Build.VERSION.SDK_INT >= 30) {
            projection += "album_artist"; projection += "bitrate"; projection += "genre"
        }
        // Rows still being indexed have NULL flags: keep them, drop only real ringtones/alerts.
        fun notFlag(c: String) = "($c IS NULL OR $c=0)"
        val selection = listOf(
            MediaStore.Audio.Media.IS_RINGTONE, MediaStore.Audio.Media.IS_NOTIFICATION, MediaStore.Audio.Media.IS_ALARM,
        ).joinToString(" AND ") { notFlag(it) }
        val rows = ArrayList<Map<String, Any?>>()
        context.contentResolver.query(audioCollection, projection.toTypedArray(), selection, null, null)?.use { c ->
            fun idx(n: String) = c.getColumnIndex(n)
            val iId = idx(MediaStore.Audio.Media._ID)
            while (c.moveToNext()) {
                val id = c.getLong(iId)
                val m = HashMap<String, Any?>()
                m["id"] = id
                m["uri"] = ContentUris.withAppendedId(audioCollection, id).toString()
                for (col in projection) {
                    val i = idx(col)
                    if (i < 0 || c.isNull(i)) continue
                    when (col) {
                        MediaStore.Audio.Media._ID -> {}
                        MediaStore.Audio.Media.DATA -> m["path"] = c.getString(i)
                        MediaStore.Audio.Media.DISPLAY_NAME -> m["displayName"] = c.getString(i)
                        MediaStore.Audio.Media.TITLE -> m["title"] = c.getString(i)
                        MediaStore.Audio.Media.ARTIST -> m["artist"] = c.getString(i)
                        MediaStore.Audio.Media.ALBUM -> m["album"] = c.getString(i)
                        MediaStore.Audio.Media.TRACK -> {
                            // MediaStore encodes disc*1000 + track.
                            val t = c.getInt(i)
                            if (t >= 1000) { m["discNo"] = t / 1000; m["trackNo"] = t % 1000 } else m["trackNo"] = t
                        }
                        MediaStore.Audio.Media.YEAR -> m["year"] = c.getInt(i)
                        MediaStore.Audio.Media.DURATION -> m["durationMs"] = c.getLong(i)
                        MediaStore.Audio.Media.SIZE -> m["size"] = c.getLong(i)
                        MediaStore.Audio.Media.DATE_MODIFIED -> m["dateModified"] = c.getLong(i)
                        MediaStore.Audio.Media.DATE_ADDED -> m["dateAdded"] = c.getLong(i)
                        MediaStore.Audio.Media.MIME_TYPE -> m["mime"] = c.getString(i)
                        "album_artist" -> m["albumArtist"] = c.getString(i)
                        "bitrate" -> m["bitrate"] = c.getLong(i) / 1000
                        "genre" -> m["genre"] = c.getString(i)
                        MediaStore.Audio.Media.RELATIVE_PATH -> m["relativePath"] = c.getString(i)
                    }
                }
                rows.add(m)
            }
        }
        return rows
    }

    // ------------------------------------------------------------------ SAF

    private fun pickFolder(result: MethodChannel.Result) {
        val act = activity ?: return result.error("no_activity", "No foreground activity", null)
        if (pickResult != null) return result.error("busy", "A picker is already open", null)
        pickResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
        )
        act.startActivityForResult(intent, REQ_PICK_TREE)
    }

    private fun persistedFolders(): List<Map<String, Any?>> =
        context.contentResolver.persistedUriPermissions.filter { it.isReadPermission && DocumentsContract.isTreeUri(it.uri) }
            .map { mapOf("uri" to it.uri.toString(), "name" to folderName(it.uri)) }

    private fun folderName(tree: Uri): String {
        val docId = DocumentsContract.getTreeDocumentId(tree)
        return docId.substringAfter(':', docId).ifEmpty { "Storage" }
    }

    private val audioExt = setOf("mp3", "flac", "m4a", "aac", "ogg", "opus", "wav", "wma", "mka", "m4b", "oga")

    private fun scanTree(tree: Uri): List<Map<String, Any?>> {
        val rows = ArrayList<Map<String, Any?>>()
        val rootId = DocumentsContract.getTreeDocumentId(tree)
        fun walk(docId: String, rel: String) {
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, docId)
            val cols = arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_SIZE,
                DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            )
            val subdirs = ArrayList<Pair<String, String>>()
            context.contentResolver.query(children, cols, null, null, null)?.use { c ->
                while (c.moveToNext()) {
                    val id = c.getString(0)
                    val name = c.getString(1) ?: continue
                    val mime = c.getString(2) ?: ""
                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                        subdirs.add(id to "$rel$name/")
                        continue
                    }
                    val ext = name.substringAfterLast('.', "").lowercase()
                    if (!mime.startsWith("audio/") && ext !in audioExt) continue
                    val m = HashMap<String, Any?>()
                    m["uri"] = DocumentsContract.buildDocumentUriUsingTree(tree, id).toString()
                    m["displayName"] = name
                    m["size"] = if (c.isNull(3)) 0L else c.getLong(3)
                    m["dateModified"] = if (c.isNull(4)) 0L else c.getLong(4) / 1000
                    m["mime"] = mime
                    m["relativePath"] = rel
                    documentIdToPath(id)?.let { m["path"] = it }
                    rows.add(m)
                }
            }
            for ((id, r) in subdirs) walk(id, r)
        }
        walk(rootId, "")
        return rows
    }

    /** "primary:Music/a.mp3" -> /storage/emulated/0/Music/a.mp3 so SAF items dedupe with MediaStore. */
    private fun documentIdToPath(docId: String): String? {
        val volume = docId.substringBefore(':', "")
        val rel = docId.substringAfter(':', "")
        if (volume.isEmpty()) return null
        return if (volume == "primary") "${Environment.getExternalStorageDirectory().absolutePath}/$rel"
        else "/storage/$volume/$rel"
    }

    // ---------------------------------------------------------- write/delete

    private fun insertAudio(src: File, displayName: String, relativeDir: String, mime: String): Map<String, Any?> {
        val cleanDir = relativeDir.trim('/').ifEmpty { "MusicPlayer" }
        if (Build.VERSION.SDK_INT >= 29) {
            val values = ContentValues().apply {
                put(MediaStore.Audio.Media.DISPLAY_NAME, displayName)
                put(MediaStore.Audio.Media.MIME_TYPE, mime)
                put(MediaStore.Audio.Media.RELATIVE_PATH, "${Environment.DIRECTORY_MUSIC}/$cleanDir")
                put(MediaStore.Audio.Media.IS_PENDING, 1)
            }
            val resolver = context.contentResolver
            val uri = resolver.insert(audioCollection, values)
                ?: throw PlatformError("insert_failed", "MediaStore refused $displayName")
            try {
                resolver.openOutputStream(uri)!!.use { o -> src.inputStream().use { it.copyTo(o) } }
                values.clear()
                values.put(MediaStore.Audio.Media.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            } catch (e: Throwable) {
                resolver.delete(uri, null, null)
                throw e
            }
            var path: String? = null
            var name = displayName
            resolver.query(
                uri, arrayOf(MediaStore.Audio.Media.DATA, MediaStore.Audio.Media.DISPLAY_NAME), null, null, null,
            )?.use { c -> if (c.moveToFirst()) { path = c.getString(0); name = c.getString(1) ?: name } }
            return mapOf("uri" to uri.toString(), "path" to path, "displayName" to name)
        }
        @Suppress("DEPRECATION")
        val root = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MUSIC)
        val dir = File(root, cleanDir).apply { mkdirs() }
        var target = File(dir, displayName)
        var n = 1
        while (target.exists()) {
            target = File(dir, "${displayName.substringBeforeLast('.')} ($n).${displayName.substringAfterLast('.')}")
            n++
        }
        src.copyTo(target)
        MediaScannerConnection.scanFile(context, arrayOf(target.absolutePath), arrayOf(mime), null)
        return mapOf("uri" to Uri.fromFile(target).toString(), "path" to target.absolutePath, "displayName" to target.name)
    }

    /** Renames/moves an audio file this app owns (used to organise downloads by tags). */
    private fun moveAudio(uri: String, relativeDir: String, displayName: String): Map<String, Any?> {
        val cleanDir = relativeDir.trim('/').ifEmpty { "MusicPlayer" }
        val resolver = context.contentResolver
        val target = Uri.parse(uri)
        if (Build.VERSION.SDK_INT >= 29) {
            val values = ContentValues().apply {
                put(MediaStore.Audio.Media.DISPLAY_NAME, displayName)
                put(MediaStore.Audio.Media.RELATIVE_PATH, "${Environment.DIRECTORY_MUSIC}/$cleanDir")
            }
            val updated = try {
                resolver.update(target, values, null, null)
            } catch (e: SecurityException) {
                throw PlatformError("needs_permission", e.message ?: "Move denied")
            } catch (e: Exception) {
                throw PlatformError("move_failed", e.message ?: e.toString())
            }
            if (updated <= 0) throw PlatformError("move_failed", "MediaStore did not update $displayName")
            var path: String? = null
            var name = displayName
            resolver.query(
                target, arrayOf(MediaStore.Audio.Media.DATA, MediaStore.Audio.Media.DISPLAY_NAME), null, null, null,
            )?.use { c -> if (c.moveToFirst()) { path = c.getString(0); name = c.getString(1) ?: name } }
            return mapOf("uri" to uri, "path" to path, "displayName" to name)
        }
        var oldPath: String? = null
        resolver.query(target, arrayOf(MediaStore.Audio.Media.DATA), null, null, null)?.use { c ->
            if (c.moveToFirst()) oldPath = c.getString(0)
        }
        val from = File(oldPath ?: throw PlatformError("not_found", "Unknown file"))
        @Suppress("DEPRECATION")
        val root = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MUSIC)
        val dir = File(root, cleanDir).apply { mkdirs() }
        var dest = File(dir, displayName)
        var n = 1
        while (dest.exists() && dest.absolutePath != from.absolutePath) {
            dest = File(dir, "${displayName.substringBeforeLast('.')} ($n).${displayName.substringAfterLast('.')}")
            n++
        }
        if (dest.absolutePath != from.absolutePath && !from.renameTo(dest)) {
            from.copyTo(dest, overwrite = false); from.delete()
        }
        MediaScannerConnection.scanFile(context, arrayOf(from.absolutePath, dest.absolutePath), null, null)
        return mapOf("uri" to uri, "path" to dest.absolutePath, "displayName" to dest.name)
    }

    private fun deleteAudio(uri: String): Boolean {
        return try {
            if (uri.startsWith("file:")) File(Uri.parse(uri).path!!).delete()
            else context.contentResolver.delete(Uri.parse(uri), null, null) > 0
        } catch (e: SecurityException) {
            throw PlatformError("needs_permission", e.message ?: "Delete denied")
        }
    }

    private fun requestWrite(uris: List<String>, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 30) return result.success(true)
        val act = activity ?: return result.error("no_activity", "No foreground activity", null)
        if (writeResult != null) return result.error("busy", "A request is already open", null)
        writeResult = result
        val sender = MediaStore.createWriteRequest(context.contentResolver, uris.map { Uri.parse(it) }).intentSender
        act.startIntentSenderForResult(sender, REQ_WRITE, null, 0, 0, 0)
    }

    // ------------------------------------------------------------- results

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        when (requestCode) {
            REQ_PICK_TREE -> {
                val r = pickResult ?: return true
                pickResult = null
                val uri = data?.data
                if (resultCode == Activity.RESULT_OK && uri != null) {
                    context.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    r.success(mapOf("uri" to uri.toString(), "name" to folderName(uri)))
                } else r.success(null)
                return true
            }
            REQ_WRITE -> {
                val r = writeResult ?: return true
                writeResult = null
                r.success(resultCode == Activity.RESULT_OK)
                return true
            }
        }
        return false
    }

    // --------------------------------------------------------------- events

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        val sink = events ?: return
        observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) { sink.success("changed") }
        }
        context.contentResolver.registerContentObserver(audioCollection, true, observer!!)
    }

    override fun onCancel(arguments: Any?) {
        observer?.let { context.contentResolver.unregisterContentObserver(it) }
        observer = null
    }

    companion object {
        const val REQ_PICK_TREE = 4711
        const val REQ_WRITE = 4712
    }
}
