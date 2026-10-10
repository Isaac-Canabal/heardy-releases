package com.heardy.app

import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import kotlin.math.sqrt

/**
 * Decodifica el audio (acepta content:// y rutas) y devuelve [buckets]
 * amplitudes RMS en 0..1 repartidas por tiempo. Devuelve null si falla.
 */
object WaveformExtractor {
    private const val TIMEOUT_US = 10_000L
    // Tope de seguridad para no decodificar horas de audio.
    private const val MAX_DURATION_US = 30L * 60L * 1_000_000L

    fun extract(context: Context, uriString: String, buckets: Int): DoubleArray? {
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
            if (durationUs <= 0 || durationUs > MAX_DURATION_US) return null

            extractor.selectTrack(trackIndex)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: return null
            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()

            val sumSquares = DoubleArray(buckets)
            val counts = LongArray(buckets)
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            var channels = if (format.containsKey(MediaFormat.KEY_CHANNEL_COUNT))
                format.getInteger(MediaFormat.KEY_CHANNEL_COUNT) else 2
            if (channels < 1) channels = 1

            while (!outputDone) {
                if (!inputDone) {
                    val inIndex = codec.dequeueInputBuffer(TIMEOUT_US)
                    if (inIndex >= 0) {
                        val inBuf = codec.getInputBuffer(inIndex)
                        val size = if (inBuf != null) extractor.readSampleData(inBuf, 0) else -1
                        if (size < 0) {
                            codec.queueInputBuffer(
                                inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM
                            )
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
                            val shorts = outBuf.asShortBuffer()
                            val total = shorts.remaining()
                            val bucket = ((info.presentationTimeUs * buckets) / durationUs)
                                .toInt().coerceIn(0, buckets - 1)
                            // Un frame de cada 4 basta para estimar la energía.
                            val stride = channels * 4
                            var i = 0
                            while (i < total) {
                                val s = shorts.get(i).toDouble() / 32768.0
                                sumSquares[bucket] += s * s
                                counts[bucket]++
                                i += stride
                            }
                        }
                        codec.releaseOutputBuffer(outIndex, false)
                        if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                            outputDone = true
                        }
                    }
                    outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val out = codec.outputFormat
                        if (out.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                            channels = out.getInteger(MediaFormat.KEY_CHANNEL_COUNT).coerceAtLeast(1)
                        }
                    }
                }
            }

            val result = DoubleArray(buckets)
            for (i in 0 until buckets) {
                result[i] = if (counts[i] > 0) sqrt(sumSquares[i] / counts[i]) else 0.0
            }
            return result
        } catch (e: Exception) {
            return null
        } finally {
            try { codec?.stop() } catch (_: Exception) {}
            try { codec?.release() } catch (_: Exception) {}
            try { extractor.release() } catch (_: Exception) {}
        }
    }
}
