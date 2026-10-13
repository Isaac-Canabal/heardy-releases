/*
 * Derived from NewPipe (https://github.com/TeamNewPipe/NewPipe), file
 * https://github.com/TeamNewPipe/NewPipe/blob/dev/app/src/main/java/org/schabi/newpipe/DownloaderImpl.java
 * NewPipe is licensed under the GNU General Public License, version 3 or (at your
 * option) any later version (SPDX-License-Identifier: GPL-3.0-or-later). The upstream
 * file carries no copyright line of its own; copyright in it belongs to its authors,
 * the NewPipe contributors.
 *
 * This file has been modified by Heardy in 2026: rewritten in Kotlin on top of OkHttp, without cookies, restricted mode or the ReCaptcha flow.
 *
 * This program is free software: you can redistribute it and/or modify it under the
 * terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later version.
 * It is distributed WITHOUT ANY WARRANTY; see the GNU General Public License for details.
 */

package com.heardy.ytstream

import java.io.IOException
import java.util.concurrent.TimeUnit
import okhttp3.OkHttpClient
import okhttp3.RequestBody.Companion.toRequestBody
import org.schabi.newpipe.extractor.downloader.Downloader
import org.schabi.newpipe.extractor.downloader.Request
import org.schabi.newpipe.extractor.downloader.Response
import org.schabi.newpipe.extractor.exceptions.ReCaptchaException

/**
 * Port of NewPipe's `DownloaderImpl` without cookies, restricted mode or the ReCaptcha flow.
 * OkHttp handles gzip transparently.
 */
class DownloaderImpl private constructor() : Downloader() {
    private val client = OkHttpClient.Builder()
        .readTimeout(30, TimeUnit.SECONDS)
        .build()

    @Throws(IOException::class, ReCaptchaException::class)
    override fun execute(request: Request): Response {
        val body = request.dataToSend()?.toRequestBody()
        val builder = okhttp3.Request.Builder()
            .method(request.httpMethod(), body)
            .url(request.url())
            .addHeader("User-Agent", USER_AGENT)

        request.headers().forEach { (name, values) ->
            builder.removeHeader(name)
            values.forEach { builder.addHeader(name, it) }
        }

        client.newCall(builder.build()).execute().use { response ->
            if (response.code == 429) {
                throw ReCaptchaException("reCaptcha Challenge requested", request.url())
            }
            val responseBody = response.body?.string()
            return Response(
                response.code,
                response.message,
                response.headers.toMultimap(),
                responseBody,
                response.request.url.toString()
            )
        }
    }

    companion object {
        const val USER_AGENT =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0"

        @Volatile
        private var instance: DownloaderImpl? = null

        fun getInstance(): DownloaderImpl =
            instance ?: synchronized(this) { instance ?: DownloaderImpl().also { instance = it } }
    }
}
