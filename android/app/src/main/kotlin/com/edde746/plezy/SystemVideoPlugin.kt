package com.edde746.plezy

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import android.view.Surface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

/** Framework MediaPlayer, independent of the Media3 and libmpv sessions. */
class SystemVideoPlugin :
  FlutterPlugin,
  MethodChannel.MethodCallHandler {
  private lateinit var binding: FlutterPlugin.FlutterPluginBinding
  private lateinit var channel: MethodChannel
  private val sessions = mutableMapOf<Long, Session>()

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    this.binding = binding
    channel = MethodChannel(binding.binaryMessenger, "org.snapetech.pleazyng/system_video")
    channel.setMethodCallHandler(this)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    sessions.values.forEach { it.close() }
    sessions.clear()
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    val id = call.argument<Number>("id")?.toLong() ?: return result.error("id", "Missing session", null)
    try {
      if (call.method == "create") {
        val session = Session(binding.textureRegistry.createSurfaceTexture())
        sessions.put(id, session)?.close()
        try {
          session.open(binding.applicationContext, Uri.parse(call.argument<String>("uri")!!))
          result.success(session.texture.id())
        } catch (error: Exception) {
          sessions.remove(id)?.close()
          throw error
        }
        return
      }
      if (call.method == "dispose") {
        sessions.remove(id)?.close()
        return result.success(null)
      }
      val session = sessions[id] ?: return result.error("session", "Closed video session", null)
      val player = session.player
      when (call.method) {
        "state" -> return result.success(session.state())
        "tracks" -> return result.success(session.tracks())
        "play" -> {
          player.start()
          if (session.rate != 1f) player.playbackParams = player.playbackParams.setSpeed(session.rate)
        }
        "pause" -> if (player.isPlaying) player.pause()
        "seek" -> {
          val ms = call.argument<Number>("value")!!.toLong()
          if (Build.VERSION.SDK_INT >= 26) {
            player.seekTo(ms, MediaPlayer.SEEK_CLOSEST)
          } else {
            player.seekTo(ms.coerceIn(0, Int.MAX_VALUE.toLong()).toInt())
          }
        }
        "volume" -> call.argument<Number>("value")!!.toFloat().also { player.setVolume(it, it) }
        "rate" -> {
          val speed = call.argument<Number>("value")!!.toFloat()
          if (player.isPlaying) player.playbackParams = player.playbackParams.setSpeed(speed)
          session.rate = speed
        }
        "audio", "subtitle" -> session.select(call.method, call.argument<String>("value")!!)
        else -> return result.notImplemented()
      }
      result.success(null)
    } catch (_: Exception) {
      result.error("media-player", "Android MediaPlayer rejected the operation", null)
    }
  }

  private class Session(val texture: TextureRegistry.SurfaceTextureEntry) {
    val player = MediaPlayer()
    private val surface = Surface(texture.surfaceTexture())
    private var ready = false
    private var failed = false
    private var ended = false
    private var frame = false
    private var buffering = false
    private var caption = ""
    var rate = 1f

    fun open(context: Context, uri: Uri) {
      player.setAudioAttributes(
        AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
          .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build()
      )
      player.setSurface(surface)
      player.setOnVideoSizeChangedListener { _, w, h ->
        if (w > 0 && h > 0) texture.surfaceTexture().setDefaultBufferSize(w, h)
      }
      player.setOnPreparedListener { ready = true }
      player.setOnErrorListener { _, _, _ ->
        failed = true
        true
      }
      player.setOnCompletionListener { ended = true }
      player.setOnSeekCompleteListener { ended = false }
      player.setOnTimedTextListener { _, text -> caption = text?.text ?: "" }
      player.setOnInfoListener { _, info, _ ->
        when (info) {
          MediaPlayer.MEDIA_INFO_VIDEO_RENDERING_START -> frame = true
          MediaPlayer.MEDIA_INFO_BUFFERING_START -> buffering = true
          MediaPlayer.MEDIA_INFO_BUFFERING_END -> buffering = false
        }
        false
      }
      player.setDataSource(context, uri)
      player.prepareAsync()
    }

    fun state(): Map<String, Any> {
      if (!ready || failed) return mapOf("ready" to false, "failed" to failed)
      return mapOf(
        "ready" to true, "playing" to player.isPlaying, "ended" to ended,
        "frame" to frame, "buffering" to buffering, "caption" to caption,
        "width" to player.videoWidth, "height" to player.videoHeight,
        "duration" to player.duration.coerceAtLeast(0), "position" to player.currentPosition
      )
    }

    fun tracks() = player.trackInfo.mapIndexedNotNull { index, info ->
      val type = when (info.trackType) {
        MediaPlayer.TrackInfo.MEDIA_TRACK_TYPE_AUDIO -> "audio"
        MediaPlayer.TrackInfo.MEDIA_TRACK_TYPE_TIMEDTEXT -> "subtitle"
        else -> return@mapIndexedNotNull null
      }
      mapOf(
        "type" to type,
        "id" to index.toString(),
        "language" to info.language,
        "selected" to (player.getSelectedTrack(info.trackType) == index)
      )
    }

    fun select(type: String, id: String) {
      if (type == "subtitle") caption = ""
      if (id == "no") {
        val kind = if (type == "audio") {
          MediaPlayer.TrackInfo.MEDIA_TRACK_TYPE_AUDIO
        } else {
          MediaPlayer.TrackInfo.MEDIA_TRACK_TYPE_TIMEDTEXT
        }
        val selected = player.getSelectedTrack(kind)
        if (selected >= 0) player.deselectTrack(selected)
      } else {
        player.selectTrack(id.toInt())
      }
    }

    fun close() {
      player.release()
      surface.release()
      texture.release()
    }
  }
}
