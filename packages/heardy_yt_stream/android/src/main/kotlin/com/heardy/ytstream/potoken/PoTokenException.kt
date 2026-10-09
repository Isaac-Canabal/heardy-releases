package com.heardy.ytstream.potoken

class PoTokenException(message: String) : Exception(message)

// to be thrown if the WebView provided by the system is broken
class BadWebViewException(message: String) : Exception(message)

fun buildExceptionForJsError(error: String): Exception {
    return if (error.contains("SyntaxError")) {
        BadWebViewException(error)
    } else {
        PoTokenException(error)
    }
}

// Verbose poToken logs (they include tokens): enable with `adb shell setprop log.tag.HeardyPoToken DEBUG`.
internal val DEBUG_LOGS: Boolean
    get() = android.util.Log.isLoggable("HeardyPoToken", android.util.Log.DEBUG)
