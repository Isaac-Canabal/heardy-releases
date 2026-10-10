package com.heardy.app

import android.os.Handler
import android.os.Looper
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity: AudioServiceActivity() {
    private val waveformExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
    }

    override fun onDestroy() {
        waveformExecutor.shutdown()
        super.onDestroy()
    }
}
