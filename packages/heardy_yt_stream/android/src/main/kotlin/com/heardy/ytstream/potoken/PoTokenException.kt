/*
 * Derived from NewPipe (https://github.com/TeamNewPipe/NewPipe), file
 * https://github.com/TeamNewPipe/NewPipe/blob/dev/app/src/main/java/org/schabi/newpipe/util/potoken/PoTokenException.kt
 * NewPipe is licensed under the GNU General Public License, version 3 or (at your
 * option) any later version (SPDX-License-Identifier: GPL-3.0-or-later). The upstream
 * file carries no copyright line of its own; copyright in it belongs to its authors,
 * the NewPipe contributors.
 *
 * This file has been modified by Heardy in 2026: package renamed to com.heardy.ytstream.potoken; DEBUG_LOGS (a log-tag based flag) added.
 *
 * This program is free software: you can redistribute it and/or modify it under the
 * terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later version.
 * It is distributed WITHOUT ANY WARRANTY; see the GNU General Public License for details.
 */

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
