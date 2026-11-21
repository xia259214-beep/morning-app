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

    /** 把本页重新顶到锁屏之上；拿到焦点即止，最多重试 6 次 */
    private fun reassertOverKeyguard() {
        if (stopped || isFinishing || reassertCount >= 6) return
        if (hasWindowFocus()) {
            android.util.Log.d("MorningRing", "reassert: 已获得焦点，停止重试 (count=$reassertCount)")
            return
        }
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
        handler.postDelayed({ reassertOverKeyguard() }, 900)
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
     * 贪睡按钮：一天只有一次机会。
     *
     * v1.5.0 之前这里是无限制的，按几下都能再睡 5 分钟——那等于闹钟可以被无限推迟，
     * 所谓「必须打卡才能结束」根本不成立。现在用掉额度后按钮变灰、文案说清楚原因，
     * 不给一个点了没反应的死按钮（用户会以为坏了，然后去翻设置）。
     */
    private fun applySnoozeButton() {
        val b = findViewById<Button>(R.id.snoozeBtn)
        if (AlarmStore.canSnooze(this)) {
            b.isEnabled = true
            b.alpha = 1f
            b.text = "贪睡 $snoozeMinutes 分钟（今天仅此一次）"
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
                if (stopped) return
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
        // 故意不关闭：必须选择起床或贪睡
    }

    override fun onDestroy() {
        isShowing = false
        stopRinging()
        releaseWakeLock()
        super.onDestroy()
    }
}
