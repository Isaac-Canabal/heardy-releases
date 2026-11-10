package com.heardy.app

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Bucle de decodificación compartido por la onda del seek bar
 * ([WaveformExtractor]) y el Mix DJ ([MixCodec]): MediaExtractor + MediaCodec
 * sobre content:// o una ruta. El formato de salida (frecuencia, canales y
 * KEY_PCM_ENCODING) se lee del decodificador, no de la pista: con HE-AAC la
 * frecuencia de la pista no es la que sale.
 */
object AudioDecodeLoop {
    private const val TIMEOUT_US = 10_000L

    class Output(val durationUs: Long) {
        var sampleRate = 0
        var channels = 0
        var encoding = AudioFormat.ENCODING_PCM_16BIT
    }

    class Cancelled : Exception()

    /**
     * Devuelve null si no hay pista de audio, si su duración no está en
     * (0, [maxDurationUs]] o si no se pudo abrir. Lanza [Cancelled] si
     * [isCancelled] da true y cualquier otro error del códec.
     */
    fun run(
        context: Context,
        uriString: String,
        maxDurationUs: Long,
        isCancelled: () -> Boolean = { false },
        onPcm: (ByteBuffer, MediaCodec.BufferInfo, Output) -> Unit,
    ): Output? {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            val uri = Uri.parse(uriString)
            if (uri.scheme == null || uri.scheme == "file") {
                extractor.setDataSource(uri.path ?: uriString)
            } else {
                extractor.setDataSource(context, uri, null)
            }
            var trackIndex = -1
            var format: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("audio/")) {
                    trackIndex = i
                    format = f
                    break
                }
            }
            if (trackIndex < 0 || format == null) return null
            if (!format.containsKey(MediaFormat.KEY_DURATION)) return null
            val durationUs = format.getLong(MediaFormat.KEY_DURATION)
            if (durationUs <= 0 || durationUs > maxDurationUs) return null

            extractor.selectTrack(trackIndex)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: return null
            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()

            val out = Output(durationUs)
            readFormat(format, out)
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            while (true) {
                if (isCancelled()) throw Cancelled()
                if (!inputDone) {
                    val inIndex = codec.dequeueInputBuffer(TIMEOUT_US)
                    if (inIndex >= 0) {
                        val inBuf = codec.getInputBuffer(inIndex)
                        val size = if (inBuf != null) extractor.readSampleData(inBuf, 0) else -1
                        if (size < 0) {
                            codec.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val outIndex = codec.dequeueOutputBuffer(info, TIMEOUT_US)
                when {
                    outIndex >= 0 -> {
                        val outBuf = codec.getOutputBuffer(outIndex)
                        if (outBuf != null && info.size > 0) {
                            outBuf.position(info.offset)
                            outBuf.limit(info.offset + info.size)
                            onPcm(outBuf.slice().order(ByteOrder.nativeOrder()), info, out)
                        }
                        codec.releaseOutputBuffer(outIndex, false)
                        if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break
                    }
                    outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> readFormat(codec.outputFormat, out)
                }
            }
            return out
        } finally {
            try { codec?.stop() } catch (_: Exception) {}
            try { codec?.release() } catch (_: Exception) {}
            try { extractor.release() } catch (_: Exception) {}
        }
    }

    private fun readFormat(f: MediaFormat, out: Output) {
        if (f.containsKey(MediaFormat.KEY_SAMPLE_RATE)) out.sampleRate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        if (f.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
            out.channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT).coerceAtLeast(1)
        }
        if (f.containsKey(MediaFormat.KEY_PCM_ENCODING)) out.encoding = f.getInteger(MediaFormat.KEY_PCM_ENCODING)
    }

    fun bytesPerSample(encoding: Int): Int = when (encoding) {
        AudioFormat.ENCODING_PCM_8BIT -> 1
        AudioFormat.ENCODING_PCM_FLOAT -> 4
        ENCODING_PCM_24BIT_PACKED -> 3
        ENCODING_PCM_32BIT -> 4
        else -> 2
    }

    /** Muestra [index] (contando todos los canales) de [buf] en -1..1. */
    fun sample(buf: ByteBuffer, index: Int, encoding: Int): Float = when (encoding) {
        AudioFormat.ENCODING_PCM_FLOAT -> buf.getFloat(index * 4)
        AudioFormat.ENCODING_PCM_8BIT -> ((buf.get(index).toInt() and 0xff) - 128) / 128f
        ENCODING_PCM_24BIT_PACKED -> {
            val o = index * 3
            val v = (buf.get(o).toInt() and 0xff) or ((buf.get(o + 1).toInt() and 0xff) shl 8) or
                (buf.get(o + 2).toInt() shl 16)
            v / 8388608f
        }
        ENCODING_PCM_32BIT -> buf.getInt(index * 4) / 2147483648f
        else -> buf.getShort(index * 2) / 32768f
    }

    // AudioFormat.ENCODING_PCM_24BIT_PACKED / _32BIT (API 31), por valor para
    // poder compilar contra minSdk menores.
    private const val ENCODING_PCM_24BIT_PACKED = 21
    private const val ENCODING_PCM_32BIT = 22
}
