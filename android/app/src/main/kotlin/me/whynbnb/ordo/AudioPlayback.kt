package me.whynbnb.ordo

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.media.MediaMetadata
import android.media.MediaPlayer
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.IBinder

/**
 * 全局音频播放持有者：与前台服务同进程，供 MainActivity 直接同步调用。
 * 负责 MediaPlayer、MediaSession（锁屏 / 通知控制）与播放状态回调。
 */
object AudioPlayerHolder {
    private var player: MediaPlayer? = null
    private var session: MediaSession? = null
    private var title: String = ""
    private var prepared: Boolean = false

    /** 播放状态变化时回调，服务用它刷新通知。 */
    var onStateChanged: (() -> Unit)? = null

    fun sessionToken(): MediaSession.Token? = session?.sessionToken

    private fun ensureSession(context: Context) {
        if (session != null) return
        val created = MediaSession(context.applicationContext, "ordo_audio")
        created.setCallback(object : MediaSession.Callback() {
            override fun onPlay() = play()
            override fun onPause() = pause()
            override fun onStop() {
                release()
                onStateChanged?.invoke()
            }

            override fun onSeekTo(pos: Long) = seek(pos.toInt())
        })
        created.isActive = true
        session = created
    }

    fun load(context: Context, path: String, name: String, onPrepared: (Int) -> Unit) {
        release()
        ensureSession(context)
        title = name
        val created = MediaPlayer()
        player = created
        created.setOnPreparedListener { mp ->
            prepared = true
            updateSession()
            onPrepared(mp.duration)
            onStateChanged?.invoke()
        }
        created.setOnErrorListener { mp, _, _ ->
            if (player === mp) player = null
            runCatching { mp.release() }
            onPrepared(-1)
            true
        }
        created.setOnCompletionListener {
            updateSession()
            onStateChanged?.invoke()
        }
        try {
            created.setDataSource(path)
            created.prepareAsync()
        } catch (_: Exception) {
            release()
            onPrepared(-1)
        }
    }

    fun play() {
        val current = player ?: return
        runCatching { current.start() }
        updateSession()
        onStateChanged?.invoke()
    }

    fun pause() {
        val current = player ?: return
        runCatching { if (current.isPlaying) current.pause() }
        updateSession()
        onStateChanged?.invoke()
    }

    fun toggle() {
        if (isPlaying()) pause() else play()
    }

    fun seek(ms: Int) {
        val current = player ?: return
        if (prepared) runCatching { current.seekTo(ms) }
        updateSession()
    }

    fun isPlaying(): Boolean = runCatching { player?.isPlaying == true }.getOrDefault(false)

    fun status(): Map<String, Any?> = mapOf(
        "position" to runCatching { player?.currentPosition ?: 0 }.getOrDefault(0),
        "duration" to runCatching { player?.duration ?: 0 }.getOrDefault(0),
        "playing" to isPlaying(),
    )

    fun currentTitle(): String = title

    fun release() {
        val current = player
        player = null
        prepared = false
        if (current != null) {
            runCatching { if (current.isPlaying) current.stop() }
            runCatching { current.release() }
        }
    }

    fun releaseAll() {
        release()
        runCatching { session?.release() }
        session = null
    }

    private fun updateSession() {
        val current = session ?: return
        current.setMetadata(
            MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, title)
                .build()
        )
        val playing = isPlaying()
        current.setPlaybackState(
            PlaybackState.Builder()
                .setActions(
                    PlaybackState.ACTION_PLAY or
                        PlaybackState.ACTION_PAUSE or
                        PlaybackState.ACTION_PLAY_PAUSE or
                        PlaybackState.ACTION_SEEK_TO or
                        PlaybackState.ACTION_STOP
                )
                .setState(
                    if (playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                    runCatching { player?.currentPosition?.toLong() ?: 0L }.getOrDefault(0L),
                    1f,
                )
                .build()
        )
    }
}

/** 前台服务：保持进程存活并显示带播放控制的媒体通知。 */
class AudioPlaybackService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        AudioPlayerHolder.onStateChanged = { updateNotification() }
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureChannel()
        startForeground(NOTIFICATION_ID, buildNotification())
        when (intent?.action) {
            ACTION_TOGGLE -> AudioPlayerHolder.toggle()
            ACTION_PLAY -> AudioPlayerHolder.play()
            ACTION_PAUSE -> AudioPlayerHolder.pause()
            ACTION_STOP -> {
                AudioPlayerHolder.release()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
        }
        updateNotification()
        return START_STICKY
    }

    override fun onDestroy() {
        AudioPlayerHolder.onStateChanged = null
        if (!AudioPlayerHolder.isPlaying()) AudioPlayerHolder.release()
        super.onDestroy()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "音频播放", NotificationManager.IMPORTANCE_LOW)
            )
        }
    }

    private fun updateNotification() {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        runCatching { manager.notify(NOTIFICATION_ID, buildNotification()) }
    }

    private fun buildNotification(): Notification {
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val toggleIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, AudioPlaybackService::class.java).setAction(ACTION_TOGGLE),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val stopIntent = PendingIntent.getService(
            this,
            2,
            Intent(this, AudioPlaybackService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val playing = AudioPlayerHolder.isPlaying()
        val icon = Icon.createWithResource(this, R.mipmap.ic_launcher)
        val toggleAction = Notification.Action.Builder(
            icon,
            if (playing) "暂停" else "播放",
            toggleIntent,
        ).build()
        val stopAction = Notification.Action.Builder(icon, "停止", stopIntent).build()
        val style = Notification.MediaStyle()
            .setShowActionsInCompactView(0)
        AudioPlayerHolder.sessionToken()?.let { style.setMediaSession(it) }
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(AudioPlayerHolder.currentTitle())
            .setContentText("安序 · 音频播放")
            .setContentIntent(contentIntent)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(playing)
            .addAction(toggleAction)
            .addAction(stopAction)
            .setStyle(style)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "ordo_audio"
        private const val NOTIFICATION_ID = 0x0A0D
        private const val ACTION_TOGGLE = "me.whynbnb.ordo.AUDIO_TOGGLE"
        private const val ACTION_PLAY = "me.whynbnb.ordo.AUDIO_PLAY"
        private const val ACTION_PAUSE = "me.whynbnb.ordo.AUDIO_PAUSE"
        private const val ACTION_STOP = "me.whynbnb.ordo.AUDIO_STOP"

        fun start(context: Context) {
            val intent = Intent(context, AudioPlaybackService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, AudioPlaybackService::class.java))
        }
    }
}
