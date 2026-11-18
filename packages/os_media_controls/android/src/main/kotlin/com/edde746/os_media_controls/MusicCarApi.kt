package com.edde746.os_media_controls

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Catalog/commands only. The existing MediaSession and Dart player own transport. */
object MusicCarApi {
    private var channel: MethodChannel? = null
    private val handler = Handler(Looper.getMainLooper())
    private val listeners = mutableSetOf<() -> Unit>()
    private var epoch = 0
    var hasCarHost = false
        private set
    var embeddedBrowserBound = false
    val retainsEngine get() = hasCarHost || embeddedBrowserBound
    var ready = false
        private set
    var snapshot: Map<*, *> = emptyMap<Any, Any>()
        private set

    var queueWindow: Map<*, *> = emptyMap<Any, Any>()
        private set
    var catalogVersion = 0L
        private set
    private fun catalogChanged() {
        catalogVersion++
        listeners.toList().forEach { it() }
    }
    private val claims = mutableMapOf<String, () -> Boolean>()
    private var unclaimedPlay: Pair<String, () -> Unit>? = null
    private val pending = mutableSetOf<() -> Unit>()
    fun retireRequests() {
        epoch++
        pending.toList().forEach { it() }
    }
    var failureHandler: ((String) -> Unit)? = null
    fun reportFailure(code: String) { failureHandler?.invoke(code) }
    fun attach(messenger: BinaryMessenger) {
        channel?.setMethodCallHandler(null)
        retireRequests()
        ready = false
        snapshot = emptyMap<Any, Any>()
        queueWindow = emptyMap<Any, Any>()
        channel = MethodChannel(messenger, "com.pleazyng/music_car").also { pipe ->
            pipe.setMethodCallHandler { call, result ->
                when (call.method) {
                    "ready" -> { retireRequests(); ready = true; if (hasCarHost) connection(true); catalogChanged(); result.success(null) }
                    "acceptCarRequest" -> result.success((call.arguments as? String)?.let { claims.remove(it)?.invoke() } == true)
                    "catalogChanged" -> { catalogChanged(); result.success(null) }
                    "queueWindow" -> { queueWindow = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>(); listeners.toList().forEach { it() }; result.success(null) }
                    "snapshot" -> { snapshot = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>(); listeners.toList().forEach { it() }; result.success(null) }
                    "close" -> { retireRequests(); ready = false; snapshot = emptyMap<Any, Any>(); queueWindow = emptyMap<Any, Any>(); catalogChanged(); result.success(null) }
                    else -> result.notImplemented()
                }
            }
        }
    }
    fun detach() { retireRequests(); ready = false; snapshot = emptyMap<Any, Any>(); queueWindow = emptyMap<Any, Any>(); channel?.setMethodCallHandler(null); channel = null }
    fun addListener(listener: () -> Unit) { listeners.add(listener) }
    fun removeListener(listener: () -> Unit) { listeners.remove(listener) }
    fun connection(connected: Boolean) { if (!connected) retireRequests(); hasCarHost = connected; channel?.invokeMethod("connection", mapOf("connected" to connected)) }
    fun request(method: String, args: Any?, onError: ((String) -> Unit)? = null, done: (Any?) -> Unit) {
        val pipe = channel
        if (pipe == null || !ready) { onError?.invoke("loading"); done(null); return }
        val expected = epoch
        val token = java.util.UUID.randomUUID().toString()
        var finished = false
        lateinit var cancel: () -> Unit
        lateinit var timeout: Runnable
        fun finish(value: Any?, error: String? = null) {
            if (finished) return
            finished = true
            if (unclaimedPlay?.first == token) unclaimedPlay = null
            pending.remove(cancel)
            claims.remove(token)
            handler.removeCallbacks(timeout)
            if (error != null) onError?.invoke(error)
            done(if (expected == epoch) value else null)
        }
        cancel = { finish(null, "disconnected") }
        timeout = Runnable { finish(null, "timeout") }
        pending.add(cancel)
        handler.postDelayed(timeout, 10000)
        val payload = if (args is Map<*, *> && method in setOf("playItem", "playSearch", "transport", "jump", "guestAction")) {
            if (method in setOf("playItem", "playSearch", "jump")) {
                unclaimedPlay?.second?.invoke()
                unclaimedPlay = token to { finish(null, "superseded") }
            }
            claims[token] = {
                if (unclaimedPlay?.first == token) unclaimedPlay = null
                handler.removeCallbacks(timeout)
                !finished && ready && expected == epoch
            }
            args.entries.associate { it.key to it.value } + ("carRequest" to token)
        } else args
        pipe.invokeMethod(method, payload, object : MethodChannel.Result {
            override fun success(result: Any?) = finish(result)
            override fun error(code: String, message: String?, details: Any?) = finish(null, code)
            override fun notImplemented() = finish(null, "unavailable")
        })
    }
}
