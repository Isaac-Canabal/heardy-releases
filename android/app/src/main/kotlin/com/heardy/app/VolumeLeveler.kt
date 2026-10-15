package com.heardy.app

import android.media.audiofx.AudioEffect
import android.media.audiofx.DynamicsProcessing
import android.media.audiofx.LoudnessEnhancer
import android.os.Build
import android.util.Log

/**
 * "Estabilizar audio": nivelador suave sobre la sesión de audio del reproductor.
 * Con API 28+ usa DynamicsProcessing (compresor de una banda + limitador de
 * salida a -2 dBFS); si no existe o falla al engancharse, cae a LoudnessEnhancer
 * con una ganancia modesta. Una sola instancia viva a la vez: cada `enable` con
 * otra sesión (el reproductor se recrea) libera la anterior.
 */
class VolumeLeveler {
    private var effect: AudioEffect? = null
    private var sessionId = 0

    @Synchronized
    fun enable(newSessionId: Int): String? {
        if (newSessionId <= 0) return null
        if (effect != null && sessionId == newSessionId) return engineName(effect)
        release()
        sessionId = newSessionId
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                effect = buildDynamics(newSessionId)
                return "dynamics"
            } catch (t: Throwable) {
                Log.w(TAG, "DynamicsProcessing no disponible: ${t.javaClass.simpleName}")
                release()
                sessionId = newSessionId
            }
        }
        return try {
            val loudness = LoudnessEnhancer(newSessionId)
            loudness.setTargetGain(FALLBACK_GAIN_MB)
            loudness.enabled = true
            effect = loudness
            "loudness"
        } catch (t: Throwable) {
            Log.w(TAG, "LoudnessEnhancer no disponible: ${t.javaClass.simpleName}")
            release()
            null
        }
    }

    @Synchronized
    fun disable() {
        release()
    }

    private fun release() {
        try {
            effect?.enabled = false
            effect?.release()
        } catch (_: Throwable) {
        }
        effect = null
        sessionId = 0
    }

    private fun engineName(e: AudioEffect?): String? = when (e) {
        is DynamicsProcessing -> "dynamics"
        is LoudnessEnhancer -> "loudness"
        else -> null
    }

    private fun buildDynamics(session: Int): DynamicsProcessing {
        val channels = 2
        val builder = DynamicsProcessing.Config.Builder(
            DynamicsProcessing.VARIANT_FAVOR_TIME_RESOLUTION,
            channels,
            false, 0,
            true, 1,
            false, 0,
            true,
        )
        for (ch in 0 until channels) {
            val mbc = DynamicsProcessing.Mbc(true, true, 1)
            mbc.setBand(
                0,
                DynamicsProcessing.MbcBand(
                    true,
                    20000f,
                    MBC_ATTACK_MS,
                    MBC_RELEASE_MS,
                    MBC_RATIO,
                    MBC_THRESHOLD_DB,
                    MBC_KNEE_DB,
                    -90f,
                    1f,
                    0f,
                    MBC_POST_GAIN_DB,
                ),
            )
            builder.setMbcByChannelIndex(ch, mbc)
            builder.setLimiterByChannelIndex(
                ch,
                DynamicsProcessing.Limiter(
                    true, true, 0,
                    LIMITER_ATTACK_MS,
                    LIMITER_RELEASE_MS,
                    LIMITER_RATIO,
                    LIMITER_THRESHOLD_DB,
                    0f,
                ),
            )
        }
        val dp = DynamicsProcessing(0, session, builder.build())
        dp.enabled = true
        return dp
    }

    private companion object {
        const val TAG = "VolumeLeveler"
        const val FALLBACK_GAIN_MB = 400
        const val MBC_ATTACK_MS = 15f
        const val MBC_RELEASE_MS = 200f
        const val MBC_RATIO = 2f
        const val MBC_THRESHOLD_DB = -24f
        const val MBC_KNEE_DB = 12f
        const val MBC_POST_GAIN_DB = 4f
        const val LIMITER_ATTACK_MS = 1f
        const val LIMITER_RELEASE_MS = 60f
        const val LIMITER_RATIO = 10f
        const val LIMITER_THRESHOLD_DB = -2f
    }
}
