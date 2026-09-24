package dev.personal.musicplayer

import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Decodes any audio file the platform can play into raw signed 16-bit little-endian PCM.
 * Dart uses that for Chromaprint fingerprints and loudness (ReplayGain) analysis, both of
 * which are implemented in Dart so they can be unit tested off-device.
 */
class AudioDecoder(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {

    init {
        MethodChannel(messenger, "dev.personal.musicplayer/decoder").setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "decode") return result.notImplemented()
        val path = call.argument<String>("path")
        val uri = call.argument<String>("uri")
        val out = call.argument<String>("out") ?: return result.error("args", "out", null)
        val rate = call.argument<Int>("sampleRate") ?: 0 // 0 = keep the source rate
        val channels = call.argument<Int>("channels") ?: 1
        val maxSeconds = call.argument<Int>("maxSeconds") ?: 0 // 0 = whole file
        Background.run(result) { decode(path, uri, File(out), rate, channels, maxSeconds) }
    }

    private fun decode(
        path: String?, uri: String?, out: File, targetRate: Int, targetChannels: Int, maxSeconds: Int,
    ): Map<String, Any?> {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            if (path != null && File(path).canRead()) extractor.setDataSource(path)
            else if (uri != null) extractor.setDataSource(context, Uri.parse(uri), null)
            else throw PlatformError("not_found", "No readable source")

            var track = -1
            var format: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                if ((f.getString(MediaFormat.KEY_MIME) ?: "").startsWith("audio/")) {
                    track = i; format = f; break
                }
            }
            if (track < 0 || format == null) throw PlatformError("no_audio", "No audio track")
            extractor.selectTrack(track)

            codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
            codec.configure(format, null, null, 0)
            codec.start()

            var srcRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var srcChannels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            val outRate = if (targetRate > 0) targetRate else srcRate
            val outChannels = if (targetChannels >= 2) 2 else 1

            out.parentFile?.mkdirs()
            val stream = BufferedOutputStream(FileOutputStream(out), 1 shl 16)
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            var producedFrames = 0L
            var resamplePos = 0.0 // position in source frames of the next output frame
            var srcFrameBase = 0L // global index of first frame in the current chunk
            var carry: FloatArray? = null // last frame of previous chunk for interpolation
            val maxFrames = if (maxSeconds > 0) maxSeconds.toLong() * outRate else Long.MAX_VALUE

            while (!outputDone && producedFrames < maxFrames) {
                if (!inputDone) {
                    val inIdx = codec.dequeueInputBuffer(10_000)
                    if (inIdx >= 0) {
                        val buf = codec.getInputBuffer(inIdx)!!
                        val n = extractor.readSampleData(buf, 0)
                        if (n < 0) {
                            codec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(inIdx, 0, n, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val outIdx = codec.dequeueOutputBuffer(info, 10_000)
                when {
                    outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val nf = codec.outputFormat
                        if (nf.containsKey(MediaFormat.KEY_SAMPLE_RATE)) srcRate = nf.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        if (nf.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) srcChannels = nf.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    }
                    outIdx >= 0 -> {
                        val buf = codec.getOutputBuffer(outIdx)!!
                        buf.position(info.offset)
                        buf.limit(info.offset + info.size)
                        val shorts = buf.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
                        val frames = shorts.remaining() / srcChannels
                        if (frames > 0) {
                            // Mixdown to float frames of outChannels.
                            val mixed = FloatArray(frames * outChannels)
                            for (fr in 0 until frames) {
                                if (outChannels == 1) {
                                    var s = 0f
                                    for (c in 0 until srcChannels) s += shorts.get(fr * srcChannels + c)
                                    mixed[fr] = s / srcChannels
                                } else {
                                    val l = shorts.get(fr * srcChannels).toFloat()
                                    val r = if (srcChannels > 1) shorts.get(fr * srcChannels + 1).toFloat() else l
                                    mixed[fr * 2] = l
                                    mixed[fr * 2 + 1] = r
                                }
                            }
                            producedFrames += writeResampled(
                                stream, mixed, outChannels, srcRate, outRate,
                                srcFrameBase, resamplePos, carry,
                            ).also {
                                resamplePos = it.nextPos
                                carry = it.carry
                            }.written
                            srcFrameBase += frames
                        }
                        codec.releaseOutputBuffer(outIdx, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                    }
                }
            }
            stream.flush()
            stream.close()
            return mapOf(
                "sampleRate" to outRate,
                "channels" to outChannels,
                "frames" to producedFrames,
                "sourceSampleRate" to srcRate,
            )
        } finally {
            try { codec?.stop() } catch (_: Throwable) {}
            try { codec?.release() } catch (_: Throwable) {}
            extractor.release()
        }
    }

    private class ResampleState(val written: Long, val nextPos: Double, val carry: FloatArray?)

    /** Linear-interpolation resampler working chunk by chunk. Returns frames written. */
    private fun writeResampled(
        out: BufferedOutputStream, chunk: FloatArray, ch: Int, srcRate: Int, outRate: Int,
        chunkBase: Long, startPos: Double, carry: FloatArray?,
    ): ResampleState {
        val frames = chunk.size / ch
        val bb = ByteBuffer.allocate(4096 * 2 * ch + 16).order(ByteOrder.LITTLE_ENDIAN)
        var written = 0L
        var pos = startPos
        val step = srcRate.toDouble() / outRate
        fun sample(idx: Long, c: Int): Float {
            val local = (idx - chunkBase).toInt()
            return if (local < 0) (carry?.get(c) ?: 0f) else chunk[local * ch + c]
        }
        fun flushIfFull() {
            if (bb.remaining() < 2 * ch + 2) {
                out.write(bb.array(), 0, bb.position())
                bb.clear()
            }
        }
        while (true) {
            val i0 = Math.floor(pos).toLong()
            if (i0 + 1 >= chunkBase + frames) break
            val frac = (pos - i0).toFloat()
            for (c in 0 until ch) {
                val a = sample(i0, c)
                val b = sample(i0 + 1, c)
                val v = (a + (b - a) * frac).coerceIn(-32768f, 32767f)
                bb.putShort(v.toInt().toShort())
            }
            written++
            pos += step
            flushIfFull()
        }
        out.write(bb.array(), 0, bb.position())
        val last = FloatArray(ch) { c -> chunk[(frames - 1) * ch + c] }
        return ResampleState(written, pos, last)
    }
}
