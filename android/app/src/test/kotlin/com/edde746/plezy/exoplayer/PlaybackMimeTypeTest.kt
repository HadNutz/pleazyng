package com.edde746.plezy.exoplayer

import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.ParserException
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.exoplayer.hls.playlist.HlsPlaylistParser
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [35])
class PlaybackMimeTypeTest {
  private val route = LiveSourceRoute()

  private fun sourceType(url: String, live: Boolean): String {
    val uri = Uri.parse(url)
    val factory = DefaultMediaSourceFactory(DefaultDataSource.Factory(RuntimeEnvironment.getApplication()))
    val item = MediaItem.Builder().setUri(uri).setMimeType(route.mimeType(uri, live)).build()
    return factory.createMediaSource(item).javaClass.simpleName
  }

  @Test
  fun loadsPackagedFactoriesForLiveAndOnDemandUrls() {
    val sources = mapOf(
      "https://tv/live.m3u8?key=123" to "HlsMediaSource",
      "https://tv/live.mpd?key=123" to "DashMediaSource",
      "https://tv/live.isml/Manifest" to "SsMediaSource",
      "rtsp://tv/stream" to "RtspMediaSource",
      "https://tv/Videos/channel/stream.TS?Static=true" to "ProgressiveMediaSource",
      "https://radio/live.mp3" to "ProgressiveMediaSource"
    )
    for ((url, type) in sources) {
      assertEquals(url, type, sourceType(url, true))
      assertEquals(url, type, sourceType(url, false))
    }
  }

  @Test
  fun retriesOpaqueLiveUrlsOnceUsingTheServersResponse() {
    val uri = Uri.parse("https://tv/watch?token=opaque")
    assertEquals("HlsMediaSource", sourceType(uri.toString(), true))
    val error = assertThrows(ParserException::class.java) {
      HlsPlaylistParser().parse(uri, byteArrayOf(0x47, 0x40, 0x11, 0x10).inputStream())
    }
    for ((contentType, expected) in mapOf(
      "video/mp2t" to "ProgressiveMediaSource",
      "application/dash+xml; charset=utf-8" to "DashMediaSource",
      "application/vnd.ms-sstr+xml" to "SsMediaSource"
    )) {
      route.observeManifestError(uri, uri, mapOf("content-type" to listOf(contentType)), error)
      assertTrue(route.useDetectedType())
      assertEquals(expected, sourceType(uri.toString(), true))
      route.observeManifestError(uri, uri, emptyMap(), error)
      assertFalse(route.useDetectedType())
      route.reset()
    }
    route.observeManifestError(uri, Uri.parse("https://tv/actual.mpd"), emptyMap(), error)
    assertTrue(route.useDetectedType())
    assertEquals(MimeTypes.APPLICATION_MPD, route.mimeType(uri, true))
    assertNull(route.mimeType(uri, false))
  }

  @Test
  fun leavesHttpFailuresAndActualHlsParseFailuresOnTheirNormalRecoveryPath() {
    val uri = Uri.parse("https://tv/watch?token=opaque")
    for (error in listOf(IOException("404"), ParserException.createForMalformedManifest("Invalid playlist tag", null))) {
      route.observeManifestError(uri, uri, emptyMap(), error)
      assertFalse(route.useDetectedType())
    }
  }
}
