package com.edde746.plezy.shared

import android.media.MediaCodecInfo
import android.media.MediaCodecInfo.CodecProfileLevel as Profile
import android.media.MediaCodecList
import android.os.Build
import java.util.Locale

/** Canonical decoder lookup and hardware classification for native playback. */
internal object MediaCodecQuery {
  /**
   * Codecs whose advertised support is decided by hardware: both have a
   * software decoder behind them, but a software HEVC or AV1 decode on
   * phone/TV-class hardware drops frames.
   */
  private val HARDWARE_GATED_VIDEO_MIME_TYPES = mapOf(
    "hevc" to "video/hevc",
    "av1" to "video/av01"
  )

  /** Codec name -> whether this device has a hardware decoder for it. */
  fun hardwareVideoDecodeSupport(
    hardwareMimeTypes: Set<String> = hardwareDecoderMimeTypes()
  ): Map<String, Boolean> = HARDWARE_GATED_VIDEO_MIME_TYPES.mapValues { (_, mimeType) -> mimeType in hardwareMimeTypes }

  /**
   * Every MIME type served by a hardware decoder, lowercased. One walk answers
   * for all codecs, unlike [findHardwareDecoder], which rescans per lookup.
   */
  private fun hardwareDecoderMimeTypes(): Set<String> {
    val mimeTypes = HashSet<String>()
    for (info in MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos) {
      if (info.isEncoder || !isHardwareAccelerated(info)) continue
      for (type in info.supportedTypes) mimeTypes.add(type.lowercase(Locale.ROOT))
    }
    return mimeTypes
  }

  /**
   * Whether a hardware `video/avc` decoder advertises H.264 High 10 (Hi10P).
   * Decoders that do not advertise it either refuse the stream (this is what
   * the mpv/FFmpeg MediaCodec path sees) or, on some SoCs, accept it and
   * render garbage; neither is a reason to let the hardware path try first
   * (#2065). Answered once per process: the codec list is static.
   */
  fun hardwareAvcHigh10Support(): Boolean = hardwareAvcHigh10.value

  private val hardwareAvcHigh10: Lazy<Boolean> = lazy {
    findHardwareDecoder("video/avc") { info, type ->
      val profiles = try {
        info.getCapabilitiesForType(type).profileLevels
      } catch (e: IllegalArgumentException) {
        return@findHardwareDecoder false
      }
      profiles.any { it.profile == MediaCodecInfo.CodecProfileLevel.AVCProfileHigh10 }
    } != null
  }

  /** Whether a hardware AV1 decoder exists; software MediaCodec AV1 components do not count (#2272). */
  fun hardwareAv1Support(): Boolean = hardwareAv1.value

  private val hardwareAv1: Lazy<Boolean> = lazy {
    findHardwareDecoder("video/av01") != null
  }

  /**
   * Whether the hardware AV1 decoder is Tensor's BigOcean block
   * (`c2.google.av1.decoder`, Pixel 6+). Its vendor service dies when a new
   * instance starts while the previous one is still being torn down (#2272);
   * [com.edde746.plezy.mpv.GpuVoPolicy.needsParkedRebuild] keeps the two apart.
   */
  fun hardwareAv1IsBigOcean(): Boolean = bigOceanAv1.value

  private val bigOceanAv1: Lazy<Boolean> = lazy {
    findHardwareDecoder("video/av01")?.name?.lowercase(Locale.ROOT)?.startsWith("c2.google.av1") == true
  }

  fun findHardwareDecoder(
    mimeType: String,
    codecKind: Int = MediaCodecList.REGULAR_CODECS,
    predicate: (MediaCodecInfo, String) -> Boolean = { _, _ -> true }
  ): MediaCodecInfo? {
    for (info in MediaCodecList(codecKind).codecInfos) {
      if (info.isEncoder || !isHardwareAccelerated(info)) continue
      for (type in info.supportedTypes) {
        if (type.equals(mimeType, ignoreCase = true) && predicate(info, type)) {
          return info
        }
      }
    }
    return null
  }

  private val videoMimeTypes = mapOf(
    "h264" to "video/avc",
    "hevc" to "video/hevc",
    "av1" to "video/av01",
    "vp9" to "video/x-vnd.on2.vp9",
    "vp8" to "video/x-vnd.on2.vp8",
    "mpeg2video" to "video/mpeg2",
    "mpeg4" to "video/mp4v-es",
    "h263" to "video/3gpp"
  )

