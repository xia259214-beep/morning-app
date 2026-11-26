package cn.morning.morning

import android.Manifest
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.Settings
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.speech.tts.Voice
import android.util.Base64
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.Locale

/**
 * Flutter 与 Android 原生之间的唯一通道（MethodChannel: morning/native）。
 * 原生负责：闹钟调度、权限、相机、本机语音、本地键值存储、设备信息。
 */
class MainActivity : FlutterActivity() {

    private val channelName = "morning/native"
    private var cameraResult: MethodChannel.Result? = null
    private var permissionResult: MethodChannel.Result? = null
    private var pendingPhoto: File? = null
    private var tts: TextToSpeech? = null

    // v1.15.0 数据搬家：系统文件选择器是异步的（用户可能在网盘里翻半天），
    // 回调结果先挂在这里，onActivityResult 回来再交还给 Dart。
    private var exportResult: MethodChannel.Result? = null
    private var exportPayload: String? = null
    private var importResult: MethodChannel.Result? = null

    // v1.17.0 头像：选图和拍照都是异步的，回调同样先挂在这里。
    // 头像不落盘，直接压成 256×256 的 JPEG 再 base64 交回 Dart ——
    // 这样它跟着 settings 走，换手机时备份里天然就带着。
    private var avatarResult: MethodChannel.Result? = null
    private var pendingAvatarPhoto: File? = null

    /// 预生成播报音频的播放器（见 playSample）
    private var samplePlayer: MediaPlayer? = null
    private var samplePlaying = false

    /**
     * 连续播报队列（见 playQueue）。
     *
     * v1.6.0 之前每条新闻都是「点一下念一条」，念完就停；用户要的是点一次
     * 就一路念下去。串行这件事必须放在原生：MediaPlayer 播完才有 onCompletion，
     * 而 Flutter 侧只能靠「时长 + 缓冲」去猜，猜早了掐掉半句、猜晚了静默好几秒，
     * 换一条音频长度不同就失效。
     */
    private var queueItems: List<QueueItem> = emptyList()
    private var queuePos = -1
    private var queueToken = 0
    private var queuePlayer: MediaPlayer? = null
    private var queueChannel: MethodChannel? = null

    /**
     * v1.9.0：连续播报语速。用户反馈「声音太杂、听着糊」，
     * 除了音频流不统一，0.98 的语速连着念十几条也确实赶。默认放慢到 0.90，
     * 设置页可切慢 / 标准 / 快三档。
     */
    private var speechRate = 0.90f

    private class QueueItem(val sample: String, val text: String)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // v1.9.0 关键修复：把物理音量键绑定到媒体流。
        // 之前播报的「文字」走 USAGE_ALARM、「音频」走 USAGE_MEDIA，两条流互相独立；
        // Activity 又没声明 volumeControlStream，按键调的是铃声音量，
        // 于是按音量键播报纹丝不动，听起来像「音量坏了」。
        // 统一音频流 + 这一行声明，物理音量键就能直接调正在播的声音。
        try {
            setVolumeControlStream(AudioManager.STREAM_MUSIC)
        } catch (e: Exception) {
        }

        // 上次选的播报语速，启动时就取出来。这样 TTS 第一次绑定即用对语速，
        // 不必等 Dart 侧把参数送过来，也避免冷启动第一串念得忽快忽慢。
        try {
            speechRate = (AlarmStore.prefs(this).getString("speechRate", "0.90")
                ?.toFloatOrNull() ?: 0.90f).coerceIn(0.6f, 1.3f)
        } catch (e: Exception) {
        }

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        // 连续播报的进度要主动推给 Flutter（谁在念、还剩几条、念完了没）
        queueChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                // 防御性取参：channel 参数缺 key 时 call.argument 返回 null，
                // 而 SharedPreferences 的 getString/putString 对 null key 会抛 NPE，
                // 异常逃出 handler 会直接崩掉主线程（不是返回 Flutter 错误）。
                "getPref" -> {
                    val key = call.argument<String>("key")
                    if (key.isNullOrEmpty()) {
                        result.success(null)
                    } else {
                        result.success(AlarmStore.prefs(this).getString(key, null))
                    }
                }

                "setPref" -> {
                    val key = call.argument<String>("key")
                    if (key.isNullOrEmpty()) {
                        result.success(false)
                    } else {
                        AlarmStore.prefs(this).edit()
                            .putString(key, call.argument<String>("value") ?: "")
                            .apply()
                        result.success(true)
                    }
                }

                "syncAlarms" -> {
                    // 解析失败时拒绝写入：宁可保留上一份能用的闹钟列表，
                    // 也不能让一次坏 JSON 把 alarms 覆盖成无法解析的字符串——
                    // 那会让 alarms() 返回空表，syncAll 随即取消全部闹钟（用户第二天不响）。
                    val json = call.argument<String>("json") ?: "[]"
                    result.success(AlarmStore.saveRaw(this, json))
                }

                "ringTest" -> {
                    AlarmStore.scheduleTest(this)
                    result.success(true)
                }

                "canScheduleExact" -> result.success(AlarmStore.canExact(this))

                "hasNotificationPermission" -> result.success(hasNotificationPermission())

                "canUseFsi" -> result.success(AlarmStore.canUseFsi(this))

                "isIgnoringBattery" -> result.success(isIgnoringBattery())

                "requestPermission" -> requestPermission(call.argument<String>("what") ?: "", result)

                "openSettings" -> {
                    openSettings(call.argument<String>("target") ?: "")
                    result.success(true)
                }

                "takePhoto" -> takePhoto(result)

                "pickAvatar" -> pickAvatar(result)

                "shootAvatar" -> shootAvatar(result)

                "speak" -> result.success(speak(call.argument<String>("text") ?: ""))

                // v1.9.0：播报语速三档（0.78 / 0.90 / 1.02），设置页可调，
                // 立刻作用于已绑定的引擎，不用重启 App。
                "setSpeechRate" -> {
                    val v = (call.argument<Double>("rate") ?: 0.90)
                        .toFloat().coerceIn(0.6f, 1.3f)
                    speechRate = v
                    try {
                        tts?.setSpeechRate(v)
                    } catch (e: Exception) {
                    }
                    result.success(true)
                }

