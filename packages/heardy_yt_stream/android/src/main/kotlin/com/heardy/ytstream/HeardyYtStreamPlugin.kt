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
import org.schabi.newpipe.extractor.Image
import org.schabi.newpipe.extractor.MediaFormat
import org.schabi.newpipe.extractor.NewPipe
import org.schabi.newpipe.extractor.ServiceList
import org.schabi.newpipe.extractor.exceptions.ContentNotAvailableException
import org.schabi.newpipe.extractor.exceptions.ParsingException
import org.schabi.newpipe.extractor.localization.Localization
import org.schabi.newpipe.extractor.services.youtube.YoutubeParsingHelper
import org.schabi.newpipe.extractor.search.SearchExtractor
import org.schabi.newpipe.extractor.services.youtube.extractors.YoutubeStreamExtractor
import org.schabi.newpipe.extractor.services.youtube.linkHandler.YoutubeSearchQueryHandlerFactory
import org.schabi.newpipe.extractor.stream.AudioStream
import org.schabi.newpipe.extractor.stream.AudioTrackType
import org.schabi.newpipe.extractor.stream.DeliveryMethod
import org.schabi.newpipe.extractor.stream.StreamInfoItem
import org.schabi.newpipe.extractor.stream.StreamType

/** The caller passed something that is not a video id or a URL of the expected kind. */
class InvalidInputException(message: String) : Exception(message)

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
        when (call.method) {
            "resolve" -> {
                val input = call.argument<String>("input")?.trim().orEmpty()
                runOnWorker("resolve", result) { resolve(videoIdFrom(input)) }
            }
            "search" -> {
                val query = call.argument<String>("query")?.trim().orEmpty()
                val limit = (call.argument<Int>("limit") ?: DEFAULT_SEARCH_LIMIT).coerceIn(1, MAX_SEARCH_LIMIT)
                val music = call.argument<Boolean>("music") ?: false
                runOnWorker("search", result) { search(query, limit, music) }
            }
            "playlist" -> {
                val url = call.argument<String>("url")?.trim().orEmpty()
                val max = (call.argument<Int>("maxEntries") ?: MAX_PLAYLIST_ENTRIES).coerceIn(1, MAX_PLAYLIST_ENTRIES)
                runOnWorker("playlist", result) { playlist(url, max) }
            }
            else -> result.notImplemented()
        }
    }

    private fun runOnWorker(method: String, result: MethodChannel.Result, block: () -> Any?) {
        val worker = executor ?: run {
            result.error(CODE_EXTRACTION, "plugin detached", null)
            return
        }
        worker.execute {
            val outcome = try {
                Result.success(block())
            } catch (t: Throwable) {
                Result.failure(t)
            }
            mainHandler.post {
                outcome.fold(
                    onSuccess = { result.success(it) },
                    onFailure = { t ->
                        val code = errorCode(t)
                        Log.w(TAG, "$method failed: $code ${t.javaClass.simpleName}")
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
            "videoId" to videoId,
            "url" to url,
            "mimeType" to (stream.format?.mimeType ?: "audio/mp4"),
            "itag" to stream.itag,
            "bitrateKbps" to stream.averageBitrate.takeIf { it > 0 }?.toDouble(),
            "contentLength" to contentLength,
            "expiresAt" to parsed.getQueryParameter("expire")?.toLongOrNull(),
            "durationSeconds" to extractor.length,
            "httpHeaders" to playbackHeaders(url),
            "title" to optional { extractor.name },
            "uploader" to optional { extractor.uploaderName },
            "thumbnailUrl" to optional { bestImageUrl(extractor.thumbnails) },
        )
    }

    private fun search(query: String, limit: Int, music: Boolean): List<Map<String, Any?>> {
        if (query.isEmpty()) return emptyList()
        val filter = if (music) YoutubeSearchQueryHandlerFactory.MUSIC_SONGS else YoutubeSearchQueryHandlerFactory.VIDEOS
        val extractor = ServiceList.YouTube.getSearchExtractor(query, listOf(filter), "")
        val out = ArrayList<Map<String, Any?>>()
        try {
            extractor.fetchPage()
            var page = extractor.initialPage
            var pages = 1
            while (true) {
                for (item in page.items) {
                    if (out.size >= limit) break
                    if (item !is StreamInfoItem || !isSearchableVideo(item)) continue
                    itemMap(item)?.let(out::add)
                }
                if (out.size >= limit || !page.hasNextPage() || pages >= MAX_SEARCH_PAGES) break
                page = extractor.getPage(page.nextPage)
                pages++
            }
        } catch (e: SearchExtractor.NothingFoundException) {
            return out
        }
        return out
    }

    private fun playlist(url: String, maxEntries: Int): Map<String, Any?> {
        val handler = try {
            ServiceList.YouTube.playlistLHFactory.fromUrl(url)
        } catch (e: Exception) {
            throw InvalidInputException("not a playlist url")
        }
        val extractor = ServiceList.YouTube.getPlaylistExtractor(handler)
        extractor.fetchPage()
        val entries = ArrayList<Map<String, Any?>>()
        var page = extractor.initialPage
        while (true) {
            for (item in page.items) {
                if (entries.size >= maxEntries) break
                if (isLive(item)) continue
                itemMap(item)?.let(entries::add)
            }
            if (entries.size >= maxEntries || !page.hasNextPage()) break
            page = extractor.getPage(page.nextPage)
        }
        return mapOf(
            "id" to extractor.id,
            "name" to optional { extractor.name },
            "url" to handler.url,
            "entries" to entries,
        )
    }

    companion object {
        private const val TAG = "HeardyYtStream"
        private const val CODE_UNAVAILABLE = "unavailable"
        private const val CODE_EXTRACTION = "extraction_failed"
        private const val CODE_PO_TOKEN = "po_token_failed"
        private const val CODE_INVALID_URL = "invalid_url"
        private const val DEFAULT_SEARCH_LIMIT = 20
        private const val MAX_SEARCH_LIMIT = 200
        private const val MAX_SEARCH_PAGES = 5
        private const val MAX_PLAYLIST_ENTRIES = 10000
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

        /** A bare video id, or the id parsed from a YouTube / YouTube Music video URL. */
        private fun videoIdFrom(input: String): String {
            if (VIDEO_ID.matches(input)) return input
            val id = try {
                ServiceList.YouTube.streamLHFactory.getId(input)
            } catch (e: Exception) {
                throw InvalidInputException("not a video id or url")
            }
            if (!VIDEO_ID.matches(id)) throw InvalidInputException("not a video id or url")
            return id
        }

        private fun isLive(item: StreamInfoItem): Boolean =
            item.streamType == StreamType.LIVE_STREAM || item.streamType == StreamType.AUDIO_LIVE_STREAM

        private fun isSearchableVideo(item: StreamInfoItem): Boolean =
            !isLive(item) && !item.isShortFormContent && item.duration > 0

        private fun itemMap(item: StreamInfoItem): Map<String, Any?>? {
            val id = try {
                ServiceList.YouTube.streamLHFactory.getId(item.url)
            } catch (e: Exception) {
                return null
            }
            if (!VIDEO_ID.matches(id)) return null
            return mapOf(
                "id" to id,
                "title" to item.name,
                "uploader" to item.uploaderName,
                "durationSeconds" to item.duration.takeIf { it > 0 },
                "thumbnailUrl" to bestImageUrl(item.thumbnails),
                "url" to "https://www.youtube.com/watch?v=$id",
            )
        }

        private fun bestImageUrl(images: List<Image>?): String? =
            images?.maxByOrNull { it.height.toLong() * maxOf(it.width, 1) }?.url

        // Metadata is optional: a parsing hiccup on the title must not lose an otherwise valid stream.
        private fun <T> optional(block: () -> T): T? = try {
            block()
        } catch (e: ParsingException) {
            null
        }

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
                    is InvalidInputException -> return CODE_INVALID_URL
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
