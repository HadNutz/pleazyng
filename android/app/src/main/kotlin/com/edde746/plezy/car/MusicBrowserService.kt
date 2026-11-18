package com.edde746.plezy.car

import android.content.Intent
import android.os.Bundle
import android.os.Process
import android.support.v4.media.MediaBrowserCompat
import android.support.v4.media.MediaDescriptionCompat
import androidx.media.MediaBrowserServiceCompat
import androidx.media.MediaSessionManager
import com.edde746.os_media_controls.MediaSessionHolder
import com.edde746.os_media_controls.MusicCarApi
import com.edde746.plezy.BuildConfig
import com.edde746.plezy.mpv.MpvAudioGroupOutputPlugin
import com.edde746.plezy.mpv.MpvAudioOverlapPlugin
import com.edde746.plezy.mpv.MpvAudioPlayerPlugin
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/** Android Auto browser over the app's existing media session. No second queue/player. */
class MusicBrowserService : MediaBrowserServiceCompat() {
  companion object {
    const val ENGINE_ID = "pleazyng_music_session"
  }
  private var acceptedHost = false

  private fun ensureMusicEngine() {
    if (FlutterEngineCache.getInstance().get(ENGINE_ID) != null) return
    // Boot the ordinary app/profile binder without opening an Activity.
    // PIN/account gates still decide whether Dart publishes a catalog.
    val engine = FlutterEngine(applicationContext)
    engine.plugins.add(MusicBackgroundPlatformPlugin())
    engine.plugins.add(com.edde746.plezy.music.CastMusicQueuePlugin())
    engine.plugins.add(MpvAudioPlayerPlugin())
    engine.plugins.add(MpvAudioOverlapPlugin())
    engine.plugins.add(MpvAudioGroupOutputPlugin())
    FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
    engine.dartExecutor.executeDartEntrypoint(
      DartExecutor.DartEntrypoint.createDefault(),
      listOf("--pleazyng-car-host")
    )
  }
  private var observedCatalog = -1L
  private var observedWindow: Map<*, *>? = null
  private val loadedParents = LinkedHashSet<String>()
  private val changed: () -> Unit = {
    MediaSessionHolder.sessionToken?.let { if (sessionToken == null) setSessionToken(it) }
    if (observedCatalog != MusicCarApi.catalogVersion) {
      observedCatalog = MusicCarApi.catalogVersion
      for (parent in loadedParents.toList() + "root") notifyChildrenChanged(parent)
    }
    if (observedWindow !== MusicCarApi.queueWindow) {
      observedWindow = MusicCarApi.queueWindow
      for (parent in listOf("home", "queue", "spoken", "chapters")) notifyChildrenChanged(parent)
    }
  }

  override fun onCreate() {
    super.onCreate()
    com.edde746.plezy.widgets.MusicWidgetProvider.attach(applicationContext)
    MusicCarApi.addListener(changed)
    MediaSessionHolder.sessionToken?.let { setSessionToken(it) }
  }

  override fun onGetRoot(clientPackageName: String, clientUid: Int, rootHints: Bundle?): BrowserRoot? {
    val user = MediaSessionManager.RemoteUserInfo(clientPackageName, -1, clientUid)
    if (clientUid != Process.myUid() && !MediaSessionManager.getSessionManager(this).isTrustedForMediaControl(user)) return null
    acceptedHost = !BuildConfig.AUTOMOTIVE_MEDIA &&
      (
        acceptedHost ||
          clientPackageName == "com.google.android.projection.gearhead" ||
          packageManager.hasSystemFeature("android.hardware.type.automotive")
        )
    if (BuildConfig.AUTOMOTIVE_MEDIA) MusicCarApi.embeddedBrowserBound = true
    ensureMusicEngine()
    MediaSessionHolder.sessionToken?.let { if (sessionToken == null) setSessionToken(it) }
    if (acceptedHost) MusicCarApi.connection(true)
    return BrowserRoot("root", Bundle().apply { putBoolean("android.media.browse.SEARCH_SUPPORTED", true) })
  }

  override fun onLoadChildren(parentId: String, result: Result<MutableList<MediaBrowserCompat.MediaItem>>) {
    if (loadedParents.size >= 100) loadedParents.remove(loadedParents.first())
    loadedParents.add(parentId)
    result.detach()
    MusicCarApi.request("browse", mapOf("id" to parentId)) { raw -> result.sendResult(if (raw is List<*>) items(raw) else null) }
  }

  override fun onSearch(query: String, extras: Bundle?, result: Result<MutableList<MediaBrowserCompat.MediaItem>>) {
    result.detach()
    MusicCarApi.request("search", mapOf("query" to query)) { raw -> result.sendResult(if (raw is List<*>) items(raw) else null) }
  }

  private fun items(raw: Any?): MutableList<MediaBrowserCompat.MediaItem> = (raw as? List<*>)?.take(100)?.mapNotNull { value ->
    val row = value as? Map<*, *> ?: return@mapNotNull null
    val id = row["id"] as? String ?: return@mapNotNull null
    val title = row["title"] as? String ?: return@mapNotNull null
    val description = MediaDescriptionCompat.Builder().setMediaId(id).setTitle(title)
      .setSubtitle(row["subtitle"] as? String)
    if (row["artwork"] == true) description.setIconUri(android.net.Uri.Builder().scheme("content")
        .authority("${packageName}.car.artwork").appendPath(id).build())
    MediaBrowserCompat.MediaItem(description.build(), if (row["playable"] == true) MediaBrowserCompat.MediaItem.FLAG_PLAYABLE else MediaBrowserCompat.MediaItem.FLAG_BROWSABLE)
  }?.toMutableList() ?: mutableListOf()

  override fun onDestroy() {
    MusicCarApi.removeListener(changed)
    if (acceptedHost) MusicCarApi.connection(false)
    MusicCarApi.embeddedBrowserBound = false
    super.onDestroy()
  }

  override fun onUnbind(intent: Intent?): Boolean {
    if (acceptedHost) {
      acceptedHost = false
      MusicCarApi.connection(false)
    }
    MusicCarApi.embeddedBrowserBound = false
    return super.onUnbind(intent)
  }
}
