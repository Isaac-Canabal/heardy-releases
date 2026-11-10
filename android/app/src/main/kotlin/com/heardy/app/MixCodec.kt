package com.heardy.app

import android.content.Context
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * Códec del Mix DJ (canal `heardy/mix`). Todo lo que escribe va a rutas
 * privadas de la app que elige Dart; la entrada de [decode] puede ser un
 * content:// del usuario, que solo abre MediaExtractor.
 */
object MixCodec {
    // Mismo tope que la onda: no se decodifican horas de audio.
    private const val MAX_DURATION_US = 30L * 60L * 1_000_000L
    private const val TIMEOUT_US = 10_000L
    private const val SAMPLE_RATE = 44_100
    private const val CHANNELS = 2

    private val cancelFlags = ConcurrentHashMap<String, AtomicBoolean>()

    fun cancel(job: String) {
        cancelFlags.getOrPut(job) { AtomicBoolean() }.set(true)
    }

    private fun flag(job: String) = cancelFlags.getOrPut(job) { AtomicBoolean() }

    fun finish(job: String) {
        cancelFlags.remove(job)
    }

    /**
     * Decodifica a float32 little-endian intercalado, con la frecuencia y los
     * canales del decodificador (Dart pasa a estéreo 44.1 kHz). Devuelve
     * sampleRate, channels y frames.
     */
    fun decode(context: Context, uri: String, outPath: String, job: String): Map<String, Int> {
        val cancelled = flag(job)
        val outFile = File(outPath)
        var frames = 0L
        var fixedRate = 0
        var fixedChannels = 0
        try {
            FileOutputStream(outFile).channel.use { ch ->
                var scratch = ByteBuffer.allocate(0)
                val out = AudioDecodeLoop.run(context, uri, MAX_DURATION_US, { cancelled.get() }) { buf, _, fmt ->
                    if (fmt.sampleRate <= 0 || fmt.channels <= 0) throw IllegalStateException("formato desconocido")
                    if (fixedRate == 0) {
                        fixedRate = fmt.sampleRate
                        fixedChannels = fmt.channels
                    } else if (fixedRate != fmt.sampleRate || fixedChannels != fmt.channels) {
                        throw IllegalStateException("el formato cambió a mitad")
                    }
                    val n = buf.remaining() / AudioDecodeLoop.bytesPerSample(fmt.encoding)
                    if (scratch.capacity() < n * 4) {
                        scratch = ByteBuffer.allocate(n * 4).order(ByteOrder.LITTLE_ENDIAN)
                    }
                    scratch.clear()
                    for (i in 0 until n) scratch.putFloat(AudioDecodeLoop.sample(buf, i, fmt.encoding))
                    scratch.flip()
                    while (scratch.hasRemaining()) ch.write(scratch)
                    frames += n / fmt.channels
                } ?: throw IllegalStateException("sin pista de audio")
                if (fixedRate == 0) {
                    fixedRate = out.sampleRate
                    fixedChannels = out.channels
                }
            }
            return mapOf("sampleRate" to fixedRate, "channels" to fixedChannels, "frames" to frames.toInt())
        } catch (e: Exception) {
            outFile.delete()
            throw e
        } finally {
            finish(job)
        }
    }

    /**
     * Codifica [inPath] (float32 LE estéreo 44.1 kHz) a AAC-LC en MP4 con
     * MediaCodec + MediaMuxer, aplicando [gainDb] y pasando a 16 bits.
     */
    fun encodeAac(inPath: String, outPath: String, bitrate: Int, gainDb: Double, job: String) {
        val cancelled = flag(job)
        val gain = 10.0.pow(gainDb / 20.0).toFloat()
        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, SAMPLE_RATE, CHANNELS).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 1 shl 16)
        }
        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        var muxer: MediaMuxer? = null
        var muxerStarted = false
        val outFile = File(outPath)
        try {
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()
            val mux = MediaMuxer(outPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            muxer = mux
            var track = -1
            val info = MediaCodec.BufferInfo()
            FileInputStream(inPath).channel.use { input ->
                val floats = ByteBuffer.allocate(1 shl 16).order(ByteOrder.LITTLE_ENDIAN)
                var framesIn = 0L
                var inputDone = false
                while (true) {
                    if (cancelled.get()) throw AudioDecodeLoop.Cancelled()
                    if (!inputDone) {
                        val idx = codec.dequeueInputBuffer(TIMEOUT_US)
                        if (idx >= 0) {
                            val dst = codec.getInputBuffer(idx)!!.order(ByteOrder.nativeOrder())
                            dst.clear()
                            // 2 bytes de salida por cada float de entrada.
                            val want = minOf(dst.capacity() / 2, floats.capacity()) / 8 * 8
                            floats.clear()
                            floats.limit(want)
                            var read = 0
                            while (floats.hasRemaining()) {
                                val r = input.read(floats)
                                if (r < 0) break
                                read += r
                            }
                            floats.flip()
                            val samples = read / 4
                            if (samples == 0) {
                                codec.queueInputBuffer(idx, 0, 0, ptsUs(framesIn), MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputDone = true
                            } else {
                                for (i in 0 until samples) {
                                    val v = (floats.getFloat() * gain * 32767f).roundToInt().coerceIn(-32768, 32767)
                                    dst.putShort(v.toShort())
                                }
                                codec.queueInputBuffer(idx, 0, samples * 2, ptsUs(framesIn), 0)
                                framesIn += samples / CHANNELS
                            }
                        }
                    }
                    val outIdx = codec.dequeueOutputBuffer(info, TIMEOUT_US)
                    when {
                        outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            track = mux.addTrack(codec.outputFormat)
                            mux.start()
                            muxerStarted = true
                        }
                        outIdx >= 0 -> {
                            val data = codec.getOutputBuffer(outIdx)
                            val config = (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                            if (data != null && info.size > 0 && !config && muxerStarted) {
                                data.position(info.offset)
                                data.limit(info.offset + info.size)
                                mux.writeSampleData(track, data, info)
                            }
                            codec.releaseOutputBuffer(outIdx, false)
                            if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break
                        }
                    }
                }
            }
            if (!muxerStarted) throw IllegalStateException("el codificador no produjo audio")
        } catch (e: Exception) {
            try { if (muxerStarted) muxer?.stop() } catch (_: Exception) {}
            muxerStarted = false
            outFile.delete()
            throw e
        } finally {
            try { if (muxerStarted) muxer?.stop() } catch (_: Exception) {}
            try { muxer?.release() } catch (_: Exception) {}
            try { codec.stop() } catch (_: Exception) {}
            try { codec.release() } catch (_: Exception) {}
            finish(job)
        }
    }

    private fun ptsUs(frames: Long) = frames * 1_000_000L / SAMPLE_RATE
}
