package com.edde746.plezy.exoplayer

import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.FileTypes
import androidx.media3.common.MimeTypes
import androidx.media3.common.ParserException
import androidx.media3.common.util.UnstableApi
import androidx.media3.common.util.Util
import java.io.IOException

/** Media3 chooses its source factory before it opens the first HTTP response. */
@OptIn(UnstableApi::class)
internal class LiveSourceRoute {
  private var detectedType: String? = null
  private var retryType: String? = null

  fun reset() {
    detectedType = null
    retryType = null
  }

  fun mimeType(uri: Uri, isLive: Boolean): String? {
    if (!isLive) return null
    retryType?.let { return it }
    if (!uri.scheme.equals("http", true) && !uri.scheme.equals("https", true)) return null
    if (Util.inferContentType(uri) != C.CONTENT_TYPE_OTHER) return null
    // FileTypes checks suffixes case-sensitively. Use its extractor table on
    // the decoded filename while preserving the actual request URI.
    val name = uri.lastPathSegment.orEmpty().lowercase()
    if (FileTypes.inferFileTypeFromUri(Uri.Builder().appendPath(name).build()) != FileTypes.UNKNOWN) return null
    return MimeTypes.APPLICATION_M3U8
  }

  fun observeManifestError(uri: Uri, resolved: Uri, headers: Map<String, List<String>>, error: IOException) {
    if (retryType != null || mimeType(uri, true) != MimeTypes.APPLICATION_M3U8) return
    // The first response was not an HLS playlist. A corrupt HLS playlist or
    // failed child segment belongs to the normal error path.
    if (error !is ParserException || error.message?.contains("#EXTM3U header") != true) return
    val header = headers.entries.firstOrNull { it.key.equals("Content-Type", true) }
      ?.value?.firstOrNull()?.substringBefore(';')?.trim()?.lowercase()
    detectedType = when (header) {
      MimeTypes.APPLICATION_MPD -> MimeTypes.APPLICATION_MPD
      MimeTypes.APPLICATION_SS -> MimeTypes.APPLICATION_SS
      else -> when (Util.inferContentType(resolved)) {
        C.CONTENT_TYPE_DASH -> MimeTypes.APPLICATION_MPD
        C.CONTENT_TYPE_SS -> MimeTypes.APPLICATION_SS
        else -> "application/octet-stream" // Let the progressive extractors sniff the response.
      }
    }
  }

  fun useDetectedType(): Boolean {
    retryType = detectedType ?: return false
    detectedType = null
    return true
  }
}