                // 优先用包里带的真人音色念新闻；返回 ok=false 时上层退回系统 TTS
                "playSample" -> result.success(playSample(call.argument<String>("name") ?: ""))

                // 连续播报：一次传入整串条目，原生串行念完
                "playQueue" -> result.success(playQueue(call.argument<List<*>>("items") ?: emptyList<Any>()))

                // 用系统浏览器打开官方渠道。只放行 https，别的一律拒——
                // 这个入口的参数最终会进 Intent，不设白名单等于把任意跳转发给外部应用。
                "openUrl" -> result.success(openUrl(call.argument<String>("url") ?: ""))

                "stopSpeak" -> {
                    tts?.stop()
                    stopSample()
                    stopQueue()
                    result.success(true)
                }

                // 语音引擎体检结果，给「权限诊断」和播报页做可用性判断
                "ttsStatus" -> result.success(ttsStatus())

                // 强制重建语音引擎：用户点了「重试」时，把失败态彻底清掉再绑一次
                "retryTts" -> {
                    resetTts()
                    initTts()
                    result.success(ttsStatus())
                }

                "deviceInfo" -> result.success(
                    mapOf(
                        "brand" to Build.BRAND.replaceFirstChar { it.uppercase() },
                        "model" to Build.MODEL,
                        "sdk" to Build.VERSION.SDK_INT.toString(),
                        // 版本号从安装包读，避免界面上写死旧版本
                        "version" to try {
                            packageManager.getPackageInfo(packageName, 0).versionName ?: ""
                        } catch (e: Exception) {
                            ""
                        }
                    )
                )

                "consumeLaunchEvent" -> result.success(AlarmStore.consumeEvent(this))

                // 打卡完成 / 主动放弃 / 重置流程时都要撤掉追赶，否则今天会被一直叫回来
                "cancelChase" -> {
                    AlarmStore.cancelChase(this)
                    result.success(true)
                }

                // v1.13.0：打卡成功 → 停掉强制播报、关掉响铃页、清空今天的贪睡额度。
                // 这是「闹钟什么时候才算结束」的唯一出口：铃声和播报都只认这一个回调。
                "stopRing" -> {
                    try {
                        RingActivity.instance?.finishFromCheckin()
                    } catch (e: Exception) {
                        // 响铃页不在时忽略
                    }
                    AlarmStore.cancelRingNotification(this)
                    AlarmStore.resetSnooze(this)
                    result.success(true)
                }

                // 今天还能贪睡几次 / 现在是不是强制播报模式，供 Flutter 界面提示
                "snoozeState" -> result.success(
                    mapOf(
                        "count" to AlarmStore.snoozeCount(this),
                        "max" to AlarmStore.MAX_SNOOZE,
                        "forced" to AlarmStore.isForcedBroadcast(this)
                    )
                )

                // 已经追了几轮，用于流程页顶部提示「第 n 次提醒你还没打卡」
                "chaseRound" -> result.success(AlarmStore.chaseRound(this))

