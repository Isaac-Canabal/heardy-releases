package com.heardy.app

import android.app.ActivityManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity: AudioServiceActivity() {
    private val waveformExecutor = Executors.newSingleThreadExecutor()
    // El Mix DJ decodifica y codifica en serie, fuera del hilo principal.
    private val mixExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val volumeLeveler = VolumeLeveler()
    private val multicastLock by lazy { MulticastLockHolder(this) }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "heardy/volume_leveler")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "enable" -> {
                        val sessionId = call.argument<Int>("sessionId") ?: 0
                        result.success(volumeLeveler.enable(sessionId))
                    }
                    "disable" -> {
                        volumeLeveler.disable()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "heardy/multicast_lock")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquire" -> result.success(multicastLock.acquire())
                    "release" -> {
                        multicastLock.release()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "heardy/waveform")
            .setMethodCallHandler { call, result ->
                if (call.method != "extract") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val uri = call.argument<String>("uri")
                val samples = call.argument<Int>("samples") ?: 800
                if (uri == null || samples <= 0 || samples > 10_000) {
                    result.error("bad_args", "uri/samples invalidos", null)
                    return@setMethodCallHandler
                }
                val appContext = applicationContext
                waveformExecutor.execute {
                    val data = WaveformExtractor.extract(appContext, uri, samples)
                    mainHandler.post {
                        if (data == null) {
                            result.error("extract_failed", "no se pudo extraer", null)
                        } else {
                            result.success(data)
                        }
                    }
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "heardy/mix")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "totalMemory" -> {
                        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                        val info = ActivityManager.MemoryInfo()
                        am.getMemoryInfo(info)
                        result.success(info.totalMem)
                    }
                    "cancel" -> {
                        call.argument<String>("job")?.let { MixCodec.cancel(it) }
                        result.success(null)
                    }
                    "decode", "encodeAac" -> {
                        val job = call.argument<String>("job")
                        if (job == null) {
                            result.error("bad_args", "falta job", null)
                            return@setMethodCallHandler
                        }
                        val appContext = applicationContext
                        mixExecutor.execute {
                            try {
                                val value: Any? = if (call.method == "decode") {
                                    MixCodec.decode(appContext, call.argument<String>("uri")!!,
                                        call.argument<String>("out")!!, job)
                                } else {
                                    MixCodec.encodeAac(call.argument<String>("in")!!, call.argument<String>("out")!!,
                                        call.argument<Int>("bitrate") ?: 192_000,
                                        call.argument<Double>("gainDb") ?: 0.0, job)
                                    null
                                }
                                mainHandler.post { result.success(value) }
                            } catch (e: AudioDecodeLoop.Cancelled) {
                                mainHandler.post { result.error("cancelled", "cancelado", null) }
                            } catch (e: Exception) {
                                // Solo el tipo: el mensaje puede llevar rutas.
                                mainHandler.post { result.error("codec_failed", e.javaClass.simpleName, null) }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        mixExecutor.shutdown()
        waveformExecutor.shutdown()
        volumeLeveler.disable()
        multicastLock.release()
        super.onDestroy()
    }
}
