package cn.morning.morning

import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * 闹钟触发入口。
 *
 * 两条路按锁屏状态分流（这是在小米 HyperOS 3 / Android 16 上实测出来的唯一稳定组合）：
 *
 * - **锁屏 / 息屏**：只用全屏通知（FSI）。系统会把响铃页放到锁屏**之上**；
 *   若先自己 startActivity 造出一个实例，通知再来就只能复用那个实例，
 *   结果页面停留在锁屏之下——用户看到的是黑屏。
 * - **已解锁（正在用手机）**：直接 startActivity 立刻可见；此时 FSI 只会变成横幅，
 *   不会抢前台，正好当兜底。
 *
 * 通知始终先发：进程有可能在这一行之后被系统冻结，先把唯一可靠的那条路铺好。
 */
class AlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        // 追赶：用户点了「起床」但一直没打卡。这条路不响铃，只是把流程页拉回来。
        if (intent.getBooleanExtra("chase", false)) {
            onChase(context)
            return
        }

        val alarmId = intent.getIntExtra("alarmId", 0)
        val label = AlarmStore.labelOf(context, alarmId)
        val isBackup = intent.getBooleanExtra("backup", false)

        // 响铃页已经在最前面了，说明本次是重复触发（主链路或兜底撞在一起），
        // 不再打扰；同时把还挂着的兜底撤掉，避免它过几分钟再响一次。
        if (RingActivity.isShowing) {
            AlarmStore.cancelBackup(context, alarmId)
            return
        }

        // 主链路已经真的响了，兜底就没有存在意义。不撤掉的话，
        // 用户点「起床」3 分钟后会再被同一个闹钟叫一次（真机实测）。
        if (!isBackup) AlarmStore.cancelBackup(context, alarmId)

        // ① 全屏通知：锁屏 + 息屏下由系统负责点亮屏幕、并把页面压在锁屏之上
        AlarmStore.notifyRing(context, alarmId, label, fsi = true)

        // ② 直接起页：只在已解锁时用，避免抢在 FSI 之前建出实例
        if (!isLocked(context)) {
            val ring = Intent(context, RingActivity::class.java).apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_NO_USER_ACTION
                )
                putExtra("alarmId", alarmId)
                putExtra("label", label)
                putExtra("snoozeMinutes", AlarmStore.snoozeOf(context, alarmId))
            }
            try {
                context.startActivity(ring)
            } catch (e: Exception) {
                // 后台启动受限，交给上面的全屏通知
            }
        }

        if (alarmId > 0) AlarmStore.disableOnce(context, alarmId)
    }

    /**
     * 追赶一次。
     *
     * 三种情况要区分开：
     * - 响铃页正开着（用户还在锁屏上纠结）：不追，等他点「起床」时自己会重排；
     * - 今天额度用完了：不再弹，让他安静地把这一天记成未打卡；
     * - 其余：写事件 + 拉起 App，同时把下一轮排上。
     *
     * 事件走 prefs 而不是 Intent extra，理由见 [AlarmStore.pushChaseEvent]。
     */
    private fun onChase(context: Context) {
        if (RingActivity.isShowing) return

        val next = AlarmStore.nextChaseMinutes(context)
        if (next < 0) {
            AlarmStore.cancelChase(context)
            return
        }

        AlarmStore.pushChaseEvent(context)
        // 主路径：全屏通知。实测后台 startActivity 会被系统拦掉，
        // 屏幕上什么都不发生——这条 FSI 通路和真闹钟用的是同一条。
        AlarmStore.notifyChase(context, AlarmStore.chaseRound(context))
        // 直接振一下，绕开通知渠道：HyperOS 上无声通道的横幅在桌面不一定弹，
        // 但手机在桌上"嗡"一下是一定能被察觉的。
        vibrateChase(context)
        // 双保险：App 本身就在前台时这条立刻生效，比通知更快
        try {
            val i = Intent(context, MainActivity::class.java).apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                )
            }
            context.startActivity(i)
        } catch (e: Exception) {
            // 后台起页被拦（部分 ROM）：上面那条通知会兜住
        }

        AlarmStore.scheduleChase(context, next)
    }

    /**
     * 追赶时的振动。
     *
     * 不响铃：人已经醒了，再放一遍闹铃是折磨；但完全不提醒等于白追。
     * 两下短振，足够让手机在桌上或口袋里"叫"一次。
     */
    private fun vibrateChase(context: Context) {
        try {
            val v = context.getSystemService(Context.VIBRATOR_SERVICE) as? android.os.Vibrator
                ?: return
            val pattern = longArrayOf(0, 260, 180, 260)
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                v.vibrate(android.os.VibrationEffect.createWaveform(pattern, -1))
            } else {
                @Suppress("DEPRECATION")
                v.vibrate(pattern, -1)
            }
        } catch (e: Exception) {
            // 没有振动马达或被系统限制时忽略
        }
    }

    private fun isLocked(context: Context): Boolean {
        return try {
            val km = context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
            km.isKeyguardLocked
        } catch (e: Exception) {
            true
        }
    }
}
