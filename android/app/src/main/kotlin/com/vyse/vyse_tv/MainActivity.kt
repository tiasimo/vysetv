package com.vyse.vyse_tv

import android.app.AppOpsManager
import android.app.PictureInPictureParams
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.util.Log
import android.util.Rational
import androidx.annotation.RequiresApi
import com.edde746.plezy.DeferredSurfaceTextureListener
import com.edde746.plezy.ExternalPlayerChannel
import com.edde746.plezy.TvDetection
import com.edde746.plezy.exoplayer.ExoPlayerPlugin
import com.edde746.plezy.mpv.MpvAudioPlayerPlugin
import com.edde746.plezy.mpv.MpvPlayerPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterTextureView
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.android.TransparencyMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import androidx.core.content.FileProvider
import java.io.File

/**
 * Hosts Plezy's player (android/app/src/main/kotlin/com/edde746/plezy, copied
 * from edde746/plezy's PlezyActivity): the video lives in a SurfaceView
 * *below* Flutter, so Flutter must render through a transparent TextureView.
 */
class MainActivity : FlutterActivity() {
  private val pipChannelName = "com.plezy/pip"

  private var flutterTextureView: FlutterTextureView? = null
  private var flutterSurfaceReconnectPending = false
  private var activityStarted = false

  // Plezy's "open in another player" (com.plezy/external_player)
  private val externalPlayerChannel = ExternalPlayerChannel(this)

  private var autoPipReady = false
  private var autoPipWidth = 16
  private var autoPipHeight = 9

  // ── Plezy player: video under a transparent Flutter ──

  // Keep Flutter in the normal View hierarchy so the player's video/subtitle
  // SurfaceViews stay the only native composition layers.
  override fun getRenderMode(): RenderMode = RenderMode.texture

  // Transparent so the video below shows through wherever Flutter paints nothing.
  override fun getTransparencyMode(): TransparencyMode = TransparencyMode.transparent

  override fun onFlutterTextureViewCreated(flutterTextureView: FlutterTextureView) {
    this.flutterTextureView = flutterTextureView
    val original = flutterTextureView.surfaceTextureListener ?: return
    flutterTextureView.surfaceTextureListener =
      DeferredSurfaceTextureListener(
        delegate = original,
        onSurfaceAvailable = ::tryReconnectFlutterSurface,
        // A resize must rebuild the surface at the new size, or an idle screen
        // stays squeezed into the old buffer after a rotation.
        onResize = { swapFlutterSurface(flutterTextureView) }
      ) { surface ->
        flutterTextureView.isAvailable && flutterTextureView.surfaceTexture === surface
      }
  }

  override fun onStop() {
    activityStarted = false
    if (TvDetection.isTv(this)) flutterSurfaceReconnectPending = true
    super.onStop()
  }

  override fun onStart() {
    super.onStart()
    activityStarted = true
    tryReconnectFlutterSurface()
  }

  // Some TV firmware keeps an "available" TextureView while invalidating its
  // compositor surface in standby; swap the surface so rendering resumes.
  private fun tryReconnectFlutterSurface() {
    if (!activityStarted || !flutterSurfaceReconnectPending) return
    val textureView = flutterTextureView ?: return
    textureView.post {
      if (!activityStarted ||
        !flutterSurfaceReconnectPending ||
        textureView !== flutterTextureView ||
        !textureView.isAttachedToWindow ||
        !textureView.isAvailable
      ) {
        return@post
      }
      Log.i(TAG, "Reconnecting Flutter texture surface after Android TV standby")
      swapFlutterSurface(textureView)
      flutterSurfaceReconnectPending = false
    }
  }

  private fun swapFlutterSurface(textureView: FlutterTextureView) {
    textureView.pause()
    textureView.resume()
  }

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    flutterEngine.plugins.add(MpvPlayerPlugin())
    flutterEngine.plugins.add(ExoPlayerPlugin())
    flutterEngine.plugins.add(MpvAudioPlayerPlugin())
    // VyseTV: second audio-only core so audiobooks keep their own track next to music
    flutterEngine.plugins.add(MpvAudio2PlayerPlugin())
    externalPlayerChannel.attach(flutterEngine.dartExecutor.binaryMessenger)