  /** MediaFormat MIME type for an mpv/FFmpeg codec name. */
  fun mimeTypeForCodec(codec: String?): String? = videoMimeTypes[codec?.lowercase(Locale.ROOT)]

  /** Regular decoders Media3 can select without a secure playback session. */
  fun nativeVideoCodecs(): List<String> {
    val available = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
      .filterNot { it.isEncoder }
      .flatMap { it.supportedTypes.map { type -> type.lowercase(Locale.ROOT) } }
      .toSet()
    return videoMimeTypes.filterValues { it in available }.keys.toList()
  }

  /**
   * null means the request could not be described with platform metadata.
   * Check each decoder as a unit so the selected profile and size/rate
   * cannot come from different components.
   */
  fun supportsVideoFormat(
    codec: String?,
    width: Int?,
    height: Int?,
    fps: Double?,
    profile: String?,
    bitDepth: Int?,
    hardwareOnly: Boolean = false
  ): Boolean? {
    val mime = mimeTypeForCodec(codec) ?: return null
    val profiles = platformProfiles(codec, profile, bitDepth)
    val describesProfile = !profile.isNullOrBlank() || (bitDepth ?: 0) > 8
    var incomplete = false
    for (info in MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos) {
      if (info.isEncoder || (hardwareOnly && !isHardwareAccelerated(info))) continue
      val type = info.supportedTypes.firstOrNull { it.equals(mime, ignoreCase = true) } ?: continue
      val caps = try {
        info.getCapabilitiesForType(type)
      } catch (e: IllegalArgumentException) {
        incomplete = true
        continue
      }
      val video = caps.videoCapabilities
      if (width != null && height != null && width > 0 && height > 0) {
        if (video == null) {
          incomplete = true
          continue
        }
        val sizeSupported = if (fps != null && fps.isFinite() && fps > 0) {
          // Media3 checks rounded-down frame rates for fractional content.
          video.areSizeAndRateSupported(width, height, kotlin.math.floor(fps))
        } else {
          video.isSizeSupported(width, height)
        }
        if (!sizeSupported) continue
      }
      if (!describesProfile) return true
      if (profiles.isEmpty() || caps.profileLevels.isEmpty()) {
        incomplete = true
        continue
      }
      if (caps.profileLevels.any { it.profile in profiles }) return true
    }
    return if (incomplete) null else false
  }

  private fun platformProfiles(codec: String?, profile: String?, bitDepth: Int?): Set<Int> {
    val name = profile?.lowercase(Locale.ROOT)?.filter { it.isLetterOrDigit() }
    return when (codec) {
      "mpeg4" -> when (name) {
        "simple", "simpleprofile" -> setOf(Profile.MPEG4ProfileSimple, Profile.MPEG4ProfileAdvancedSimple)
        "advancedsimple", "advancedsimpleprofile" -> setOf(Profile.MPEG4ProfileAdvancedSimple)
        else -> emptySet()
      }
      "h264" -> when (name) {
        "baseline" -> setOf(Profile.AVCProfileBaseline, Profile.AVCProfileConstrainedBaseline)
        "constrainedbaseline" -> setOf(Profile.AVCProfileConstrainedBaseline, Profile.AVCProfileBaseline)
        "main" -> setOf(Profile.AVCProfileMain)
        "high" -> setOf(Profile.AVCProfileHigh, Profile.AVCProfileConstrainedHigh)
        "high10" -> setOf(Profile.AVCProfileHigh10)
        "high422" -> setOf(Profile.AVCProfileHigh422)
        "high444", "high444predictive" -> setOf(Profile.AVCProfileHigh444)
        null -> if (bitDepth == 10) setOf(Profile.AVCProfileHigh10) else emptySet()
        else -> emptySet()
      }
      "hevc" -> when {
        name == "main10" || (name == null && bitDepth == 10) ->
          setOf(Profile.HEVCProfileMain10, Profile.HEVCProfileMain10HDR10, Profile.HEVCProfileMain10HDR10Plus)
        name == "main" && (bitDepth ?: 8) <= 8 -> setOf(Profile.HEVCProfileMain, Profile.HEVCProfileMain10)
        else -> emptySet()
      }
      "av1" -> when {
        name != null && name != "main" && name != "profile0" -> emptySet()
        bitDepth == 10 ->
          setOf(Profile.AV1ProfileMain10, Profile.AV1ProfileMain10HDR10, Profile.AV1ProfileMain10HDR10Plus)
        bitDepth == 8 -> setOf(Profile.AV1ProfileMain8, Profile.AV1ProfileMain10)
        else -> emptySet()
      }
      "vp9" -> when (name) {
        "profile0", "0" -> setOf(Profile.VP9Profile0)
        "profile1", "1" -> setOf(Profile.VP9Profile1)
        "profile2", "2" -> setOf(Profile.VP9Profile2, Profile.VP9Profile2HDR, Profile.VP9Profile2HDR10Plus)
        "profile3", "3" -> setOf(Profile.VP9Profile3, Profile.VP9Profile3HDR, Profile.VP9Profile3HDR10Plus)
        else -> emptySet()
      }
      else -> emptySet()
    }
  }