                // v1.11.0 本地崩溃日志（零依赖）：崩溃堆栈追加落盘到 filesDir/crash_log.txt。
                // 超 64KB 直接删掉重记，避免无限膨胀；Bugly 接入后此通道保留作离线兜底。
                "writeCrashLog" -> {
                    try {
                        val f = File(filesDir, "crash_log.txt")
                        if (f.length() > 64 * 1024) f.delete()
                        f.appendText(call.argument<String>("text") ?: "")
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }

                "readCrashLog" -> {
                    try {
                        val f = File(filesDir, "crash_log.txt")
                        result.success(if (f.exists()) f.readText() else "")
                    } catch (e: Exception) {
                        result.success("")
                    }
                }

                "clearCrashLog" -> {
                    try {
                        val f = File(filesDir, "crash_log.txt")
                        if (f.exists()) f.delete()
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }

                // ---------------- v1.15.0 数据搬家 ----------------
                // 导出：只写用户亲手选的那个文件，不扫目录、不留缓存副本。
                "exportData" -> exportData(
                    call.argument<String>("json") ?: "",
                    call.argument<String>("name") ?: "morning-backup.json",
                    result
                )

                // 导入：只读用户亲手选的那一份，不认识类型就当场拒绝。
                "importData" -> importData(result)

                // 分享到微信/网盘/邮件：另一条「送到云端」的路，同样不经过我们的服务器
                "shareData" -> shareData(
                    call.argument<String>("json") ?: "",
                    call.argument<String>("name") ?: "morning-backup.json",
                    result
                )

                // 导入前的自动备份（私有目录，用户看不见，但能一键撤销）
                "saveLocal" -> {
                    try {
                        val dir = File(filesDir, "backups").apply { mkdirs() }
                        File(dir, safeName(call.argument<String>("name") ?: "backup.json"))
                            .writeText(call.argument<String>("json") ?: "")
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }

                "readLocal" -> {
                    try {
                        val f = File(
                            File(filesDir, "backups"),
                            safeName(call.argument<String>("name") ?: "")
                        )
                        result.success(if (f.exists()) f.readText() else null)
                    } catch (e: Exception) {
                        result.success(null)
                    }
                }

                else -> result.notImplemented()
            }
        }

        initTts()
        readRingExtra(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        readRingExtra(intent)
    }

    /**
     * 响铃事件只由 [RingActivity] 写入（用户真的点了「起床」那一刻）。
     *
     * v1.4.1 安全修复：这里原本是 `AlarmStore.pushEvent(this, id)`，
     * 而 MainActivity 必须 exported=true 才能从桌面图标启动 —— 于是任何第三方应用
     * 或 adb 都能 `am start -n cn.morning.morning/.MainActivity --ei alarmId 1`
     * 伪造一次「闹钟已响、我已起床」，直接把用户拖进晨间流程并写进当天日志。
     * 实测确认可复现。
     *
     * 现在这里只做清理，不再采信外部传入的 alarmId；真正的入口在 RingActivity，
     * 那里 exported=false，外部起不来。
     */
    private fun readRingExtra(intent: Intent?) {
        // 仍把残留 extra 摘掉，避免同一个 Intent 被复用后反复命中
        intent?.removeExtra("alarmId")
    }

    // ------------------------------------------------------------ 权限
    private fun hasNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < 33) return true
        return checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
    }

    /** 是否已被加入电池优化白名单（true = 系统不会限制后台） */
    private fun isIgnoringBattery(): Boolean {
        return try {
            val pm = getSystemService(POWER_SERVICE) as android.os.PowerManager
            pm.isIgnoringBatteryOptimizations(packageName)
        } catch (e: Exception) {
            false
        }
    }

    private fun requestPermission(what: String, result: MethodChannel.Result) {
        when (what) {
            // 拍照走系统相机 intent，不需要 CAMERA 权限，这里直接视为已就绪
            "check_camera" -> result.success(true)

            "camera" -> result.success(true)

            "notification" -> {
                if (Build.VERSION.SDK_INT < 33) {
                    result.success(true)
                    return
                }
                permissionResult = result
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 2002)
            }

            else -> result.success(false)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        permissionResult?.success(granted)
        permissionResult = null
    }

    private fun openSettings(target: String) {
        val intent = when (target) {
            "exact_alarm" -> if (Build.VERSION.SDK_INT >= 31) {
                Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:$packageName"))
            } else {
                appDetails()
            }

            "notification" -> Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)

            // Android 14 起「全屏通知」是独立开关；没有它，锁屏不会弹出响铃页
            "fsi" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, Uri.parse("package:$packageName"))
            } else {
                appDetails()
            }

            "battery" -> Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)

            // 直接弹「允许在后台运行」系统对话框，比让用户自己在列表里找少三步
            "battery_request" -> if (Build.VERSION.SDK_INT >= 23) {
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:$packageName")
                )
            } else {
                Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
            }

            // 系统语音合成设置：换引擎、下载中文语音包都在这一页
            "tts" -> Intent("com.android.settings.TTS_SETTINGS")

            else -> appDetails()
        }
        try {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
        } catch (e: Exception) {
            // 个别 ROM 把语音设置页裁掉了，退一步直接拉起「安装语音数据」
            if (target == "tts") {
                try {
                    startActivity(
                        Intent(TextToSpeech.Engine.ACTION_INSTALL_TTS_DATA)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    return
                } catch (e2: Exception) {
                    // 继续往下兜底
                }
            }
            try {
                startActivity(appDetails().addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            } catch (e2: Exception) {
                // 忽略：部分 ROM 缺少对应设置页
            }
        }
    }

    private fun appDetails(): Intent =
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))

    // ------------------------------------------------------------ 相机
    // 走系统相机的 ACTION_IMAGE_CAPTURE，按 Android 官方约定不需要 CAMERA 权限；
    // 反过来，如果 App 自己声明了 CAMERA 却没授予，系统反而会抛 SecurityException。
    // 所以这里不申请权限，从清单里也移除了该权限 —— 用户少一道授权弹窗。
    private fun takePhoto(result: MethodChannel.Result) {
        val dir = File(filesDir, "photos").apply { mkdirs() }
        val file = File(dir, "morning_${System.currentTimeMillis()}.jpg")
        pendingPhoto = file
        cameraResult = result

        val uri = androidx.core.content.FileProvider.getUriForFile(
            this, "$packageName.fileprovider", file
        )
        val intent = Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
            putExtra(MediaStore.EXTRA_OUTPUT, uri)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            startActivityForResult(intent, REQ_CAMERA)
        } catch (e: Exception) {
            cameraResult = null
            result.success(null)
        }
    }

    // ------------------------------------------------------------ 头像
    // v1.17.0：用户说「点进去想换个头像换不了」——之前那块是个写死的图标。
    // 头像只有两种来源：相册里挑一张，或者当场拍一张。两条路都在原生处理成
    // 256×256 的 JPEG 再交给 Dart，不建文件、不用管文件生命周期，
    // 而且它跟着 settings 走，换手机时备份里天然就带着。
    private fun pickAvatar(result: MethodChannel.Result) {
        if (avatarResult != null) {
            // 上一次选择器还开着：直接拒绝，别把回调结果覆盖掉
            result.success(mapOf("ok" to false, "reason" to "busy"))
            return
        }
        avatarResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "image/*"
        }
        try {
            startActivityForResult(intent, REQ_AVATAR_PICK)
        } catch (e: Exception) {
            avatarResult = null
            result.success(mapOf("ok" to false, "reason" to "no_picker"))
        }
    }

    private fun shootAvatar(result: MethodChannel.Result) {
        if (avatarResult != null) {
            result.success(mapOf("ok" to false, "reason" to "busy"))
            return
        }
        val dir = File(cacheDir, "avatar").apply { mkdirs() }
        val file = File(dir, "avatar_${System.currentTimeMillis()}.jpg")
        avatarResult = result
        pendingAvatarPhoto = file
        try {
            val uri = androidx.core.content.FileProvider.getUriForFile(
                this, "$packageName.fileprovider", file
            )
            val intent = Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
                putExtra(MediaStore.EXTRA_OUTPUT, uri)
                addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivityForResult(intent, REQ_AVATAR_CAMERA)
        } catch (e: Exception) {
            // 没有相机 App，或被设备策略禁用：清干净状态，别把回调永远挂住
            avatarResult = null
            pendingAvatarPhoto = null
            result.success(mapOf("ok" to false, "reason" to "no_camera"))
        }
    }

    /**
     * 任意尺寸的图 → 居中裁正方形 → 缩到 AVATAR_PX → JPEG → base64。
     *
     * 大图必须先按 2 的幂采样再解码：一张 5000 万像素的照片直接 decode 会 OOM，
     * 那不是「图太大慢一点」，是进程被系统杀掉。
     */
    private fun avatarFromUri(uri: Uri): Map<String, Any> {
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
                return mapOf("ok" to false, "reason" to "decode")
            }
            var sample = 1
            while (bounds.outWidth / (sample * 2) >= AVATAR_PX &&
                bounds.outHeight / (sample * 2) >= AVATAR_PX
            ) {
                sample *= 2
            }
            val opts = BitmapFactory.Options().apply { inSampleSize = sample }
            val src = contentResolver.openInputStream(uri)?.use {
                BitmapFactory.decodeStream(it, null, opts)
            } ?: return mapOf("ok" to false, "reason" to "decode")

            val side = minOf(src.width, src.height)
            val cropped = Bitmap.createBitmap(
                src, (src.width - side) / 2, (src.height - side) / 2, side, side
            )
            val scaled = Bitmap.createScaledBitmap(cropped, AVATAR_PX, AVATAR_PX, true)
            val out = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.JPEG, AVATAR_QUALITY, out)
            val bytes = out.toByteArray()
            // 及早释放：这几张位图加起来可能几十 MB
            if (src !== cropped) src.recycle()
            if (cropped !== scaled) cropped.recycle()
            scaled.recycle()

            if (bytes.isEmpty()) {
                mapOf("ok" to false, "reason" to "encode")
            } else {
                mapOf(
                    "ok" to true,
                    "b64" to Base64.encodeToString(bytes, Base64.NO_WRAP),
                    "bytes" to bytes.size,
                    "px" to AVATAR_PX
                )
            }
        } catch (e: OutOfMemoryError) {
            mapOf("ok" to false, "reason" to "oom")
        } catch (e: Exception) {
            mapOf("ok" to false, "reason" to "decode")
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            REQ_CAMERA -> {
                val file = pendingPhoto
                pendingPhoto = null
                if (resultCode == RESULT_OK && file != null && file.exists() && file.length() > 0) {
                    cameraResult?.success(file.absolutePath)
                } else {
                    cameraResult?.success(null)
                }
                cameraResult = null
            }
            REQ_EXPORT -> finishExport(resultCode, data?.data)
            REQ_IMPORT -> finishImport(resultCode, data?.data)
            REQ_AVATAR_PICK -> {
                val r = avatarResult
                avatarResult = null
                val uri = data?.data
                r?.success(
                    if (resultCode == RESULT_OK && uri != null) avatarFromUri(uri)
                    else mapOf("ok" to false, "reason" to "cancel")
                )
            }
            REQ_AVATAR_CAMERA -> {
                val r = avatarResult
                val file = pendingAvatarPhoto
                avatarResult = null
                pendingAvatarPhoto = null
                val ok = resultCode == RESULT_OK && file != null && file.exists() && file.length() > 0
                r?.success(
                    if (ok) avatarFromUri(Uri.fromFile(file))
                    else mapOf("ok" to false, "reason" to "cancel")
                )
                // 原图只用来裁头像，留在缓存里没用，还占几十 MB
                try {
                    file?.delete()
                } catch (e: Exception) {
                }
            }
        }
    }

    // ------------------------------------------------------------ 数据搬家
    // 全部走 SAF（Storage Access Framework）：
    //   · 不需要任何存储权限，系统把「选哪个文件」这件事交给用户；
    //   · 选择器里本来就列着网盘和「下载」，所以「存本地」和「存云端」是同一个动作；
    //   · App 只碰用户亲手点过的那一个 Uri，拿不到别的目录。
    private fun exportData(json: String, name: String, result: MethodChannel.Result) {
        if (json.isEmpty()) {
            result.success(mapOf("ok" to false, "reason" to "empty"))
            return
        }
        if (exportResult != null) {
            result.success(mapOf("ok" to false, "reason" to "busy"))
            return
        }
        exportResult = result
        exportPayload = json
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/json"
            putExtra(Intent.EXTRA_TITLE, name)
        }
        try {
            startActivityForResult(intent, REQ_EXPORT)
        } catch (e: Exception) {
            // 部分精简 ROM 没有文档选择器：如实告诉 Dart，让界面提示改用「发送到…」
            exportResult = null
            exportPayload = null
            result.success(mapOf("ok" to false, "reason" to "no_picker"))
        }
    }

    private fun importData(result: MethodChannel.Result) {
        if (importResult != null) {
            result.success(mapOf("ok" to false, "reason" to "busy"))
            return
        }
        importResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            // 有些网盘的 JSON 会被标成 text/plain 甚至 octet-stream，
            // 所以放开 MIME，真正的校验交给 Dart 的 Portable.parse
            type = "*/*"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf("application/json", "text/plain", "application/octet-stream")
            )
        }
        try {
            startActivityForResult(intent, REQ_IMPORT)
        } catch (e: Exception) {
            importResult = null
            result.success(mapOf("ok" to false, "reason" to "no_picker"))
        }
    }

    private fun shareData(json: String, name: String, result: MethodChannel.Result) {
        try {
            val dir = File(cacheDir, "share").apply { mkdirs() }
            val file = File(dir, safeName(name))
            file.writeText(json)
            val uri = androidx.core.content.FileProvider.getUriForFile(
                this, "$packageName.fileprovider", file
            )
            val send = Intent(Intent.ACTION_SEND).apply {
                type = "application/json"
                putExtra(Intent.EXTRA_STREAM, uri)
                putExtra(Intent.EXTRA_SUBJECT, name)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(send, "把备份发到…"))
            result.success(mapOf("ok" to true))
        } catch (e: Exception) {
            result.success(mapOf("ok" to false, "reason" to "share_failed"))
        }
    }

    private fun finishExport(resultCode: Int, uri: Uri?) {
        val res = exportResult ?: return
        val payload = exportPayload
        exportResult = null
        exportPayload = null
        if (resultCode != RESULT_OK || uri == null || payload == null) {
            res.success(mapOf("ok" to false, "reason" to "cancel"))
            return
        }
        try {
            // "wt" = 截断后写。不截断的话，覆盖一个更长的旧文件会留下尾巴，
            // 那份 JSON 就成了半新半旧的垃圾。
            contentResolver.openOutputStream(uri, "wt")?.use { out ->
                out.write(payload.toByteArray(Charsets.UTF_8))
                out.flush()
            } ?: throw IllegalStateException("no stream")
            res.success(mapOf("ok" to true, "name" to displayName(uri)))
        } catch (e: Exception) {
            res.success(mapOf("ok" to false, "reason" to "write_failed"))
        }
    }

    private fun finishImport(resultCode: Int, uri: Uri?) {
        val res = importResult ?: return
        importResult = null
        if (resultCode != RESULT_OK || uri == null) {
            res.success(mapOf("ok" to false, "reason" to "cancel"))
            return
        }
        try {
            // 用 Reader 读，不自己按字节切缓冲：中文在缓冲区边界被切断会变成乱码，
            // 一份几千条流水的备份足够撞上这个概率。
            val text = contentResolver.openInputStream(uri)?.use { input ->
                java.io.BufferedReader(java.io.InputStreamReader(input, Charsets.UTF_8))
                    .readText()
            } ?: throw IllegalStateException("no stream")
            if (text.length > 16 * 1024 * 1024) {
                res.success(mapOf("ok" to false, "reason" to "too_big"))
                return
            }
            res.success(mapOf("ok" to true, "json" to text, "name" to displayName(uri)))
        } catch (e: Exception) {
            res.success(mapOf("ok" to false, "reason" to "read_failed"))
        }
    }

    /// 文件名只留最后一段，别让 `../` 之类的写法跑出应用目录
    private fun safeName(name: String): String {
        val base = File(name).name
        return if (base.isEmpty() || base == "." || base == "..") "backup.json" else base
    }

    private fun displayName(uri: Uri): String {
        return try {
            contentResolver.query(uri, null, null, null, null)?.use { c ->
                val idx = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                if (idx >= 0 && c.moveToFirst()) c.getString(idx) else uri.lastPathSegment ?: ""
            } ?: uri.lastPathSegment ?: ""
        } catch (e: Exception) {
            uri.lastPathSegment ?: ""
        }
    }

    // ------------------------------------------------------------ 语音合成
    // 真机上踩过两个坑：
    //  1) TextToSpeech 是异步绑定引擎的，构造后立刻 speak 必然报 not bound（v1.1.0 已修）；
    //  2) 换一台设备可能根本没有 TTS 引擎，或引擎缺中文语音包 —— 这时既不出声也没有任何
    //     提示，用户只会以为「朗读按钮坏了」。v1.1.2 起把状态显式化：初始化时做一次体检，
    //     把结论交给 Flutter 展示，并提供「去系统语音设置 / 安装语音数据」的入口。
    companion object {
        const val TTS_INIT = "init"
        const val TTS_READY = "ready"
        const val TTS_NO_ENGINE = "no_engine"
        const val TTS_NO_CHINESE = "no_chinese"
        const val TTS_BIND_FAILED = "bind_failed"
        const val TTS_TIMEOUT = "timeout"

        // startActivityForResult 的请求码（相机 1001 是原有约定，不要改）
        private const val REQ_CAMERA = 1001
        private const val REQ_EXPORT = 1002
        private const val REQ_IMPORT = 1003
        private const val REQ_AVATAR_PICK = 1004
        private const val REQ_AVATAR_CAMERA = 1005

        // 头像：256px 够「我的」页那个 46dp 的圆圈用，也够分享时看；
        // 质量 88 时一般 15–30 KB，塞进 settings 不会把备份撑大。
        private const val AVATAR_PX = 256
        private const val AVATAR_QUALITY = 88
    }

    private var ttsReady = false
    private var ttsSpeaking = false
    private var pendingText: String? = null
    private var ttsState = TTS_INIT
    private var ttsDetail = ""
    private val ttsHandler = Handler(Looper.getMainLooper())
    private val ttsTimeout = Runnable {
        if (!ttsReady && ttsState == TTS_INIT) {
            // v1.1.3：超时必须清对象，否则 initTts 第一行就 return，永远无法重试
            resetTts()
            ttsState = TTS_TIMEOUT
            ttsDetail = "语音引擎 6 秒内未就绪"
            // 注意：不清 pendingText，重建后还能补播用户点的那句话
        }
    }

    /**
     * 回到可重试的初始态。这是 v1.1.3 的核心修复：
     * v1.1.2 在绑定失败/超时后只写状态、不清对象，导致 tts != null 永远成立、
     * initTts 第一行就 return，引擎一次失败就被永久钉死，后续每次朗读都失败。
     */
    private fun resetTts() {
        ttsHandler.removeCallbacks(ttsTimeout)
        try {
            tts?.stop()
        } catch (e: Exception) {
        }
        try {
            tts?.shutdown()
        } catch (e: Exception) {
        }
        tts = null
        ttsReady = false
        ttsSpeaking = false
        ttsState = TTS_INIT
        ttsDetail = ""
    }

    /**
     * 系统里有没有任何语音合成引擎。
     * Android 11 起查包受可见性限制，清单里声明了 <queries> 才能看到 TTS 服务。
     */
    private fun hasTtsEngine(): Boolean {
        return try {
            packageManager.queryIntentServices(
                Intent(TextToSpeech.Engine.INTENT_ACTION_TTS_SERVICE), 0
            ).isNotEmpty()
        } catch (e: Exception) {
            // 查不到就不拦，交给绑定结果判定
            true
        }
    }

    private fun initTts() {
        if (tts != null) return
        // v1.1.3：这里原本还有一行
        //   if (ttsState == TTS_NO_ENGINE || ttsState == TTS_BIND_FAILED) return
        // 它让「无引擎 / 绑定失败」变成终态，用户装好语音引擎后必须杀进程才能恢复。已删除。

        // 体检第一步：系统里到底有没有装任何语音合成引擎（查系统服务，不用先构造 TTS）
        if (!hasTtsEngine()) {
            ttsState = TTS_NO_ENGINE
            ttsDetail = "系统未安装任何语音合成引擎"
            pendingText = null
            return
        }

        ttsState = TTS_INIT
        tts = TextToSpeech(this) { status ->
            ttsHandler.removeCallbacks(ttsTimeout)
            val engine = tts
            if (status != TextToSpeech.SUCCESS || engine == null) {
                // 关键修复：先清对象再落状态，否则后面永远重试不了
                resetTts()
                ttsState = TTS_BIND_FAILED
                ttsDetail = "语音引擎绑定失败（status=$status）"
                return@TextToSpeech
            }
            engine.setSpeechRate(speechRate)
            // v1.9.0：播报统一走媒体流，和包里的 mp3（USAGE_MEDIA）完全一致。
            // 原来这里写的是 USAGE_ALARM，本意是「媒体静音也能出声」，但代价是：
            //   1) 一串播报里 mp3 与 TTS 分属两条流，音量一大一小、听着「杂」；
            //   2) 物理音量键调不到 ALARM 流，用户以为音量坏了；
            //   3) mediaVolume() 查的是媒体流，静音提醒因此是错的。
            // 闹钟响铃仍走 USAGE_ALARM（在 RingActivity / AlarmStore 里），不受影响。
            try {
                engine.setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                )
            } catch (e: Exception) {
            }
            try {
                engine.setPitch(1.0f)
            } catch (e: Exception) {
            }
            // v1.12.1：从引擎可用音色里挑中文女声。为什么挑：真实新闻没有随包真人录音，
            // 会退回系统 TTS；而小米等引擎的默认音色单薄刺耳（用户反馈「太空、太刺耳」）。
            // 挑不出来时保持引擎默认，宁可不动也别换一个更差的。
            // v1.22.7：挑音色挪到 setLanguage 体检之后——setLanguage 会把音色
            // 重置回该语言的默认，先 setVoice 再 setLanguage 等于白挑一遍，
            // 这就是「好声音又变回机械音」的根源：挑了个寂寞。

            // 合成进度监听：真机排查全靠它。onStart 出现说明引擎接单了，
            // onError 带错误码说明引擎接单但合成失败（缺语音包最常见）。
            engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) {
                    Log.i("MorningTts", "onStart $utteranceId")
                    ttsSpeaking = true
                }

                override fun onDone(utteranceId: String?) {
                    Log.i("MorningTts", "onDone $utteranceId")
                    ttsSpeaking = false
                    // 连续播报里 TTS 念完一条，接着念下一条
                    if (utteranceId != null && utteranceId.startsWith("q")) {
                        onQueueUtteranceDone(utteranceId)
                    }
                }

                @Deprecated("Deprecated in Java")
                override fun onError(utteranceId: String?) {
                    Log.e("MorningTts", "onError $utteranceId")
                    ttsSpeaking = false
                    // 引擎挂了要允许下次重建，否则会一直卡在 ready 状态假装能读
                    ttsReady = false
                }

                override fun onError(utteranceId: String?, errorCode: Int) {
                    Log.e("MorningTts", "onError $utteranceId code=$errorCode")
                    ttsSpeaking = false
                    ttsReady = false
                }
            })

            // 体检第二步：依次试 简体中文 → 通用中文 → 系统默认，任一可用即算就绪
            var langOk = false
            for (loc in listOf(Locale.SIMPLIFIED_CHINESE, Locale.CHINESE, Locale.getDefault())) {
                val r = engine.setLanguage(loc)
                if (r != TextToSpeech.LANG_MISSING_DATA &&
                    r != TextToSpeech.LANG_NOT_SUPPORTED &&
                    r != TextToSpeech.ERROR
                ) {
                    langOk = true
                    break
                }
            }
            if (!langOk) {
                val name = engine.defaultEngine ?: "?"
                resetTts()
                ttsState = TTS_NO_CHINESE
                ttsDetail = "引擎 $name 缺少中文语音数据"
                return@TextToSpeech
            }

            // v1.22.7：setLanguage 体检完再挑音色——顺序不能反，
            // setLanguage 会把 setVoice 的结果冲回默认音色。
            try {
                val picked: Voice? = pickBestVoice(engine)
                if (picked != null && engine.setVoice(picked) == TextToSpeech.SUCCESS) {
                    Log.i("MorningTts", "voice=${picked.name} quality=${picked.quality}")
                } else {
                    Log.i("MorningTts", "voice=default（没有合适的本地中文音色）")
                }
            } catch (e: Exception) {
            }

            ttsState = TTS_READY
            ttsDetail = engine.defaultEngine ?: ""
            ttsReady = true
            pendingText?.let { t ->
                pendingText = null
                doSpeak(t)
            }
        }
        ttsHandler.postDelayed(ttsTimeout, 6000)
    }

    /** 返回 {ok, state}：ok=false 时 Dart 侧会引导用户去装语音引擎，而不是静默失败 */
    /**
     * 播放随包分发的播报音频。
     *
     * 为什么不用系统 TTS：音色由各家引擎决定，同一段文字在小米、华为、平板上
     * 声音完全不同。用户要的是「和电脑里那个声音一样」，唯一能保证一致的做法
     * 是把音频本身带在包里。
     *
     * assets 里没有对应文件时返回 ok=false，由 Dart 侧退回系统 TTS——
     * 新闻条数以后还会变，不能让新增条目变成哑巴。
     */
    /**
     * 把 assets 里的音频解到 cache 再返回文件。
     *
     * 为什么先解到 cache：openFd 要求资源未压缩，而压缩状态由打包配置决定，
     * 解一次以后就直接读文件，不受这个前提约束。
     *
     * 先写临时文件再改名：上一次解压如果被中途杀掉，会留下一个长度正常但内容
     * 截断的 mp3，那种文件 MediaPlayer 打不开，而 length>0 又骗过了存在性检查
     * ——结果每一条都悄悄退回系统音色。
     */
    /**
     * 从引擎可用音色里挑最适合播报的中文女声。
     *
     * 为什么挑：真实新闻条目没有随包真人录音，只能走系统 TTS，而默认音色
     * 在小米等引擎上单薄刺耳（用户反馈「太空、太刺耳」）。
     * 挑选优先级：本地中文女声 > 本地中文 > 什么都不选（保持引擎默认）。
     * 只挑本地音色：需要联网的音色在断网早上会变哑巴，违背离线可用的底线。
     */
    private fun pickBestVoice(engine: TextToSpeech): Voice? {
        val all = try {
            engine.voices ?: return null
        } catch (e: Exception) {
            return null
        }
        val zh = all.filter {
            // fallback 音色的 locale 一般是 eng，zh 过滤已能排除；不直接用
            // Voice.isFallback()，该 API 在部分编译目标下无法解析
            it.locale?.language == "zh" && !it.isNetworkConnectionRequired
        }
        if (zh.isEmpty()) return null
        // v1.22.7：候选先按音质降序排——同一个女声名下常有多个档位，
        // 不排序的话 firstOrNull 会挑到音质最差的那档。
        val byQuality = zh.sortedByDescending { it.quality }
        // 诊断：把引擎的全部音色（含联网音色）都打出来，真机排查全靠它
        Log.i("MorningTts", "all voices=${all.joinToString { v -> "${v.name}|${v.locale}|q${v.quality}|net=${v.isNetworkConnectionRequired}" }}")
        // 讯飞/小米/谷歌各家中文女声的常见命名：小燕、小晓、小爱、female…
        val femaleHints = listOf(
            "xiaoyan", "xiaoxiao", "xiaoyu", "xiaomei", "xiaoai", "xiaoyun",
            "female", "woman", "f_", "-f-", "_f", "luna", "meijia"
        )
        // 名字命中女声的排最前；都命中时 quality 高的先出（byQuality 已排序）
        val female = byQuality.filter { v ->
            val n = v.name.lowercase()
            femaleHints.any { n.contains(it) }
        }
        // 引擎不按女声命名时（如 mibrain 用「晓晓·聆听版」这类中文），退而求
        // 其次按音质挑：quality 500+ 的「高清档」比默认档耐听得多。
        val hiQuality = byQuality.filter { it.quality >= 500 }
        Log.i("MorningTts", "zh voices=${byQuality.map { "${it.name}(q${it.quality})" }}")
        return female.firstOrNull()
            ?: hiQuality.firstOrNull()
            ?: byQuality.firstOrNull { it.locale.country == "CN" }
            ?: byQuality.first()
    }

    private fun sampleFile(name: String): File? {
        return try {
            val f = File(cacheDir, "tts_$name.mp3")
            if (!f.exists() || f.length() == 0L) {
                val tmp = File(cacheDir, "tts_$name.mp3.tmp")
                try {
                    assets.open("tts/$name.mp3").use { input ->
                        tmp.outputStream().use { out -> input.copyTo(out) }
                    }
                    if (!tmp.renameTo(f)) {
                        tmp.copyTo(f, overwrite = true)
                        tmp.delete()
                    }
                } catch (e: Exception) {
                    tmp.delete()
                    return null
                }
            }
            if (f.length() == 0L) null else f
        } catch (e: Exception) {
            null
        }
    }

    private fun playSample(name: String): Map<String, Any> {
        // 只接受 n01..n99 / l01..l99 的固定形态。这个名字会被拼进 asset 路径和 cache
        // 文件名，放任任意字符串等于允许 ".." 之类的路径片段进来。
        if (!sampleName.matches(name)) {
            return mapOf("ok" to false, "reason" to "bad_name")
        }
        val assetPath = "tts/$name.mp3"
        var mp: MediaPlayer? = null
        return try {
            stopSample()
            // 单条播放要掐掉正在跑的整串，否则两个声音叠在一起
            stopQueue()
            val f = sampleFile(name)
                ?: return mapOf("ok" to false, "reason" to "missing")
            mp = MediaPlayer()
            mp.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            mp.setDataSource(f.absolutePath)
            mp.setOnCompletionListener {
                samplePlaying = false
                it.release()
                if (samplePlayer === it) samplePlayer = null
            }
            mp.prepare()
            mp.start()
            samplePlayer = mp
            samplePlaying = true
            mapOf("ok" to true, "duration" to mp.duration, "mediaVolume" to mediaVolume())
        } catch (e: Exception) {
            // 失败时必须把半初始化的 player 释放掉：prepare 抛异常时它已经
            // 占了一个 native 解码器，连着点几次就能把 MediaPlayer 池耗光。
            try {
                mp?.release()
            } catch (_: Exception) {
            }
            Log.w("MorningTts", "playSample $assetPath 失败", e)
            mapOf("ok" to false, "reason" to (e.message ?: "error"))
        }
    }

    private fun stopSample() {
        try {
            samplePlayer?.let {
                if (it.isPlaying) it.stop()
                it.release()
            }
        } catch (_: Exception) {
        }
        samplePlayer = null
        samplePlaying = false
    }

    // ========================================================================
    // 连续播报队列
    // ========================================================================

    /** 包里音频的合法名字：n01..n99 是新闻，l01..l99 是本地条目 */
    private val sampleName = Regex("[nl]\\d{2}")

    private val queueHandler = Handler(Looper.getMainLooper())

    /**
     * 整串一起念。[items] 每项要么 {"sample":"n03"} 要么 {"text":"…"}。
     * 返回 ok=false 时 Flutter 侧不亮「正在播报」，并把 reason 翻成人话告诉用户。
     */
    private fun playQueue(items: List<*>): Map<String, Any> {
        stopQueue()
        if (items.isEmpty()) return mapOf("ok" to false, "reason" to "empty")

        val parsed = ArrayList<QueueItem>(items.size)
        for (o in items) {
            val m = o as? Map<*, *> ?: continue
            val s = ((m["sample"] as? String) ?: "").trim()
            val t = ((m["text"] as? String) ?: "").trim()
            if (s.isNotEmpty()) {
                // 和 playSample 同一条理由：这个名字会拼进文件名，必须限定形态
                if (sampleName.matches(s)) parsed.add(QueueItem(s, ""))
            } else if (t.isNotEmpty()) {
                parsed.add(QueueItem("", t))
            }
        }
        if (parsed.isEmpty()) return mapOf("ok" to false, "reason" to "bad_items")

        // 媒体音量为 0 时一路念下去也是白念，早点告诉用户
        if (mediaVolume() == 0) return mapOf("ok" to false, "reason" to "muted")

        queueItems = parsed
        queuePos = -1
        val token = ++queueToken
        emit("begin", -1, parsed.size)
        playNext(token)
        return mapOf("ok" to true, "total" to parsed.size)
    }

    private fun playNext(token: Int) {
        if (token != queueToken) return
        queuePos += 1
        if (queuePos >= queueItems.size) {
            val total = queueItems.size
            queueItems = emptyList()
            queuePos = -1
            emit("done", -1, total)
            return
        }
        val item = queueItems[queuePos]
        emit("start", queuePos, queueItems.size)

        if (item.sample.isNotEmpty()) {
            playQueueSample(item.sample, token)
        } else {
            speakQueued(item.text, token, queuePos)
        }
    }

    private fun playQueueSample(name: String, token: Int) {
        val f = sampleFile(name)
        if (f == null) {
            queueHandler.postDelayed({ playNext(token) }, 300)
            return
        }
        try {
            val mp = MediaPlayer()
            mp.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            mp.setDataSource(f.absolutePath)
            mp.setOnCompletionListener {
                try {
                    it.release()
                } catch (_: Exception) {
                }
                if (queuePlayer === it) queuePlayer = null
                // 条与条之间留一口气：连续念时不喘气会像一串没有标点的句子
                if (token == queueToken) queueHandler.postDelayed({ playNext(token) }, 420)
            }
            mp.setOnErrorListener { p, _, _ ->
                try {
                    p.release()
                } catch (_: Exception) {
                }
                if (queuePlayer === p) queuePlayer = null
                if (token == queueToken) queueHandler.postDelayed({ playNext(token) }, 300)
                true
            }
            mp.prepare()
            mp.start()
            queuePlayer = mp
        } catch (e: Exception) {
            Log.w("MorningTts", "队列播放 $name 失败", e)
            queueHandler.postDelayed({ playNext(token) }, 300)
        }
    }

    /** 没有预生成音频的条目退回系统 TTS。引擎是异步绑定的，这里最多等 2.5 秒再跳过。 */
    private fun speakQueued(text: String, token: Int, pos: Int, attempt: Int = 0) {
        if (token != queueToken) return
        val engine = tts
        if (engine == null || !ttsReady) {
            if (attempt == 0) initTts()
            if (attempt < 10) {
                queueHandler.postDelayed({ speakQueued(text, token, pos, attempt + 1) }, 250)
                return
            }
            // 引擎起不来：跳过这一条，不能把整串卡死在这里
            emit("skip", pos, queueItems.size)
            playNext(token)
            return
        }
        val id = "q$token-$pos"
        val ok = try {
            engine.speak(text, TextToSpeech.QUEUE_FLUSH, null, id) == TextToSpeech.SUCCESS
        } catch (e: Exception) {
            false
        }
        if (!ok) {
            emit("skip", pos, queueItems.size)
            queueHandler.postDelayed({ playNext(token) }, 300)
        }
    }

    /** TTS 念完一条，接着念下一条 */
    private fun onQueueUtteranceDone(utteranceId: String) {
        if (utteranceId != "q$queueToken-$queuePos") return
        val token = queueToken
        queueHandler.postDelayed({ playNext(token) }, 420)
    }

    private fun stopQueue() {
        // token 先加一：所有还在飞的 postDelayed 回调都会立刻失效，
        // 否则「停止」之后还可能冒出下一条的声音。
        queueToken += 1
        queueItems = emptyList()
        queuePos = -1
        // v1.9.0：原来这里只 release 了 mp3 播放器，没停 TTS。
        // 重新点一次「连续播报」时，上一条还在念的 TTS 不会立刻停，
        // 会和新串的第一条叠在一起 —— 这正是「声音太杂」的一个真实来源。
        try {
            tts?.stop()
        } catch (_: Exception) {
        }
        try {
            queuePlayer?.let {
                if (it.isPlaying) it.stop()
                it.release()
            }
        } catch (_: Exception) {
        }
        queuePlayer = null
    }

    /** 状态推给 Flutter：begin / start / skip / done */
    private fun emit(event: String, index: Int, total: Int) {
        try {
            queueChannel?.invokeMethod(
                "onPlayState",
                mapOf("event" to event, "index" to index, "total" to total)
            )
        } catch (_: Exception) {
        }
    }

    /** 只用系统浏览器打开官方渠道；只放行 https */
    private fun openUrl(url: String): Boolean {
        if (!url.startsWith("https://")) return false
        return try {
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun speak(text: String): Map<String, Any> {
        if (text.isEmpty()) return mapOf("ok" to false, "state" to ttsState)

        // 对象还在但已不就绪（onError 之后最常见）：先彻底重置，
        // 否则 initTts 第一行就会因为 tts != null 直接返回，永远重建不了。
        if (tts != null && !ttsReady) {
            resetTts()
        }

        if (ttsReady && tts != null) {
            if (doSpeak(text)) return mapOf("ok" to true, "state" to ttsState)
            // 引擎心跳失败（被系统回收 / 音频通道被占）：留一句话，重建后补播
            pendingText = text
            resetTts()
            initTts()
            return mapOf(
                "ok" to (ttsState == TTS_INIT),
                "state" to ttsState,
                "detail" to ttsDetail,
                "mediaVolume" to mediaVolume()
            )
        }

        pendingText = text
        initTts()
        // 体检若当场判死（无引擎 / 缺中文数据），这轮播不出去
        val accepted = ttsState == TTS_INIT || ttsState == TTS_READY
        if (!accepted) pendingText = null
        return mapOf(
            "ok" to accepted,
            "state" to ttsState,
            "detail" to ttsDetail,
            "mediaVolume" to mediaVolume()
        )
    }

    /** 媒体音量索引。Dart 侧在 ==0 时提示「被静音了」，省得用户对着没声音的文本发呆。 */
    private fun mediaVolume(): Int {
        return try {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            am.getStreamVolume(AudioManager.STREAM_MUSIC)
        } catch (e: Exception) {
            -1
        }
    }

    private fun ttsStatus(): Map<String, Any> {
        if (tts == null) initTts()
        return mapOf(
            "state" to ttsState,
            "ready" to ttsReady,
            "speaking" to ttsSpeaking,
            "engine" to (tts?.defaultEngine ?: ""),
            "detail" to ttsDetail,
            "mediaVolume" to mediaVolume()
        )
    }

    private fun doSpeak(text: String): Boolean {
        val t = tts ?: return false
        return try {
            val id = "morning-${System.currentTimeMillis()}"
            t.speak(text, TextToSpeech.QUEUE_FLUSH, null, id) == TextToSpeech.SUCCESS
        } catch (e: Exception) {
            // 引擎异常时静默，不打断晨间流程
            false
        }
    }

    // 关键修复：熄屏一夜后系统往往把语音引擎回收了，第二天点朗读就是「语音不可用」。
    // 回到前台时自检一次，坏了就地重建，用户不必杀进程。
    override fun onResume() {
        super.onResume()
        if (tts != null && !ttsReady) {
            resetTts()
            initTts()
        }
    }

    override fun onDestroy() {
        resetTts()
        stopSample()
        stopQueue()
        pendingText = null
        super.onDestroy()
    }
}
