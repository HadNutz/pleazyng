package com.edde746.plezy.exoplayer

import androidx.media3.exoplayer.mediacodec.MediaCodecInfo
import com.edde746.plezy.shared.MediaCodecQuery

/** Media3 has already filtered for secure/tunneled playback. Preserve its rank within each group. */
internal fun preferredVideoDecoders(candidates: List<MediaCodecInfo>, hardwareDecoding: Boolean): List<MediaCodecInfo> {
  val (hardware, software) = candidates.partition {
    it.hardwareAccelerated && !MediaCodecQuery.isSoftwareCodecName(it.name)
  }
  return if (hardwareDecoding) hardware + software else software
}
