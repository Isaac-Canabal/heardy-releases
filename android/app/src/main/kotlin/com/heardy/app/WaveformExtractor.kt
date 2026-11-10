package com.heardy.app

import android.content.Context
import kotlin.math.sqrt

/**
 * Decodifica el audio (acepta content:// y rutas) y devuelve [buckets]
 * amplitudes RMS en 0..1 repartidas por tiempo. Devuelve null si falla.
 */
object WaveformExtractor {
    // Tope de seguridad para no decodificar horas de audio.
    private const val MAX_DURATION_US = 30L * 60L * 1_000_000L

    fun extract(context: Context, uriString: String, buckets: Int): DoubleArray? {
        val sumSquares = DoubleArray(buckets)
        val counts = LongArray(buckets)
        try {
            AudioDecodeLoop.run(context, uriString, MAX_DURATION_US) { buf, info, out ->
                val total = buf.remaining() / AudioDecodeLoop.bytesPerSample(out.encoding)
                val bucket = ((info.presentationTimeUs * buckets) / out.durationUs)
                    .toInt().coerceIn(0, buckets - 1)
                // Un frame de cada 4 basta para estimar la energía.
                val stride = out.channels.coerceAtLeast(1) * 4
                var i = 0
                while (i < total) {
                    val s = AudioDecodeLoop.sample(buf, i, out.encoding).toDouble()
                    sumSquares[bucket] += s * s
                    counts[bucket]++
                    i += stride
                }
            } ?: return null
        } catch (e: Exception) {
            return null
        }
        val result = DoubleArray(buckets)
        for (i in 0 until buckets) {
            result[i] = if (counts[i] > 0) sqrt(sumSquares[i] / counts[i]) else 0.0
        }
        return result
    }
}
