package com.edde746.plezy.exoplayer

import androidx.media3.exoplayer.mediacodec.MediaCodecInfo
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class VideoDecoderPreferenceTest {
  private fun decoder(name: String, hardware: Boolean) = MediaCodecInfo.newInstance(
    name, "video/avc", "video/avc", null, hardware, !hardware, hardware, false, false
  )

  @Test
  fun preferHardwareKeepsRankAndRetainsSoftwareForFallback() {
    val software = decoder("c2.android.avc.decoder", true)
    val first = decoder("c2.qti.avc.decoder", true)
    val second = decoder("c2.vendor.avc.decoder", true)
    val otherSoftware = decoder("custom.software", false)
    val candidates = listOf(software, first, otherSoftware, second)

    assertEquals(listOf(first, second, software, otherSoftware), preferredVideoDecoders(candidates, true))
    assertEquals(listOf(software, otherSoftware), preferredVideoDecoders(candidates, false))
    assertEquals(listOf(software), preferredVideoDecoders(listOf(software), true))
  }
}