  private val PERFORMANCE_POINT_RATES = intArrayOf(240, 120, 90, 60, 50, 30, 25, 24)

  /**
   * The highest frame rate the hardware decoder for [mimeType] advertises at
   * [width]x[height]: the manufacturer's performance points on API 31+, the
   * capability range below it. Null when there is no hardware decoder, the
   * size is outside what it declares, or the platform answers nothing —
   * the caller then applies its own ceiling.
   */
  fun maxDecoderFrameRate(mimeType: String, width: Int, height: Int): Int? {
    if (width <= 0 || height <= 0) return null
    val info = findHardwareDecoder(mimeType) ?: return null
    val video = try {
      info.getCapabilitiesForType(mimeType).videoCapabilities
    } catch (e: IllegalArgumentException) {
      return null
    } ?: return null
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      val points = video.supportedPerformancePoints
      if (!points.isNullOrEmpty()) {
        // The platform exposes only coverage, not the point's own rate:
        // ask for the rates a declaration would use, highest first.
        for (rate in PERFORMANCE_POINT_RATES) {
          val wanted = MediaCodecInfo.VideoCapabilities.PerformancePoint(width, height, rate)
          if (points.any { it.covers(wanted) }) return rate
        }
      }
    }
    return try {
      video.getSupportedFrameRatesFor(width, height).upper.toInt().takeIf { it > 0 }
    } catch (e: IllegalArgumentException) {
      null
    }
  }

  fun isHardwareAccelerated(info: MediaCodecInfo): Boolean {
    val name = info.name
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      isHardwareAccelerated(Build.VERSION.SDK_INT, info.isHardwareAccelerated, name)
    } else {
      // MediaCodecInfo.isHardwareAccelerated() does not exist before API 29.
      // Keep the call inside the version gate so older Fire OS releases do not
      // fail with NoSuchMethodError while initializing playback.
      isHardwareAccelerated(Build.VERSION.SDK_INT, false, name)
    }
  }

  internal fun isHardwareAccelerated(
    sdkInt: Int,
    platformReportsHardware: Boolean,
    name: String
  ): Boolean {
    // API 29 added manufacturer-provided classification, but some Codec2
    // builders still flag known software components as hardware. Require both
    // signals there; older releases expose only component names.
    return if (sdkInt >= Build.VERSION_CODES.Q) {
      platformReportsHardware && !isSoftwareCodecName(name)
    } else {
      !isSoftwareCodecName(name)
    }
  }

  /**
   * Component names Android itself ships as software. `c2.google.*` is not
   * one of them: it is the Tensor vendor prefix (`c2.google.av1.decoder` is
   * the BigOcean hardware AV1 block on Pixel 6+), and API 29's platform flag
   * classifies it (#2272). Google's software components are `c2.android.*`.
   */
  internal fun isSoftwareCodecName(name: String): Boolean {
    val normalized = name.lowercase(Locale.ROOT)
    return normalized.startsWith("omx.google.") ||
      normalized.startsWith("omx.ffmpeg.") ||
      normalized.startsWith("c2.android.") ||
      normalized.startsWith("c2.ffmpeg.") ||
      normalized.contains(".sw.")
  }
}
