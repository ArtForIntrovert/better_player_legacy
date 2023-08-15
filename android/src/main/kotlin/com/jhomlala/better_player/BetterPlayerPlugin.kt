// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
package com.jhomlala.better_player

import android.app.Activity
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.LongSparseArray
import androidx.activity.ComponentActivity
import androidx.annotation.DrawableRes
import androidx.annotation.RequiresApi
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.OnPictureInPictureModeChangedProvider
import androidx.core.app.PictureInPictureModeChangedInfo
import androidx.lifecycle.lifecycleScope
import com.jhomlala.better_player.BetterPlayerCache.releaseCache
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterPluginBinding
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.PluginRegistry.UserLeaveHintListener
import io.flutter.util.Predicate
import io.flutter.view.TextureRegistry
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/**
 * Android platform implementation of the VideoPlayerPlugin.
 */
class BetterPlayerPlugin : FlutterPlugin, ActivityAware, MethodCallHandler {
    private var currentPIPPlayer: BetterPlayer? = null
    internal var pipPrimary: BetterPlayer? = null
        private set

    private val videoPlayers = LongSparseArray<BetterPlayer>()
    private val videoPlayerListeners = mutableMapOf<BetterPlayer, Job>()
    private val dataSources = LongSparseArray<Map<String, Any?>>()
    private val userLeaveHintListener: UserLeaveHintListener =
        UserLeaveHintListenerImpl(::onUserLeave)
    private var flutterState: FlutterState? = null
    private var currentNotificationTextureId: Long = -1
    private var currentNotificationDataSource: Map<String, Any?>? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pipHandler: Handler? = null
    private var pipRunnable: Runnable? = null

    internal val isInPictureInPictureMode: Boolean
        @RequiresApi(Build.VERSION_CODES.N)
        get() = activity != null && activity!!.isInPictureInPictureMode

    private val pipActionsReceiver = PIPActionsReceiver(this)
    private val homeButtonReceiver = HomeButtonReceiver(this)

    override fun onAttachedToEngine(binding: FlutterPluginBinding) {
        val loader = FlutterLoader()
        flutterState = FlutterState(
            binding.applicationContext,
            binding.binaryMessenger, object : KeyForAssetFn {
                override fun get(asset: String?): String {
                    return loader.getLookupKeyForAsset(
                        asset!!
                    )
                }

            }, object : KeyForAssetAndPackageName {
                override fun get(asset: String?, packageName: String?): String {
                    return loader.getLookupKeyForAsset(
                        asset!!, packageName!!
                    )
                }
            },
            binding.textureRegistry
        )
        flutterState?.startListening(this)
        removeNotificationListeners()
    }

    override fun onDetachedFromEngine(binding: FlutterPluginBinding) {
        if (flutterState == null) {
            Log.wtf(TAG, "Detached from the engine before registering to it.")
        }
        disposeAllPlayers()
        releaseCache()

        flutterState?.stopListening()
        flutterState = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        binding.addOnUserLeaveHintListener(userLeaveHintListener)

        activityBinding = binding
        activity = binding.activity
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val provider = activity as? OnPictureInPictureModeChangedProvider
            provider?.addOnPictureInPictureModeChangedListener(::onPictureInPictureModeChangedListener)
        }

