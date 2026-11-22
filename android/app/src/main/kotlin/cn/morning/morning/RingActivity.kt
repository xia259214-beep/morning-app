package cn.morning.morning

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.TextView
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 全屏响铃页。
 * 用原生 Activity 而不是 Flutter 页面，为了在锁屏 / 息屏 / 冷启动时最快弹出，
 * 不依赖 Flutter 引擎初始化完成。
 */
class RingActivity : Activity() {

    companion object {
        /** 响铃页是否正开着，供兜底接收器判断，避免重复弹页 */
        @Volatile
        var isShowing = false

        /** 当前实例。打卡完成后由 Flutter 侧调 stopRing 让它收尾（停播报、关页） */
        @Volatile
        var instance: RingActivity? = null

        /** 强制播报进行中。接收器靠它判断保活闹钟要不要继续拉页 */
        @Volatile
        var broadcastActive = false
    }

    private var ringtone: Ringtone? = null
    private var vibrator: Vibrator? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private val handler = Handler(Looper.getMainLooper())
    private var alarmId = 0
    private var label = "晨间唤醒"
    private var snoozeMinutes = 5
    private var stopped = false
    /** 已尝试把页面顶到锁屏之上几次，防止无焦点时死循环重试 */
    private var reassertCount = 0

    // ---------------------------------------------------------------- 强制播报
    /** 第二次响铃（贪睡额度用完）走这里：念新闻，不给贪睡，只能拍照解除 */
    private var broadcastMode = false
    private var tts: TextToSpeech? = null
    private var newsLines: List<String> = emptyList()