    // VyseTV: the updater hands a downloaded, checked APK to Android's own installer
    // (lib/data/updater.dart). Android asks the person before anything is installed.
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vyse/update").setMethodCallHandler { call, result ->
      if (call.method != "install") {
        result.notImplemented()
        return@setMethodCallHandler
      }
      try {
        val file = File(call.argument<String>("path") ?: "")
        if (!file.isFile) {
          result.error("NO_FILE", "The update file is missing.", null)
          return@setMethodCallHandler
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
        startActivity(
          Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        )
        result.success(true)
      } catch (e: Exception) {
        result.error("INSTALL_FAILED", "Android couldn't open the installer.", e.message)
      }
    }

    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, pipChannelName).setMethodCallHandler { call, result ->
      when (call.method) {
        "isSupported" -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && isPipSupportedDevice())
        "enter" -> {
          if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.success(mapOf("success" to false, "errorCode" to "android_version"))
            return@setMethodCallHandler
          }
          if (!isPipSupportedDevice()) {
            result.success(mapOf("success" to false, "errorCode" to "not_supported"))
            return@setMethodCallHandler
          }
          if (!isPipPermissionGranted()) {
            result.success(mapOf("success" to false, "errorCode" to "permission_disabled"))
            return@setMethodCallHandler
          }
          try {
            val width = call.argument<Int>("width") ?: 16
            val height = call.argument<Int>("height") ?: 9
            val success = enterPictureInPictureMode(buildPipParams(width, height))
            result.success(if (success) mapOf("success" to true) else mapOf("success" to false, "errorCode" to "failed"))
          } catch (e: IllegalStateException) {
            result.success(mapOf("success" to false, "errorCode" to "not_supported"))
          } catch (e: Exception) {
            Log.w(TAG, "Failed to enter PiP", e)
            result.success(mapOf("success" to false, "errorCode" to "unknown", "errorMessage" to e.message))
          }
        }
        "setAutoPipReady" -> {
          if (!isPipSupportedDevice()) {
            autoPipReady = false
            result.success(true)
            return@setMethodCallHandler
          }
          autoPipReady = call.argument<Boolean>("ready") ?: false
          autoPipWidth = call.argument<Int>("width") ?: 16
          autoPipHeight = call.argument<Int>("height") ?: 9
          if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
              setPictureInPictureParams(buildPipParams(autoPipWidth, autoPipHeight, autoEnterEnabled = autoPipReady))
            } catch (e: Exception) {
              Log.w(TAG, "Failed to set auto-PiP params", e)
            }
          }
          result.success(true)
        }
        else -> result.notImplemented()
      }
    }
  }

  @Deprecated("FlutterActivity still routes results through here")
  @Suppress("DEPRECATION")
  override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
    if (!externalPlayerChannel.onActivityResult(requestCode, resultCode, data)) {
      super.onActivityResult(requestCode, resultCode, data)
    }
  }

  override fun onDestroy() {
    externalPlayerChannel.dispose()
    super.onDestroy()
  }

  // ── Picture-in-picture ──

  override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
    super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
    flutterEngine?.let { engine ->
      MethodChannel(engine.dartExecutor.binaryMessenger, pipChannelName).invokeMethod("onPipChanged", isInPictureInPictureMode)
      (engine.plugins.get(ExoPlayerPlugin::class.java) as? ExoPlayerPlugin)?.onPipModeChanged(isInPictureInPictureMode)
    }
  }

  override fun onUserLeaveHint() {
    super.onUserLeaveHint()
    // Auto PiP for API 26-30 (API 31+ uses setAutoEnterEnabled)
    if (isPipSupportedDevice() &&
      Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
      Build.VERSION.SDK_INT < Build.VERSION_CODES.S &&
      autoPipReady &&
      isPipPermissionGranted()
    ) {
      try {
        flutterEngine?.dartExecutor?.binaryMessenger?.let { messenger ->
          MethodChannel(messenger, pipChannelName).invokeMethod("onAutoPipEntering", null)
        }
        enterPictureInPictureMode(buildPipParams(autoPipWidth, autoPipHeight))
      } catch (e: Exception) {
        Log.w(TAG, "Failed to enter auto-PiP", e)
      }
    }
  }

  private fun isPipSupportedDevice(): Boolean =
    !TvDetection.isTv(this) && packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

  @RequiresApi(Build.VERSION_CODES.O)
  private fun isPipPermissionGranted(): Boolean {
    val appOps = getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
    @Suppress("DEPRECATION")
    return appOps.checkOpNoThrow(AppOpsManager.OPSTR_PICTURE_IN_PICTURE, applicationInfo.uid, packageName) ==
      AppOpsManager.MODE_ALLOWED
  }

  @RequiresApi(Build.VERSION_CODES.O)
  private fun buildPipParams(width: Int, height: Int, autoEnterEnabled: Boolean? = null): PictureInPictureParams {
    val (w, h) = if (width <= 0 || height <= 0) {
      Pair(16, 9)
    } else {
      val ratio = width.toFloat() / height.toFloat()
      when {
        ratio < 1f / 2.39f -> Pair(100, 239)
        ratio > 2.39f -> Pair(239, 100)
        else -> Pair(width, height)
      }
    }
    val builder = PictureInPictureParams.Builder().setAspectRatio(Rational(w, h))
    if (autoEnterEnabled != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      builder.setAutoEnterEnabled(autoEnterEnabled)
    }
    return builder.build()
  }

  /** Audiobooks' own mpv audio core (Plezy ships one; VyseTV needs two). */
  class MpvAudio2PlayerPlugin : MpvPlayerPlugin(channelBase = "com.plezy/mpv_audio_player_2", audioOnly = true)

  private companion object {
    const val TAG = "VyseMainActivity"
  }
}
