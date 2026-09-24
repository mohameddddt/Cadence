package dev.personal.musicplayer

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.system.ErrnoException
import android.system.OsConstants
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.IOException

/**
 * Tag reading/writing/artwork. Sources are either absolute paths or content:// URIs.
 * Reading prefers the path (fast); writing works on a temp copy and streams the result
 * back so that it also works for MediaStore/SAF documents.
 */
class TagsPlugin(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {

    init {
        MethodChannel(messenger, "dev.personal.musicplayer/tags").setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        val uri = call.argument<String>("uri")
        when (call.method) {
            "read" -> Background.run(result) { read(path, uri) }
            "write" -> {
                @Suppress("UNCHECKED_CAST")
                val values = (call.argument<Map<String, Any?>>("values") ?: emptyMap())
                val art = call.argument<String>("artPath")
                val clearArt = call.argument<Boolean>("clearArt") ?: false
                Background.run(result) { write(path, uri, values, art, clearArt) }
            }
            "extractArt" -> {
                val out = call.argument<String>("out") ?: return result.error("args", "out", null)
                Background.run(result) { extractArt(path, uri, out) }
            }
            "stat" -> Background.run(result) { stat(path, uri) }
            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------------ read

    private fun read(path: String?, uri: String?): Map<String, Any?> {
        val ext = extensionOf(path, uri)
        try {
            return withReadableFile(path, uri, ext) { f -> TagIO.read(f, ext) }
        } catch (e: PlatformError) {
            throw e
        } catch (e: Throwable) {
            // jaudiotagger can't parse everything (Opus, exotic containers): fall back to the
            // platform retriever so at least the basics show up.
            return retrieverFallback(path, uri) ?: throw e
        }
    }

    private fun retrieverFallback(path: String?, uri: String?): Map<String, Any?>? {
        val r = MediaMetadataRetriever()
        try {
            if (path != null && File(path).canRead()) r.setDataSource(path)
            else if (uri != null) r.setDataSource(context, Uri.parse(uri))
            else return null
            fun s(k: Int) = r.extractMetadata(k)?.trim()?.takeIf { it.isNotEmpty() }
            val m = HashMap<String, Any?>()
            s(MediaMetadataRetriever.METADATA_KEY_TITLE)?.let { m["title"] = it }
            s(MediaMetadataRetriever.METADATA_KEY_ARTIST)?.let { m["artist"] = it }
            s(MediaMetadataRetriever.METADATA_KEY_ALBUM)?.let { m["album"] = it }
            s(MediaMetadataRetriever.METADATA_KEY_ALBUMARTIST)?.let { m["albumArtist"] = it }
            s(MediaMetadataRetriever.METADATA_KEY_GENRE)?.let { m["genre"] = it }
            s(MediaMetadataRetriever.METADATA_KEY_YEAR)?.let { m["date"] = it }
            s(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()?.let { m["durationMs"] = it }
            s(MediaMetadataRetriever.METADATA_KEY_BITRATE)?.toLongOrNull()?.let { m["bitrate"] = it / 1000 }
            s(MediaMetadataRetriever.METADATA_KEY_CD_TRACK_NUMBER)?.let {
                it.substringBefore('/').toIntOrNull()?.let { n -> m["trackNo"] = n }
            }
            s(MediaMetadataRetriever.METADATA_KEY_DISC_NUMBER)?.let {
                it.substringBefore('/').toIntOrNull()?.let { n -> m["discNo"] = n }
            }
            s(MediaMetadataRetriever.METADATA_KEY_MIMETYPE)?.let { m["format"] = it }
            m["hasArt"] = r.embeddedPicture != null
            m["fallback"] = true
            return m
        } catch (_: Throwable) {
            return null
        } finally {
            try { r.release() } catch (_: Throwable) {}
        }
    }

    // ----------------------------------------------------------------- write

    private fun write(
        path: String?, uri: String?, values: Map<String, Any?>, artPath: String?, clearArt: Boolean,
    ): Map<String, Any?> {
        val ext = extensionOf(path, uri)
        if (ext == "opus") {
            throw PlatformError("unsupported_format", "Writing tags to Opus files is not supported")
        }
        val tmpDir = File(context.cacheDir, "tagwrite").apply { mkdirs() }
        val tmp = File(tmpDir, "${System.nanoTime()}.${ext ?: "bin"}")
        try {
            copyIn(path, uri, tmp)
            try {
                TagIO.write(tmp, ext, values, artPath?.let { File(it) }, clearArt)
            } catch (e: Throwable) {
                throw PlatformError("tag_write_failed", e.message ?: e.toString())
            }
            copyOut(path, uri, tmp)
            return stat(path, uri)
        } finally {
            tmp.delete()
        }
    }

    private fun copyIn(path: String?, uri: String?, dest: File) {
        val input = when {
            path != null && File(path).canRead() -> File(path).inputStream()
            uri != null -> context.contentResolver.openInputStream(Uri.parse(uri))
            else -> null
        } ?: throw PlatformError("not_found", "Cannot open source")
        input.use { i -> FileOutputStream(dest).use { o -> i.copyTo(o) } }
    }

    private fun copyOut(path: String?, uri: String?, src: File) {
        try {
            if (uri != null) {
                // "wt" truncates: the tagged copy can be shorter or longer than the original.
                val out = context.contentResolver.openOutputStream(Uri.parse(uri), "wt")
                    ?: throw PlatformError("not_found", "Cannot open target")
                out.use { o -> src.inputStream().use { it.copyTo(o) } }
            } else if (path != null) {
                src.inputStream().use { i -> FileOutputStream(File(path)).use { o -> i.copyTo(o) } }
            }
        } catch (e: SecurityException) {
            throw PlatformError("needs_permission", e.message ?: "Write access denied")
        } catch (e: IOException) {
            if (isPermissionDenied(e)) throw PlatformError("needs_permission", e.message ?: "Write access denied")
            throw e
        }
    }

    private fun isPermissionDenied(e: IOException): Boolean {
        val cause = e.cause
        if (cause is ErrnoException) {
            return cause.errno == OsConstants.EACCES || cause.errno == OsConstants.EPERM ||
                cause.errno == OsConstants.EROFS
        }
        val msg = e.message ?: return false
        return msg.contains("EACCES") || msg.contains("EPERM") || msg.contains("Permission denied") ||
            msg.contains("Operation not permitted") || msg.contains("Read-only file system")
    }

    // ------------------------------------------------------------ art / stat

    private fun extractArt(path: String?, uri: String?, out: String): Boolean {
        val r = MediaMetadataRetriever()
        try {
            if (path != null && File(path).canRead()) r.setDataSource(path)
            else if (uri != null) r.setDataSource(context, Uri.parse(uri))
            else return false
            val bytes = r.embeddedPicture ?: return false
            File(out).parentFile?.mkdirs()
            File(out).writeBytes(bytes)
            return true
        } finally {
            try { r.release() } catch (_: Throwable) {}
        }
    }

    private fun stat(path: String?, uri: String?): Map<String, Any?> {
        if (path != null && File(path).exists()) {
            val f = File(path)
            return mapOf("size" to f.length(), "lastModified" to f.lastModified() / 1000)
        }
        if (uri != null) {
            context.contentResolver.query(
                Uri.parse(uri), arrayOf(OpenableColumns.SIZE, "last_modified", "date_modified"),
                null, null, null,
            )?.use { c ->
                if (c.moveToFirst()) {
                    val size = c.getColumnIndex(OpenableColumns.SIZE).let { if (it >= 0) c.getLong(it) else 0L }
                    var mod = 0L
                    val lm = c.getColumnIndex("last_modified")
                    val dm = c.getColumnIndex("date_modified")
                    if (lm >= 0 && !c.isNull(lm)) mod = c.getLong(lm) / 1000
                    else if (dm >= 0 && !c.isNull(dm)) mod = c.getLong(dm)
                    return mapOf("size" to size, "lastModified" to mod)
                }
            }
        }
        return mapOf("size" to 0L, "lastModified" to 0L)
    }

    // -------------------------------------------------------------- helpers

    private fun extensionOf(path: String?, uri: String?): String? {
        path?.substringAfterLast('.', "")?.lowercase()?.takeIf { it.length in 2..5 && !it.contains('/') }
            ?.let { return it }
        if (uri != null) {
            try {
                context.contentResolver.query(
                    Uri.parse(uri), arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null,
                )?.use { c ->
                    if (c.moveToFirst()) {
                        c.getString(0)?.substringAfterLast('.', "")?.lowercase()
                            ?.takeIf { it.isNotEmpty() }?.let { return it }
                    }
                }
            } catch (_: Throwable) {}
            val mime = context.contentResolver.getType(Uri.parse(uri))
            return when (mime) {
                "audio/mpeg", "audio/mp3" -> "mp3"
                "audio/flac", "audio/x-flac" -> "flac"
                "audio/mp4", "audio/x-m4a", "audio/aac" -> "m4a"
                "audio/ogg", "application/ogg" -> "ogg"
                "audio/opus" -> "opus"
                "audio/wav", "audio/x-wav" -> "wav"
                else -> null
            }
        }
        return null
    }

    private fun <T> withReadableFile(path: String?, uri: String?, ext: String?, block: (File) -> T): T {
        if (path != null && File(path).canRead()) return block(File(path))
        if (uri != null) {
            // Random access straight from the descriptor, no temp copy.
            val pfd = context.contentResolver.openFileDescriptor(Uri.parse(uri), "r")
                ?: throw PlatformError("not_found", "Cannot open $uri")
            pfd.use { return block(File("/proc/self/fd/${it.fd}")) }
        }
        throw PlatformError("not_found", "No readable source")
    }
}