        activity?.registerReceiver(pipActionsReceiver, PIPActionsReceiver.INTENT_FILTER)
        activity?.registerReceiver(
            homeButtonReceiver, IntentFilter(Intent.ACTION_CLOSE_SYSTEM_DIALOGS)
        )
    }

    override fun onDetachedFromActivityForConfigChanges() {}

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {}

    override fun onDetachedFromActivity() {
        val provider = activity as? OnPictureInPictureModeChangedProvider
        provider?.removeOnPictureInPictureModeChangedListener(::onPictureInPictureModeChangedListener)

        activityBinding?.removeOnUserLeaveHintListener(userLeaveHintListener)
        activity?.unregisterReceiver(pipActionsReceiver)
        activity?.unregisterReceiver(homeButtonReceiver)
    }

    private fun onUserLeave() {
        if (USE_AUTO_PIP_MODE && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) return
        if (pipPrimary == null) return

        pipPrimary
            ?.let { enablePictureInPicture(it) }
    }

    private fun onPictureInPictureModeChangedListener(info: PictureInPictureModeChangedInfo) {
        if (USE_AUTO_PIP_MODE && currentPIPPlayer == null && info.isInPictureInPictureMode && pipPrimary != null) {
            currentPIPPlayer = pipPrimary
        } else if (!USE_AUTO_PIP_MODE || currentPIPPlayer == null) {
            return
        }

        currentPIPPlayer
            ?.onPictureInPictureStatusChanged(info.isInPictureInPictureMode)

        if (!info.isInPictureInPictureMode) {
            currentPIPPlayer = null
        }

        Log.v(TAG, "PIP Mode changed: ${info.isInPictureInPictureMode}")
    }

    internal fun getPlayer(textureId: Long): BetterPlayer? {
        return videoPlayers[textureId]
    }

    private fun disposeAllPlayers() {
        for (i in 0 until videoPlayers.size()) {
            videoPlayerListeners[videoPlayers.valueAt(i)]?.cancel()
            videoPlayers.valueAt(i).dispose()
        }

        videoPlayerListeners.clear()
        videoPlayers.clear()
        dataSources.clear()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (flutterState == null || flutterState?.textureRegistry == null) {
            result.error("no_activity", "better_player plugin requires a foreground activity", null)
            return
        }
        when (call.method) {
            INIT_METHOD -> disposeAllPlayers()
            CREATE_METHOD -> {
                val handle = flutterState!!.textureRegistry!!.createSurfaceTexture()
                val eventChannel = EventChannel(
                    flutterState?.binaryMessenger, EVENTS_CHANNEL + handle.id()
                )
                var customDefaultLoadControl: CustomDefaultLoadControl? = null
                if (call.hasArgument(MIN_BUFFER_MS) && call.hasArgument(MAX_BUFFER_MS) &&
                    call.hasArgument(BUFFER_FOR_PLAYBACK_MS) &&
                    call.hasArgument(BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS)
                ) {
                    customDefaultLoadControl = CustomDefaultLoadControl(
                        call.argument(MIN_BUFFER_MS),
                        call.argument(MAX_BUFFER_MS),
                        call.argument(BUFFER_FOR_PLAYBACK_MS),
                        call.argument(BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS)
                    )
                }

                val player = BetterPlayer(
                    flutterState?.applicationContext!!, eventChannel, handle,
                    customDefaultLoadControl, result
                )

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    listenToPlayerStateChangesForPIPParams(player)?.let {
                        videoPlayerListeners[player] = it
                    }
                }

                videoPlayers.put(handle.id(), player)
            }
            PRE_CACHE_METHOD -> preCache(call, result)
            STOP_PRE_CACHE_METHOD -> stopPreCache(call, result)
            CLEAR_CACHE_METHOD -> clearCache(result)
            else -> {
                val textureId = (call.argument<Any>(TEXTURE_ID_PARAMETER) as Number?)!!.toLong()
                val player = videoPlayers[textureId]
                if (player == null) {
                    result.error(
                        "Unknown textureId",
                        "No video player associated with texture id $textureId",
                        null
                    )
                    return
                }
                onMethodCall(call, result, textureId, player)
            }
        }
    }

    private fun onMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        textureId: Long,
        player: BetterPlayer
    ) {
        when (call.method) {
            SET_DATA_SOURCE_METHOD -> {
                setDataSource(call, result, player)
            }
            SET_LOOPING_METHOD -> {
                player.setLooping(call.argument(LOOPING_PARAMETER)!!)
                result.success(null)
            }
            SET_VOLUME_METHOD -> {
                player.setVolume(call.argument(VOLUME_PARAMETER)!!)
                result.success(null)
            }
            PLAY_METHOD -> {
                for (i in 0 until videoPlayers.size()) {
                    val key: Long = videoPlayers.keyAt(i)
                    val otherPlayer = videoPlayers.get(key)

                    if (otherPlayer != player) {
                        otherPlayer.pause()
                    }
                }

                setupNotification(player)
                player.play()
                result.success(null)
            }
            PAUSE_METHOD -> {
                player.pause()
                result.success(null)
            }
            SEEK_TO_METHOD -> {
                val location = (call.argument<Any>(LOCATION_PARAMETER) as Number?)!!.toInt()
                player.seekTo(location)
                result.success(null)
            }
            POSITION_METHOD -> {
                result.success(player.position)
                player.sendBufferingUpdate(false)
            }
            ABSOLUTE_POSITION_METHOD -> result.success(player.absolutePosition)
            SET_SPEED_METHOD -> {
                player.setSpeed(call.argument(SPEED_PARAMETER)!!)
                result.success(null)
            }
            SET_TRACK_PARAMETERS_METHOD -> {
                player.setTrackParameters(
                    call.argument(WIDTH_PARAMETER)!!,
                    call.argument(HEIGHT_PARAMETER)!!,
                    call.argument(BITRATE_PARAMETER)!!
                )
                result.success(null)
            }
            SET_PICTURE_IN_PICTURE_OVERLAY_RECT -> {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
                if (activity == null || activity!!.isInPictureInPictureMode) return

                lastPlayerRects[player] = getRectFromCall(call)
                result.success(null)
            }
            SET_PIP_PRIMARY -> {
                setupPIPPrimary(player, call.argument(PIP_PRIMARY_PARAMETER)!!)
                result.success(null)
            }
            ENABLE_PICTURE_IN_PICTURE_METHOD -> {
                try {
                    enablePictureInPicture(player, getRectFromCall(call))
                    result.success(null)
                } catch (e: Exception) {
                    result.error("exception", e.message ?: "Failed to enter in PIP mode", e)
                }
            }
            DISABLE_PICTURE_IN_PICTURE_METHOD -> {
                disablePictureInPicture(player)
                result.success(null)
            }
            IS_PICTURE_IN_PICTURE_SUPPORTED_METHOD -> result.success(
                isPictureInPictureSupported()
            )
            SET_AUDIO_TRACK_METHOD -> {
                val name = call.argument<String?>(NAME_PARAMETER)
                val index = call.argument<Int?>(INDEX_PARAMETER)
                if (name != null && index != null) {
                    player.setAudioTrack(name, index)
                }
                result.success(null)
            }
            SET_MIX_WITH_OTHERS_METHOD -> {
                val mixWitOthers = call.argument<Boolean?>(
                    MIX_WITH_OTHERS_PARAMETER
                )
                if (mixWitOthers != null) {
                    player.setMixWithOthers(mixWitOthers)
                }
            }
            DISPOSE_METHOD -> {
                dispose(player, textureId)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun setDataSource(
        call: MethodCall,
        result: MethodChannel.Result,
        player: BetterPlayer
    ) {
        val dataSource = call.argument<Map<String, Any?>>(DATA_SOURCE_PARAMETER)!!
        dataSources.put(getTextureId(player)!!, dataSource)
        val key = getParameter(dataSource, KEY_PARAMETER, "")
        val headers: Map<String, String> = getParameter(dataSource, HEADERS_PARAMETER, HashMap())
        val overriddenDuration: Number = getParameter(dataSource, OVERRIDDEN_DURATION_PARAMETER, 0)
        if (dataSource[ASSET_PARAMETER] != null) {
            val asset = getParameter(dataSource, ASSET_PARAMETER, "")
            val assetLookupKey: String = if (dataSource[PACKAGE_PARAMETER] != null) {
                val packageParameter = getParameter(
                    dataSource,
                    PACKAGE_PARAMETER,
                    ""
                )
                flutterState!!.keyForAssetAndPackageName[asset, packageParameter]
            } else {
                flutterState!!.keyForAsset[asset]
            }
            player.setDataSource(
                flutterState?.applicationContext!!,
                key,
                "asset:///$assetLookupKey",
                null,
                result,
                headers,
                false,
                0L,
                0L,
                overriddenDuration.toLong(),
                null,
                null, null, null
            )
        } else {
            val useCache = getParameter(dataSource, USE_CACHE_PARAMETER, false)
            val maxCacheSizeNumber: Number = getParameter(dataSource, MAX_CACHE_SIZE_PARAMETER, 0)
            val maxCacheFileSizeNumber: Number =
                getParameter(dataSource, MAX_CACHE_FILE_SIZE_PARAMETER, 0)
            val maxCacheSize = maxCacheSizeNumber.toLong()
            val maxCacheFileSize = maxCacheFileSizeNumber.toLong()
            val uri = getParameter(dataSource, URI_PARAMETER, "")
            val cacheKey = getParameter<String?>(dataSource, CACHE_KEY_PARAMETER, null)
            val formatHint = getParameter<String?>(dataSource, FORMAT_HINT_PARAMETER, null)
            val licenseUrl = getParameter<String?>(dataSource, LICENSE_URL_PARAMETER, null)
            val clearKey = getParameter<String?>(dataSource, DRM_CLEARKEY_PARAMETER, null)
            val drmHeaders: Map<String, String> =
                getParameter(dataSource, DRM_HEADERS_PARAMETER, HashMap())
            player.setDataSource(
                flutterState!!.applicationContext,
                key,
                uri,
                formatHint,
                result,
                headers,
                useCache,
                maxCacheSize,
                maxCacheFileSize,
                overriddenDuration.toLong(),
                licenseUrl,
                drmHeaders,
                cacheKey,
                clearKey
            )
        }
    }

    /**
     * Start pre cache of video.
     *
     * @param call   - invoked method data
     * @param result - result which should be updated
     */
    private fun preCache(call: MethodCall, result: MethodChannel.Result) {
        val dataSource = call.argument<Map<String, Any?>>(DATA_SOURCE_PARAMETER)
        if (dataSource != null) {
            val maxCacheSizeNumber: Number =
                getParameter(dataSource, MAX_CACHE_SIZE_PARAMETER, 100 * 1024 * 1024)
            val maxCacheFileSizeNumber: Number =
                getParameter(dataSource, MAX_CACHE_FILE_SIZE_PARAMETER, 10 * 1024 * 1024)
            val maxCacheSize = maxCacheSizeNumber.toLong()
            val maxCacheFileSize = maxCacheFileSizeNumber.toLong()
            val preCacheSizeNumber: Number =
                getParameter(dataSource, PRE_CACHE_SIZE_PARAMETER, 3 * 1024 * 1024)
            val preCacheSize = preCacheSizeNumber.toLong()
            val uri = getParameter(dataSource, URI_PARAMETER, "")
            val cacheKey = getParameter<String?>(dataSource, CACHE_KEY_PARAMETER, null)
            val headers: Map<String, String> =
                getParameter(dataSource, HEADERS_PARAMETER, HashMap())
            BetterPlayer.preCache(
                flutterState?.applicationContext,
                uri,
                preCacheSize,
                maxCacheSize,
                maxCacheFileSize,
                headers,
                cacheKey,
                result
            )
        }
    }

    /**
     * Stop pre cache video process (if exists).
     *
     * @param call   - invoked method data
     * @param result - result which should be updated
     */
    private fun stopPreCache(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>(URL_PARAMETER)
        BetterPlayer.stopPreCache(flutterState?.applicationContext, url, result)
    }

    private fun clearCache(result: MethodChannel.Result) {
        BetterPlayer.clearCache(flutterState?.applicationContext, result)
    }

    private fun getTextureId(betterPlayer: BetterPlayer): Long? {
        for (index in 0 until videoPlayers.size()) {
            if (betterPlayer === videoPlayers.valueAt(index)) {
                return videoPlayers.keyAt(index)
            }
        }
        return null
    }

    private fun setupNotification(betterPlayer: BetterPlayer) {
        try {
            val textureId = getTextureId(betterPlayer)
            if (textureId != null) {
                val dataSource = dataSources[textureId]
                //Don't setup notification for the same source.
                if (textureId == currentNotificationTextureId && currentNotificationDataSource != null && dataSource != null && currentNotificationDataSource === dataSource) {
                    return
                }
                currentNotificationDataSource = dataSource
                currentNotificationTextureId = textureId
                removeNotificationListeners()

                val showNotification = getParameter(dataSource, SHOW_NOTIFICATION_PARAMETER, false)
                if (showNotification) {
                    val title = getParameter(dataSource, TITLE_PARAMETER, "")
                    val author = getParameter(dataSource, AUTHOR_PARAMETER, "")
                    val imageUrl = getParameter(dataSource, IMAGE_URL_PARAMETER, "")
                    val notificationChannelName =
                        getParameter<String?>(dataSource, NOTIFICATION_CHANNEL_NAME_PARAMETER, null)
                    val activityName =
                        getParameter(dataSource, ACTIVITY_NAME_PARAMETER, "MainActivity")
                    betterPlayer.setupPlayerNotification(
                        flutterState?.applicationContext!!,
                        title, author, imageUrl, notificationChannelName, activityName
                    )
                }
            }
        } catch (exception: Exception) {
            Log.e(TAG, "SetupNotification failed", exception)
        }
    }

    private fun removeNotificationListeners() {
        for (index in 0 until videoPlayers.size()) {
            videoPlayers.valueAt(index).disposeRemoteNotifications()
        }

        flutterState?.applicationContext?.let {
            NotificationManagerCompat.from(it)
                .cancel(BetterPlayer.NOTIFICATION_ID)
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun <T> getParameter(parameters: Map<String, Any?>?, key: String, defaultValue: T): T {
        if (parameters?.containsKey(key) == true) {
            val value = parameters[key]
            if (value != null) {
                return value as T
            }
        }
        return defaultValue
    }


    private fun isPictureInPictureSupported(): Boolean {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && activity != null && activity!!.packageManager
            .hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
    }

    private fun getRectFromCall(call: MethodCall): Rect? {
        val left = call.argument<Double>("left")?.toInt()
        val top = call.argument<Double>("top")?.toInt()
        val width = call.argument<Double>("width")?.toInt()
        val height = call.argument<Double>("height")?.toInt()
        val density = activity!!.resources.displayMetrics.density

        return ifLet(left, top, width, height) { (left, top, width, height) ->
            Rect(left, top, left + width, top + height) * density
        }
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private fun listenToPlayerStateChangesForPIPParams(player: BetterPlayer): Job? {
        val component = activity as? ComponentActivity

        return component?.lifecycleScope?.launch {
            player.isPlaying.collect {
                if (currentPIPPlayer == player || pipPrimary == player) {
                    updatePictureInPictureParams(player)
                }
            }
        }
    }

    @RequiresApi(Build.VERSION_CODES.N)
    private fun setupPIPPrimary(player: BetterPlayer, isPrimary: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return
        if (isInPictureInPictureMode) return

        pipPrimary = if (pipPrimary == player && isPrimary) return
        else if (pipPrimary == player && !isPrimary) null
        else if (isPrimary) player
        else pipPrimary

        Log.v(TAG, "New PIP Primary player set: ${player.hashCode()}")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            updatePictureInPictureParams(pipPrimary)
        }
    }

    private val lastPlayerRects = mutableMapOf<BetterPlayer, Rect?>()
    private fun enablePictureInPicture(player: BetterPlayer, rect: Rect? = null) {
        if (currentPIPPlayer != null) return;

        rect?.let { lastPlayerRects[player] = rect }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            activity!!.enterPictureInPictureMode(
                updatePictureInPictureParams(player)
            )
            startPictureInPictureListenerTimer(player)
            player.onPictureInPictureStatusChanged(true)
            currentPIPPlayer = player
        }
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private fun updatePictureInPictureParams(player: BetterPlayer?): PictureInPictureParams {
        if (player == null) {
            val params = PictureInPictureParams.Builder().build()
            activity!!.setPictureInPictureParams(params)
            return params
        }

        val builder = PictureInPictureParams.Builder()
            .setActions(buildPIPActions(player))

        val rect = lastPlayerRects[player]
        rect?.let {
            Log.v(TAG, "PIP Params: set source rect hint: $it")

            builder.setSourceRectHint(it)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                builder.setSeamlessResizeEnabled(false)
            }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val isAutoEnterEnabled =
                USE_AUTO_PIP_MODE && player.isPlaying.value && pipPrimary == player
            Log.v(TAG, "PIP Params: Set auto enter enabled: $isAutoEnterEnabled")
            builder.setAutoEnterEnabled(isAutoEnterEnabled)
        }

        val params = builder.build()
        activity!!.setPictureInPictureParams(params)
        return params
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private fun buildPIPActions(player: BetterPlayer): List<RemoteAction> {
        val textureId = getTextureId(player) ?: return listOf()

        return listOfNotNull(
            createRemoteAction(
                R.drawable.backward,
                "Seek Backward",
                PIPActionsReceiver.REQUEST_BACKWARD,
                PIPActionsReceiver.CONTROL_TYPE_BACKWARD,
                textureId,
            ),
            if (player.isPlaying.value)
                createRemoteAction(
                    R.drawable.pause,
                    "Pause",
                    PIPActionsReceiver.REQUEST_START_OR_PAUSE,
                    PIPActionsReceiver.CONTROL_TYPE_START_OR_PAUSE,
                    textureId
                )
            else
                createRemoteAction(
                    R.drawable.play,
                    "Play",
                    PIPActionsReceiver.REQUEST_START_OR_PAUSE,
                    PIPActionsReceiver.CONTROL_TYPE_START_OR_PAUSE,
                    textureId
                ),
            createRemoteAction(
                R.drawable.forward,
                "Seek Forward",
                PIPActionsReceiver.REQUEST_FORWARD,
                PIPActionsReceiver.CONTROL_TYPE_FORWARD,
                textureId,
            ),
        )
    }

    private fun disablePictureInPicture(player: BetterPlayer) {
        stopPipHandler()
        activity!!.moveTaskToBack(false)
        player.onPictureInPictureStatusChanged(false)
        currentPIPPlayer = null
    }

    private fun startPictureInPictureListenerTimer(player: BetterPlayer) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            pipHandler = Handler(Looper.getMainLooper())
            pipRunnable = Runnable {
                if (activity!!.isInPictureInPictureMode) {
                    pipHandler!!.postDelayed(pipRunnable!!, 100)
                } else {
                    player.onPictureInPictureStatusChanged(false)
                    stopPipHandler()
                }
            }
            pipHandler!!.post(pipRunnable!!)
        }
    }

    private fun dispose(player: BetterPlayer, textureId: Long) {
        player.dispose()

        videoPlayers.remove(textureId)
        dataSources.remove(textureId)

        if (currentPIPPlayer == player) {
            stopPipHandler()
        }

        videoPlayerListeners.remove(player)?.cancel()

        if (pipPrimary == player) pipPrimary = null
        if (currentPIPPlayer == player) currentPIPPlayer = null
    }

    internal fun getFirstExistingPlayer(predicate: Predicate<BetterPlayer>? = null): BetterPlayer? {
        for (i in 0L..videoPlayers.size()) {
            val player = videoPlayers.get(i)
            if (player != null && (predicate == null || predicate.test(player))) {
                return player
            }
        }

        return null
    }

    private fun stopPipHandler() {
        if (pipHandler != null) {
            pipHandler!!.removeCallbacksAndMessages(null)
            pipHandler = null
        }
        pipRunnable = null
    }

    /**
     * Creates a [RemoteAction]. It is used as an action icon on the overlay of the
     * picture-in-picture mode.
     */
    @RequiresApi(Build.VERSION_CODES.O)
    private fun createRemoteAction(
        @DrawableRes iconResId: Int,
        title: String,
        requestCode: Int,
        controlType: Int,
        textureId: Long
    ): RemoteAction? {
        val activity = this.activity ?: return null

        return PIPActionsReceiver.createRemoteAction(
            activity,
            iconResId,
            title,
            requestCode,
            controlType,
            textureId,
        )
    }

    private interface KeyForAssetFn {
        operator fun get(asset: String?): String
    }

    private interface KeyForAssetAndPackageName {
        operator fun get(asset: String?, packageName: String?): String
    }

    private class FlutterState(
        val applicationContext: Context,
        val binaryMessenger: BinaryMessenger,
        val keyForAsset: KeyForAssetFn,
        val keyForAssetAndPackageName: KeyForAssetAndPackageName,
        val textureRegistry: TextureRegistry?
    ) {
        private val methodChannel: MethodChannel = MethodChannel(binaryMessenger, CHANNEL)

        fun startListening(methodCallHandler: BetterPlayerPlugin?) {
            methodChannel.setMethodCallHandler(methodCallHandler)
        }

        fun stopListening() {
            methodChannel.setMethodCallHandler(null)
        }

    }

    private class UserLeaveHintListenerImpl(private val onUserLeave: Runnable) :
        UserLeaveHintListener {
        override fun onUserLeaveHint() = onUserLeave.run()
    }

    companion object {
        private const val TAG = "BetterPlayerPlugin"
        private const val CHANNEL = "better_player_channel"
        private const val EVENTS_CHANNEL = "better_player_channel/videoEvents"
        private const val DATA_SOURCE_PARAMETER = "dataSource"
        private const val KEY_PARAMETER = "key"
        private const val HEADERS_PARAMETER = "headers"
        private const val USE_CACHE_PARAMETER = "useCache"
        private const val ASSET_PARAMETER = "asset"
        private const val PACKAGE_PARAMETER = "package"
        private const val URI_PARAMETER = "uri"
        private const val FORMAT_HINT_PARAMETER = "formatHint"
        private const val TEXTURE_ID_PARAMETER = "textureId"
        private const val LOOPING_PARAMETER = "looping"
        private const val VOLUME_PARAMETER = "volume"
        private const val LOCATION_PARAMETER = "location"
        private const val SPEED_PARAMETER = "speed"
        private const val WIDTH_PARAMETER = "width"
        private const val HEIGHT_PARAMETER = "height"
        private const val BITRATE_PARAMETER = "bitrate"
        private const val PIP_PRIMARY_PARAMETER = "isPrimary"
        private const val SHOW_NOTIFICATION_PARAMETER = "showNotification"
        private const val TITLE_PARAMETER = "title"
        private const val AUTHOR_PARAMETER = "author"
        private const val IMAGE_URL_PARAMETER = "imageUrl"
        private const val NOTIFICATION_CHANNEL_NAME_PARAMETER = "notificationChannelName"
        private const val OVERRIDDEN_DURATION_PARAMETER = "overriddenDuration"
        private const val NAME_PARAMETER = "name"
        private const val INDEX_PARAMETER = "index"
        private const val LICENSE_URL_PARAMETER = "licenseUrl"
        private const val DRM_HEADERS_PARAMETER = "drmHeaders"
        private const val DRM_CLEARKEY_PARAMETER = "clearKey"
        private const val MIX_WITH_OTHERS_PARAMETER = "mixWithOthers"
        const val URL_PARAMETER = "url"
        const val PRE_CACHE_SIZE_PARAMETER = "preCacheSize"
        const val MAX_CACHE_SIZE_PARAMETER = "maxCacheSize"
        const val MAX_CACHE_FILE_SIZE_PARAMETER = "maxCacheFileSize"
        const val HEADER_PARAMETER = "header_"
        const val FILE_PATH_PARAMETER = "filePath"
        const val ACTIVITY_NAME_PARAMETER = "activityName"
        const val MIN_BUFFER_MS = "minBufferMs"
        const val MAX_BUFFER_MS = "maxBufferMs"
        const val BUFFER_FOR_PLAYBACK_MS = "bufferForPlaybackMs"
        const val BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS = "bufferForPlaybackAfterRebufferMs"
        const val CACHE_KEY_PARAMETER = "cacheKey"
        private const val INIT_METHOD = "init"
        private const val CREATE_METHOD = "create"
        private const val SET_DATA_SOURCE_METHOD = "setDataSource"
        private const val SET_PIP_PRIMARY = "setPIPPrimary"
        private const val SET_LOOPING_METHOD = "setLooping"
        private const val SET_VOLUME_METHOD = "setVolume"
        private const val PLAY_METHOD = "play"
        private const val PAUSE_METHOD = "pause"
        private const val SEEK_TO_METHOD = "seekTo"
        private const val POSITION_METHOD = "position"
        private const val ABSOLUTE_POSITION_METHOD = "absolutePosition"
        private const val SET_SPEED_METHOD = "setSpeed"
        private const val SET_TRACK_PARAMETERS_METHOD = "setTrackParameters"
        private const val SET_AUDIO_TRACK_METHOD = "setAudioTrack"
        private const val SET_PICTURE_IN_PICTURE_OVERLAY_RECT = "setPictureInPictureOverlayRect"
        private const val ENABLE_PICTURE_IN_PICTURE_METHOD = "enablePictureInPicture"
        private const val DISABLE_PICTURE_IN_PICTURE_METHOD = "disablePictureInPicture"
        private const val IS_PICTURE_IN_PICTURE_SUPPORTED_METHOD = "isPictureInPictureSupported"
        private const val SET_MIX_WITH_OTHERS_METHOD = "setMixWithOthers"
        private const val CLEAR_CACHE_METHOD = "clearCache"
        private const val DISPOSE_METHOD = "dispose"
        private const val PRE_CACHE_METHOD = "preCache"
        private const val STOP_PRE_CACHE_METHOD = "stopPreCache"

        internal const val USE_AUTO_PIP_MODE = true


    }
}