    /**
     * 已交接给打卡流程。点「我已出门」后置 true：抢焦点的循环和保活闹钟都要停，
     * 否则打卡页刚打开就被响铃页压回去，两边永远打架。
     * 播报声音继续，直到打卡成功由 stopRing 收尾。
     */
    private var handoff = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        applyShowWhenLocked()
        // 主动点亮屏幕：setTurnScreenOn 在部分 ROM 上会被忽略，
        // 实测出现过「页面已经在前台，但系统仍报 Asleep」的情况，必须自己兜一层。
        wakeScreen()
        try {
            val km = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) km.requestDismissKeyguard(this, null)
        } catch (e: Exception) {
            // 部分 ROM 不支持免密解锁，忽略
        }

        setContentView(R.layout.activity_ring)

        alarmId = intent.getIntExtra("alarmId", 0)
        label = intent.getStringExtra("label") ?: AlarmStore.labelOf(this, alarmId)
        snoozeMinutes = intent.getIntExtra("snoozeMinutes", AlarmStore.snoozeOf(this, alarmId))

        isShowing = true
        instance = this
        // 「仅一次」闹钟在这里关掉：主链路已由系统直接拉起 Activity，不再经过广播
        if (alarmId > 0) AlarmStore.disableOnce(this, alarmId)
        // 注意：这里绝不能撤掉那条全屏通知。
        // 实测（小米 HyperOS 3）：一旦把「带着全屏意图的那条通知」取消，系统会判定
        // 弹页资格消失，随即把锁屏重新盖到本页之上（层级 NotificationShade > RingActivity），
        // 用户看到的就是一张黑屏。通知保留到用户点「起床 / 贪睡」时再撤。

        findViewById<TextView>(R.id.timeText).text =
            SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date())
        bindTexts()

        findViewById<Button>(R.id.wakeBtn).setOnClickListener { goMorning() }
        applySnoozeButton()

        startRinging()

        // v1.13.5：贪睡额度用完 → 第二次响铃直接进强制播报。
        // 判断放在页面里而不是 Intent 里，是为了让「从通知点进来 / 系统 FSI 拉起」
        // 这两条路径都自动得到同一个结论——参数少一个，漏传的机会就少一个。
        if (AlarmStore.isForcedBroadcast(this)) enterBroadcastMode()

        // 首次弹页兜底：HyperOS 3 实测会出现「本页已是前台 Activity、mKeyguardOccluded=true，
        // 但锁屏遮罩仍压在它上面并抢走焦点」的状态，用户看到的就是一片黑。
        // 重新申明一次「锁屏上显示」，等于让系统重算一次遮挡关系，页面才会真正升上去。
        handler.postDelayed({ reassertOverKeyguard() }, 400)
    }

    override fun onResume() {
        super.onResume()
        applyShowWhenLocked()
    }

    /** 在锁屏之上显示的窗口标志，多处复用 */
    private fun applyShowWhenLocked() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
        window.addFlags(
            WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
        )
    }

    /**
     * 把本页重新顶到锁屏之上；拿到焦点即止。
     *
     * v1.13.0 播报模式加强：没有「放弃」这个概念——权限弹窗、MIUI 首次语音授权、
     * 甚至按 Home 键回到桌面，都会在 1.2 秒内被拉回播报页。
     * 这是「播报不能被打断、关掉也不可以」的落地：只有拍完照，这个循环才会停。
     * 真机实测踩过的坑：MIUI 语音引擎首次使用会弹两层系统授权框，弹窗消失后
     * 系统把焦点还给了底下的 App 而不是本页——不拽回来，播报页就被埋在后台了。
     */
    private fun reassertOverKeyguard() {
        if (stopped || isFinishing || handoff) return
        if (hasWindowFocus()) {
            android.util.Log.d("MorningRing", "reassert: 已获得焦点，停止重试 (count=$reassertCount)")
            return
        }
        if (!broadcastMode && reassertCount >= 6) return
        reassertCount++
        android.util.Log.d("MorningRing", "reassert#$reassertCount 焦点不在本页，重新申明 showWhenLocked")
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                // 先撤再申明，触发系统重新判定一次「锁屏是否被本页遮挡」
                setShowWhenLocked(false)
                setShowWhenLocked(true)
                setTurnScreenOn(true)
            }
            window.decorView.requestFocus()
            val km = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
            km.requestDismissKeyguard(this, null)
        } catch (e: Exception) {
            // 厂商限制时忽略，下一轮再试
        }
        if (broadcastMode) bringTaskToFront()
        handler.postDelayed({ reassertOverKeyguard() }, if (broadcastMode) 1200 else 900)
    }

    /** 把响铃页所在任务挪回前台（需要 REORDER_TASKS，普通权限） */
    private fun bringTaskToFront() {
        try {
            val am = getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
            for (t in am.appTasks) {
                if (t.taskInfo.baseIntent.component?.className == RingActivity::class.java.name) {
                    t.moveToFront()
                    break
                }
            }
        } catch (e: Exception) {
            // 拉不回来就等下一轮
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        // 焦点被锁屏遮罩抢走时，下一拍再抢回来
        if (!hasFocus && !stopped) handler.postDelayed({ reassertOverKeyguard() }, 500)
    }

    /** 主动点亮屏幕 30 秒；到点自动释放，不会长期持有 */
    @Suppress("DEPRECATION")
    private fun wakeScreen() {
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            val lock = pm.newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or
                    PowerManager.ACQUIRE_CAUSES_WAKEUP or
                    PowerManager.ON_AFTER_RELEASE,
                "morning:ring"
            )
            lock.acquire(30_000L)
            wakeLock = lock
        } catch (e: Exception) {
            // 厂商限制时忽略，系统的 turnScreenOn 仍会尝试
        }
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.takeIf { it.isHeld }?.release()
        } catch (e: Exception) {
            // 忽略
        }
        wakeLock = null
    }

    private fun bindTexts() {
        findViewById<TextView>(R.id.labelText).text = label
        findViewById<TextView>(R.id.hintText).text =
            "该起床了 · 闹钟编号 ${if (alarmId < 0) "测试" else alarmId}"
    }

    /**
     * 贪睡按钮：一天一次机会（v1.13.5 收紧为一次——第一次响可以再睡 5 分钟，
     * 第二次响就直接进播报，见 [enterBroadcastMode]）。
     *
     * 用完额度后第二次响铃不会走到这里——[enterBroadcastMode] 已经把按钮藏掉了。
     * 这里保留禁用分支，只防一种情况：用户在响铃页面上停留很久，
     * 期间另一个闹钟把额度用掉了，此时按钮必须立刻变成不可点，而不是点了没反应。
     */
    private fun applySnoozeButton() {
        val b = findViewById<Button>(R.id.snoozeBtn)
        val left = (AlarmStore.MAX_SNOOZE - AlarmStore.snoozeCount(this)).coerceAtLeast(0)
        if (left > 0) {
            b.isEnabled = true
            b.alpha = 1f
            b.text = if (AlarmStore.MAX_SNOOZE > 1)
                "贪睡 $snoozeMinutes 分钟（今天还剩 $left 次）"
            else
                "贪睡 $snoozeMinutes 分钟（再睡就没机会了）"
            b.setOnClickListener { snooze() }
        } else {
            b.isEnabled = false
            b.alpha = 0.45f
            b.text = "今天已经贪睡过了，去打卡吧"
            b.setOnClickListener(null)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // 播报模式不允许新的响铃意图改写页面：按钮、文案都得保持「只能拍照」
        if (broadcastMode) return
        setIntent(intent)
        val id = intent.getIntExtra("alarmId", Int.MIN_VALUE)
        if (id == Int.MIN_VALUE || id == alarmId) return
        alarmId = id
        label = intent.getStringExtra("label") ?: AlarmStore.labelOf(this, id)
        snoozeMinutes = intent.getIntExtra("snoozeMinutes", AlarmStore.snoozeOf(this, id))
        bindTexts()
        applySnoozeButton()
    }

    private fun startRinging() {
        try {
            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            val r = RingtoneManager.getRingtone(this, uri)
            r?.audioAttributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ALARM)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) r?.isLooping = true
            r?.play()
            ringtone = r
        } catch (e: Exception) {
            // 铃声不可用时仍然振动提醒
        }

        try {
            vibrator = getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            val pattern = longArrayOf(0, 700, 500, 700, 1200)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibrator?.vibrate(VibrationEffect.createWaveform(pattern, 0))
            } else {
                @Suppress("DEPRECATION")
                vibrator?.vibrate(pattern, 0)
            }
        } catch (e: Exception) {
            // 忽略
        }

        // 部分机型 isLooping 不生效，这里做一次自愈式重播
        val tick = object : Runnable {
            override fun run() {
                if (stopped || broadcastMode) return
                try {
                    if (ringtone?.isPlaying != true) ringtone?.play()
                } catch (e: Exception) {
                    // 忽略
                }
                handler.postDelayed(this, 2500)
            }
        }
        handler.postDelayed(tick, 2500)
    }

    private fun stopRinging() {
        stopped = true
        handler.removeCallbacksAndMessages(null)
        try {
            ringtone?.stop()
        } catch (e: Exception) {
            // 忽略
        }
        ringtone = null
        try {
            vibrator?.cancel()
        } catch (e: Exception) {
            // 忽略
        }
        AlarmStore.cancelRingNotification(this)
    }

    private fun goMorning() {
        stopRinging()
        // 双保险：接收器那边已撤，这里再撤一次。漏撤的后果是起床后又被叫一次。
        if (alarmId != 0) AlarmStore.cancelBackup(this, alarmId)
        // 从这一刻开始追赶：点「起床」只是停止响铃，不是结束。
        // 不打卡就一直把流程页拉回来，直到用户真的拍了照，或者主动认了「今天不算」。
        AlarmStore.scheduleChase(this, AlarmStore.nextChaseMinutes(this))
        AlarmStore.pushEvent(this, alarmId)
        val i = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            putExtra("alarmId", alarmId)
        }
        startActivity(i)
        finish()
    }

    private fun snooze() {
        // 按钮已经 disabled，这里再挡一次：某些 ROM 的辅助功能能触发已禁用的点击
        if (!AlarmStore.canSnooze(this)) {
            applySnoozeButton()
            return
        }
        AlarmStore.markSnoozeUsed(this)
        stopRinging()
        // 兜底闹钟的触发点是「原时间 + 3 分钟」，比 5 分钟的贪睡更早。
        // 不撤掉它，用户会在贪睡期间被提前叫醒，看起来像「贪睡没用」。
        if (alarmId != 0) AlarmStore.cancelBackup(this, alarmId)
        // 贪睡意味着「还要再响一次」，这期间不该再叠加追赶，否则两套提醒一起弹
        AlarmStore.cancelChase(this)
        AlarmStore.snooze(this, alarmId, snoozeMinutes)
        finish()
    }

    @Deprecated("响铃页不允许返回键直接关闭")
    override fun onBackPressed() {
        // 故意不关闭：必须选择起床或贪睡；播报模式下必须拍照打卡
    }

    // ================================================================ 强制播报
    /**
     * 第二次响铃（贪睡额度用完）：铃声换成当天新闻播报。
     *
     * 规则：播报开始后不能关、不能退、不能贪睡，只有拍了门外照片才结束。
     * 本页只负责「关铃声 + 起 TTS + 藏入口」；真正的解除在 Flutter 打卡成功后
     * 调 Bridge.stopRing() → [finishFromCheckin]，避免 Flutter 与原生各判一次。
     */
    private fun enterBroadcastMode() {
        broadcastMode = true
        broadcastActive = true
        // 只停声音，不撤全屏通知：撤了系统会把锁屏重新盖上来（见 onCreate 注释）
        stopAlarmSound()
        findViewById<View>(R.id.snoozeBtn).visibility = View.GONE
        findViewById<TextView>(R.id.labelText).text = "晨间播报"
        findViewById<TextView>(R.id.hintText).text = "播报进行中 · 拍一张门外照片才能结束今天的闹钟"
        val wake = findViewById<Button>(R.id.wakeBtn)
        wake.text = "我已出门 · 去拍门外照片"
        wake.setOnClickListener { openCheckin() }
        startBroadcast()
        // 系统级保活：每 20 秒把响铃页拽回前台，按 Home / 被弹窗盖住都拉得回来。
        // 标记落 prefs：进程被杀后保活链条也能续上（带日期，隔天自动失效）
        try {
            AlarmStore.prefs(this).edit()
                .putString("broadcast_active", "1")
                .putString("broadcast_day", SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date()))
                .putInt("last_ring_alarm", alarmId)
                .apply()
        } catch (e: Exception) {
            // 忽略
        }
        AlarmStore.scheduleBroadcastKeep(this)
    }

    private fun stopAlarmSound() {
        try {
            ringtone?.stop()
        } catch (e: Exception) {
            // 忽略
        }
        ringtone = null
        try {
            vibrator?.cancel()
        } catch (e: Exception) {
            // 忽略
        }
    }

    /**
     * 念当天新闻。文本由 Flutter 进流程时写进 prefs，锁屏冷启动时也能直接念，
     * 不用等 Flutter 引擎起来（那要好几秒，用户在这几秒里看到的是黑屏）。
     */
    private fun startBroadcast() {
        val raw = AlarmStore.newsSpeech(this)
        newsLines = raw.split("\n").map { it.trim() }.filter { it.isNotEmpty() }
        if (newsLines.isEmpty()) {
            newsLines = listOf(
                "早上好，该起床了。今天的新闻还没有准备好，先起身活动一下。",
                "拍一张门外的照片，今天的闹钟才会结束。"
            )
        }
        try {
            tts = TextToSpeech(this) { status ->
                if (status == TextToSpeech.SUCCESS) {
                    try {
                        tts?.language = Locale.SIMPLIFIED_CHINESE
                        tts?.setSpeechRate(0.95f)
                    } catch (e: Exception) {
                        // 引擎不支持调参数时按默认念
                    }
                    speakAll()
                }
            }
        } catch (e: Exception) {
            // 没有语音引擎也不影响打卡，页面上的文字仍可读
        }
    }

    /**
     * 播一遍就停。用户的原话：「新闻直接播就可以，不需要一直播」——
     * 反复循环念等于噪音；念完后页面还在，规则不变：拍一张门外照片才结束。
     * 想重听就锁屏再亮屏一次（保活链条会重新拉起页面续播）。
     */
    private fun speakAll() {
        val t = tts ?: return
        if (!broadcastMode || isFinishing) return
        newsLines.forEachIndexed { i, line ->
            try {
                t.speak(
                    line,
                    if (i == 0) TextToSpeech.QUEUE_FLUSH else TextToSpeech.QUEUE_ADD,
                    null,
                    "news-$i"
                )
            } catch (e: Exception) {
                // 单条失败不影响后续
            }
        }
        // 中文约每秒 4.5 字 + 3 秒间隔。到点只换提示语，不再重播。
        val est = (newsLines.sumOf { it.length } * 220L + 3_000L).coerceAtLeast(20_000L)
        handler.postDelayed({
            if (broadcastMode && !isFinishing) {
                findViewById<TextView>(R.id.hintText).text =
                    "播报结束 · 拍一张门外照片结束今天的闹钟"
            }
        }, est)
    }

    private fun openCheckin() {
        // 告诉 Flutter 直接从第 3 步（打卡）开始，不必重走唤醒 / 答题 / 播报
        AlarmStore.setFlowStartStep(this, 3)
        // 启动事件要写：Flutter 侧靠 consumeLaunchEvent 决定要不要拉起流程页。
        // 正常路径在「起床」按钮里写（goMorning），播报路径只有这里。
        AlarmStore.pushEvent(this, alarmId)
        // v1.13.3：点了「我已出门」就立刻停播报——用户的原话是
        // 「点醒了就不会再播报」。念完这轮新闻再停反而像失控。
        broadcastMode = false
        broadcastActive = false
        stopBroadcast()
        // 保活标记也要一并清：不清的话，下一次保活闹钟触发时
        // onBroadcastKeep 看到 stillOn=true，会把本页再拽到前台，
        // 盖住正要拍照的打卡页（真机实测踩过）。
        try {
            AlarmStore.prefs(this).edit().putString("broadcast_active", "0").apply()
        } catch (e: Exception) {
            // 忽略
        }
        try {
            findViewById<TextView>(R.id.hintText).text = "拍完门外照片，今天的闹钟就结束"
        } catch (e: Exception) {
            // 忽略
        }
        // 停掉抢焦点与保活：打卡页要能正常用
        handoff = true
        AlarmStore.cancelBroadcastKeep(this)
        val i = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            putExtra("alarmId", alarmId)
        }
        try {
            startActivity(i)
        } catch (e: Exception) {
            // 后台启动受限时用户仍可从通知点回来
        }
        // 故意不 finish：页面留着兜底，打卡成功时 Flutter 调 stopRing 统一关页
    }

    /** Flutter 打卡成功后调用：停播报、撤通知、关页 */
    fun finishFromCheckin() {
        broadcastMode = false
        stopBroadcast()
        // 只有「打卡完成」这条正路才清标记。系统杀 Activity 不能清——
        // 保活闹钟要把播报续上；标记自带日期，隔天自动失效。
        try {
            AlarmStore.prefs(this).edit().putString("broadcast_active", "0").apply()
        } catch (e: Exception) {
            // 忽略
        }
        try {
            AlarmStore.cancelRingNotification(this)
        } catch (e: Exception) {
            // 忽略
        }
        finish()
    }

    private fun stopBroadcast() {
        broadcastActive = false
        AlarmStore.cancelBroadcastKeep(this)
        handler.removeCallbacksAndMessages(null)
        try {
            tts?.stop()
            tts?.shutdown()
        } catch (e: Exception) {
            // 忽略
        }
        tts = null
    }

    override fun onDestroy() {
        isShowing = false
        if (instance === this) instance = null
        stopBroadcast()
        stopRinging()
        releaseWakeLock()
        super.onDestroy()
    }
}
