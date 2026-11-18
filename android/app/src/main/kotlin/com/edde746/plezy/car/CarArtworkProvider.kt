package com.edde746.plezy.car

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.Process
import androidx.media.MediaSessionManager
import com.edde746.os_media_controls.MusicCarApi
import java.io.FileNotFoundException
import java.util.concurrent.Semaphore

/** The host reads bounded artwork bytes from the active profile using an opaque browse ID. */
class CarArtworkProvider : ContentProvider() {
    private val permits = Semaphore(8)
    override fun onCreate() = true
    override fun getType(uri: Uri) = "image/png"
    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        val ctx = context ?: throw FileNotFoundException()
        val uid = Binder.getCallingUid()
        val caller = callingPackage ?: throw FileNotFoundException()
        val user = MediaSessionManager.RemoteUserInfo(caller, Binder.getCallingPid(), uid)
        if (uid != Process.myUid() && !MediaSessionManager.getSessionManager(ctx).isTrustedForMediaControl(user)) {
            throw FileNotFoundException()
        }
        val id = uri.pathSegments.singleOrNull() ?: throw FileNotFoundException()
        if (mode != "r" || id.length > 160 || !permits.tryAcquire()) throw FileNotFoundException()
        try {
            return openPipeHelper(uri, "image/png", null, id) { pipe, _, _, _, key ->
                try {
                    val future = java.util.concurrent.CompletableFuture<ByteArray?>()
                    Handler(Looper.getMainLooper()).post {
                        MusicCarApi.request("artwork", mapOf("id" to key, "size" to 128)) { future.complete(it as? ByteArray) }
                    }
                    ParcelFileDescriptor.AutoCloseOutputStream(pipe).use { stream ->
                        future.get(11, java.util.concurrent.TimeUnit.SECONDS)?.let { stream.write(it) }
                    }
                } catch (_: Exception) {
                    // A detached host, inaccessible row or cancelled image read is an empty pipe.
                } finally { permits.release() }
            }
        } catch (error: Exception) { permits.release(); throw error }
    }

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = throw UnsupportedOperationException()
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = throw UnsupportedOperationException()
}
