package com.heardy.ytstream

import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import com.heardy.ytstream.potoken.BadWebViewException
import com.heardy.ytstream.potoken.PoTokenException
import com.heardy.ytstream.potoken.PoTokenProviderImpl
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import org.schabi.newpipe.extractor.MediaFormat
import org.schabi.newpipe.extractor.NewPipe
import org.schabi.newpipe.extractor.ServiceList
import org.schabi.newpipe.extractor.exceptions.ContentNotAvailableException
import org.schabi.newpipe.extractor.localization.Localization
import org.schabi.newpipe.extractor.services.youtube.YoutubeParsingHelper
import org.schabi.newpipe.extractor.services.youtube.extractors.YoutubeStreamExtractor
import org.schabi.newpipe.extractor.stream.AudioStream
import org.schabi.newpipe.extractor.stream.AudioTrackType
import org.schabi.newpipe.extractor.stream.DeliveryMethod

class HeardyYtStreamPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private val mainHandler = Handler(Looper.getMainLooper())
    private var executor: ExecutorService? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        PoTokenProviderImpl.appContext = binding.applicationContext
        ensureExtractorInitialized()
        executor = Executors.newSingleThreadExecutor()
        channel = MethodChannel(binding.binaryMessenger, "heardy_yt_stream")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        executor?.shutdown()
        executor = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "resolve") {
            result.notImplemented()
            return
        }
        val videoId = call.argument<String>("videoId")
        if (videoId.isNullOrBlank() || !VIDEO_ID.matches(videoId)) {
            result.error(CODE_EXTRACTION, "invalid videoId", null)
            return
        }
        val worker = executor ?: run {
            result.error(CODE_EXTRACTION, "plugin detached", null)
            return
        }
        worker.execute {
            val outcome = try {
                Result.success(resolve(videoId))
            } catch (t: Throwable) {
                Result.failure(t)
            }
            mainHandler.post {
                outcome.fold(
                    onSuccess = { result.success(it) },
                    onFailure = { t ->
                        val code = errorCode(t)
                        Log.w(TAG, "resolve($videoId) failed: $code ${t.javaClass.simpleName}")
                        result.error(code, safeMessage(t), null)
                    }
                )
            }
        }
    }

    private fun resolve(videoId: String): Map<String, Any?> {
        val started = SystemClock.elapsedRealtime()
        val extractor = ServiceList.YouTube.getStreamExtractor("https://www.youtube.com/watch?v=$videoId")
        extractor.fetchPage()
        val stream = pickAudioStream(extractor.audioStreams)
            ?: throw ContentNotAvailableException("no progressive audio-only stream")
        val url = stream.content
        val parsed = Uri.parse(url)
        val client = clientOf(url)
        Log.d(
            TAG,
            "resolve($videoId): itag=${stream.itag} format=${stream.format?.name} " +
                "kbps=${stream.averageBitrate} client=$client pot=${parsed.getQueryParameter("pot") != null} " +
                "in ${SystemClock.elapsedRealtime() - started} ms"
        )
        val contentLength = stream.itagItem?.contentLength?.takeIf { it > 0 }
            ?: parsed.getQueryParameter("clen")?.toLongOrNull()
        return mapOf(
            "url" to url,
            "mimeType" to (stream.format?.mimeType ?: "audio/mp4"),
            "itag" to stream.itag,
            "bitrateKbps" to stream.averageBitrate.takeIf { it > 0 }?.toDouble(),
            "contentLength" to contentLength,
            "expiresAt" to parsed.getQueryParameter("expire")?.toLongOrNull(),
            "durationSeconds" to extractor.length,
            "httpHeaders" to playbackHeaders(url),
        )
    }

    companion object {
        private const val TAG = "HeardyYtStream"
        private const val CODE_UNAVAILABLE = "unavailable"
        private const val CODE_EXTRACTION = "extraction_failed"
        private const val CODE_PO_TOKEN = "po_token_failed"
        private val VIDEO_ID = Regex("^[A-Za-z0-9_-]{11}$")

        @Volatile
        private var initialized = false

        @Synchronized
        private fun ensureExtractorInitialized() {
            if (initialized) return
            NewPipe.init(DownloaderImpl.getInstance(), Localization.DEFAULT)
            YoutubeStreamExtractor.setPoTokenProvider(PoTokenProviderImpl)
            initialized = true
        }

        /** Original-language, progressive, audio-only; itag 140 (AAC) first, then M4A, then bitrate. */
        internal fun pickAudioStream(streams: List<AudioStream>): AudioStream? =
            streams
                .filter { it.isUrl && it.deliveryMethod == DeliveryMethod.PROGRESSIVE_HTTP }
                .filter {
                    it.audioTrackType == null || it.audioTrackType == AudioTrackType.ORIGINAL
                }
                .sortedWith(
                    compareByDescending<AudioStream> { it.itag == 140 }
                        .thenByDescending { it.format == MediaFormat.M4A }
                        .thenByDescending { it.averageBitrate }
                )
                .firstOrNull()

        /** Same User-Agent choice as NewPipe's YoutubeHttpDataSource. */
        private fun playbackHeaders(url: String): Map<String, String> {
            val userAgent = when {
                YoutubeParsingHelper.isAndroidStreamingUrl(url) ->
                    YoutubeParsingHelper.getAndroidUserAgent(null)
                YoutubeParsingHelper.isIosStreamingUrl(url) ->
                    YoutubeParsingHelper.getIosUserAgent(null)
                YoutubeParsingHelper.isVisionOsStreamingUrl(url) ->
                    YoutubeParsingHelper.getVisionOsUserAgent(null)
                else -> DownloaderImpl.USER_AGENT
            }
            val headers = mutableMapOf("User-Agent" to userAgent)
            if (YoutubeParsingHelper.isWebStreamingUrl(url)) {
                headers["Origin"] = "https://www.youtube.com"
                headers["Referer"] = "https://www.youtube.com"
            }
            return headers
        }

        private fun clientOf(url: String): String = when {
            YoutubeParsingHelper.isAndroidStreamingUrl(url) -> "android"
            YoutubeParsingHelper.isIosStreamingUrl(url) -> "ios"
            YoutubeParsingHelper.isVisionOsStreamingUrl(url) -> "visionos"
            YoutubeParsingHelper.isWebStreamingUrl(url) -> "web"
            else -> "other"
        }

        private fun errorCode(t: Throwable): String {
            var cause: Throwable? = t
            while (cause != null) {
                when (cause) {
                    is ContentNotAvailableException -> return CODE_UNAVAILABLE
                    is PoTokenException, is BadWebViewException -> return CODE_PO_TOKEN
                }
                cause = cause.cause
            }
            return CODE_EXTRACTION
        }

        // Extractor messages can quote request URLs; never forward them.
        private fun safeMessage(t: Throwable): String =
            (t.message ?: t.javaClass.simpleName)
                .replace(Regex("https?://\\S+"), "<url>")
                .take(200)
    }
}
