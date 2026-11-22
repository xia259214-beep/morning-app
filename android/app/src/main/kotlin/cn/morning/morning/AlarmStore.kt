package cn.morning.morning

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/**
 * 闹钟调度中枢（原生层）。
 *
 * 设计要点（对应架构文档「闹钟可靠性原则」）：
 * 1. 只用 AlarmManager.setAlarmClock —— 系统把它当「闹钟类」任务，最不容易被省电策略延后；
 * 2. 每个闹钟固定 requestCode，避免多个闹钟互相覆盖；
 * 3. 所有时间计算都在本地完成，不依赖网络、后端或 AI；
 * 4. 开机 / 改时间 / 改时区 / 应用升级后由 BootReceiver 重新注册。
 */
object AlarmStore {

    const val PREFS = "flutter_prefs"
    const val KEY_ALARMS = "alarms"
    const val KEY_EVENT = "launch_event"
    private const val KEY_RING_NOTIF_ID = "ring_notif_id"
    private const val KEY_CHASE_NOTIF_ID = "chase_notif_id"
    private const val SNOOZE_OFFSET = 100000
    private const val BACKUP_OFFSET = 200000
    private const val TEST_ID = -99
    private const val BACKUP_DELAY_MS = 3 * 60_000L

    /** 追赶闹钟的 requestCode。负数避免和用户创建的闹钟（从 1 开始）撞号。 */
    private const val CHASE_ID = -77
    private const val KEY_SNOOZE_DAY = "snooze_day"
    private const val KEY_SNOOZE_COUNT = "snooze_count"

    /**
     * v1.13.5：一天只允许贪睡一次，第二次响铃不再给按钮，直接进强制播报。
     *
     * 流程（用户定的）：第一次响 →「贪睡 5 分钟」→ 第二次响就是晨间播报，
     * 播报不能关、不能退，只有拍了门外照片才停。
     * 一次是上限：再多就等于闹钟可以被无限推迟，所谓「必须打卡」不成立。
     */
    const val MAX_SNOOZE = 1
    private const val KEY_CHASE_DAY = "chase_day"
    private const val KEY_CHASE_COUNT = "chase_count"

    /**
     * 追赶节奏（分钟）。
     *
     * v1.5.0 的核心变化：闹钟不能靠「关掉」结束。以前点完「起床」进流程页，
     * 按 Home 键回桌面就再也没人管了——那个「起床」，实际只是「停止响铃」。
     * 现在点「起床」会排一串追赶，用户不打卡就一直被拉回来。
     *
     * 间隔逐渐拉长而不是固定高频：他要是在洗漱、在等地铁，每分钟弹一次是折磨；
     * 半小时后还在拖，就该紧一点。六轮约 71 分钟，足够一个正常的通勤。
     */
    private val CHASE_MINUTES = intArrayOf(3, 5, 8, 12, 18, 25)

    fun prefs(c: Context) = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun today(): String = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())

    // ---------------------------------------------------------------- 数据读写
    /**
     * 写入闹钟列表。返回 false 表示 JSON 不合法、拒绝覆盖。
     *
     * 为什么要在原生侧再洗一遍：这份 JSON 是整个闹钟功能的唯一真相，
     * 一旦写进无法解析的内容，[alarms] 会返回空表，[syncAll] 随即取消所有
     * AlarmManager 里的闹钟——用户第二天不会被叫醒，而且界面上看不出任何异常。
     * 与其相信上游永远传对，不如在落盘前做一次结构化校验。
     */
    fun saveRaw(c: Context, json: String): Boolean {
        val clean = try {
            sanitize(json)
        } catch (e: Exception) {
            return false
        }
        prefs(c).edit().putString(KEY_ALARMS, clean).apply()
        syncAll(c)
        return true
    }

    /** 只保留已知字段，数值全部夹到合法区间；days 过滤到 1..7 */
    private fun sanitize(raw: String): String {
        val arr = JSONArray(raw) // 非法 JSON 直接抛出，由调用方拒绝写入
        val out = JSONArray()
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val id = o.optInt("id", 0)
            if (id == 0) continue // id 0 与「无闹钟」同义，留着会污染事件判断
            val n = JSONObject()
            n.put("id", id)
            n.put("hour", o.optInt("hour", 6).coerceIn(0, 23))
            n.put("minute", o.optInt("minute", 30).coerceIn(0, 59))
            n.put("label", o.optString("label", "晨间唤醒").take(60))
            n.put("snooze", o.optInt("snooze", 5).coerceIn(1, 60))
            n.put("quizCount", o.optInt("quizCount", 10).coerceIn(1, 50))
            n.put("enabled", o.optBoolean("enabled", true))
            val days = JSONArray()
            o.optJSONArray("days")?.let { d ->
                for (k in 0 until d.length()) {
                    val v = d.optInt(k, -1)
                    if (v in 1..7) days.put(v)
                }
            }
            n.put("days", days)
            out.put(n)
        }
        return out.toString()
    }

    fun alarms(c: Context): List<JSONObject> {
        val raw = prefs(c).getString(KEY_ALARMS, null) ?: return emptyList()
        return try {
            val arr = JSONArray(raw)
            (0 until arr.length()).map { arr.getJSONObject(it) }
        } catch (e: Exception) {
            emptyList()
        }
    }

    fun labelOf(c: Context, id: Int): String {
        if (id == TEST_ID) return "测试闹钟"
        return alarms(c).firstOrNull { it.optInt("id") == id }?.optString("label", "晨间唤醒")
            ?: "晨间唤醒"
    }

    fun snoozeOf(c: Context, id: Int): Int =
        alarms(c).firstOrNull { it.optInt("id") == id }?.optInt("snooze", 5) ?: 5

    /** 「仅一次」的闹钟响过之后置为关闭，避免次日同一时间重复响 */
    fun disableOnce(c: Context, id: Int) {
        val list = alarms(c).toMutableList()
        var changed = false
        for (o in list) {
            if (o.optInt("id") == id && (o.optJSONArray("days")?.length() ?: 0) == 0) {
                o.put("enabled", false)
                changed = true
            }
        }
        if (changed) {
            prefs(c).edit().putString(KEY_ALARMS, JSONArray(list).toString()).apply()
        }
    }

    // ---------------------------------------------------------------- 时间计算
    /** 计算下一次触发时间（毫秒），与 Flutter 侧算法保持一致 */
    fun nextTrigger(o: JSONObject): Long? {
        // 夹紧范围：历史数据里可能存过 25 点或负数，Calendar 不会报错，
        // 但会算出一个莫名其妙的时间，闹钟就静默错点了。
        val hour = o.optInt("hour", 6).coerceIn(0, 23)
        val minute = o.optInt("minute", 30).coerceIn(0, 59)
        val days = mutableListOf<Int>()
        o.optJSONArray("days")?.let { arr ->
            for (i in 0 until arr.length()) {
                val v = arr.optInt(i, -1)
                if (v in 1..7) days.add(v)
            }
        }
        val now = Calendar.getInstance()

        fun base(offset: Int): Calendar = Calendar.getInstance().apply {
            add(Calendar.DAY_OF_YEAR, offset)
            set(Calendar.HOUR_OF_DAY, hour)
            set(Calendar.MINUTE, minute)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }

        if (days.isEmpty()) {
            val t = base(0)
            if (!t.after(now)) return base(1).timeInMillis
            return t.timeInMillis
        }
        for (i in 0..7) {
            val t = base(i)
            val dow = t.get(Calendar.DAY_OF_WEEK) // 1=周日 ... 7=周六
            val iso = if (dow == Calendar.SUNDAY) 7 else dow - 1
            if (!days.contains(iso)) continue
            if (t.after(now)) return t.timeInMillis
        }
        return null
    }

    // ---------------------------------------------------------------- 注册与取消
    fun syncAll(c: Context) {
        val am = c.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val list = alarms(c)
        for (o in list) {
            val id = o.optInt("id")
            am.cancel(broadcast(c, id, snooze = false, backup = false))
            am.cancel(broadcast(c, id, snooze = false, backup = true))
            am.cancel(broadcast(c, id, snooze = true, backup = false))
        }
        for (o in list) {
            if (!o.optBoolean("enabled", true)) continue
            val at = nextTrigger(o) ?: continue
            scheduleAt(c, o.optInt("id"), at, o.optString("label", "晨间唤醒"), o.optInt("snooze", 5))
        }
    }

    fun scheduleAt(c: Context, id: Int, at: Long, label: String, snooze: Int) {
        val am = c.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        // 主路径：广播触发 -> AlarmReceiver 内同时尝试「直接起页」与「全屏通知」。
        // 实测（小米 HyperOS 3 / Android 16）：第三方 App 的 startActivity 会被 BAL 拦死，
        // 而带 fullScreenIntent 的通知能被系统放行，因此全屏通知才是真机上唯一可靠的那条。
        val op = broadcast(c, id, snooze = false, backup = false)
        val showIntent = PendingIntent.getActivity(
            c, id,
            Intent(c, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            flags()
        )
        try {
            am.setAlarmClock(AlarmManager.AlarmClockInfo(at, showIntent), op)
        } catch (e: SecurityException) {
            // 没有精准闹钟权限时的降级：仍然尽量准点
            try {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, op)
            } catch (e2: SecurityException) {
                am.set(AlarmManager.RTC_WAKEUP, at, op)
            }
        }
        // 冗余兜底：若主链路被厂商策略吞掉（进程被杀、通知被限），再补响一次
        scheduleBackup(c, id, at + BACKUP_DELAY_MS, label, snooze)
    }

    /** 兜底闹钟：同样走广播，AlarmReceiver 会判断响铃页是否已在前台，避免重复弹 */
    private fun scheduleBackup(c: Context, id: Int, at: Long, label: String, snooze: Int) {
        val am = c.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val op = broadcast(c, id, snooze = false, backup = true)
        try {
            am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, op)
        } catch (e: Exception) {
            am.set(AlarmManager.RTC_WAKEUP, at, op)
        }
    }

    fun snooze(c: Context, id: Int, minutes: Int) {
        val am = c.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val at = System.currentTimeMillis() + minutes * 60_000L
        val op = broadcast(c, id, snooze = true, backup = false)
        try {
            am.setAlarmClock(AlarmManager.AlarmClockInfo(at, null), op)
        } catch (e: Exception) {
            am.set(AlarmManager.RTC_WAKEUP, at, op)
        }
    }

    /** 测试：10 秒后走完整响铃链路 */
    fun scheduleTest(c: Context) {
        scheduleAt(c, TEST_ID, System.currentTimeMillis() + 10_000L, "测试闹钟", 5)
    }

    fun cancelTest(c: Context) {
        val am = c.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.cancel(broadcast(c, TEST_ID, snooze = false, backup = false))
        am.cancel(broadcast(c, TEST_ID, snooze = false, backup = true))
    }

    /**
     * 撤掉兜底闹钟。
     *
     * 真机上暴露的问题：主链路正常响过、用户也点了「起床」，3 分钟后兜底闹钟
     * 照样触发，把已经出门的人再叫一次。兜底的意义是「主链路没响时补一次」，
     * 主链路既然抵达，它就必须消失。
     */
    fun cancelBackup(c: Context, id: Int) {
        try {
            val am = c.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            am.cancel(broadcast(c, id, snooze = false, backup = true))
        } catch (e: Exception) {
            // 取消失败也只是多响一次，不影响主流程
        }
    }

    // ---------------------------------------------------------------- 贪睡配额
    /**
     * 今天还能不能贪睡。
     *
     * v1.13.0：额度从「一天一次」改为「一天两次，跨所有闹钟算」。
     * 用完之后第二次响铃直接进强制播报（[isForcedBroadcast]），不再给贪睡按钮。
     * 按单个闹钟算的话，想赖床的人多设几个闹钟就把限制绕过去了。
     */
    fun canSnooze(c: Context): Boolean = snoozeCount(c) < MAX_SNOOZE

    /** 今天已经贪睡过几次 */
    fun snoozeCount(c: Context): Int {
        val p = prefs(c)
        return if (p.getString(KEY_SNOOZE_DAY, "") == today()) p.getInt(KEY_SNOOZE_COUNT, 0) else 0
    }

    fun markSnoozeUsed(c: Context) {
        val n = snoozeCount(c) + 1
        prefs(c).edit().putString(KEY_SNOOZE_DAY, today()).putInt(KEY_SNOOZE_COUNT, n).apply()
    }

    /** 一次贪睡用完了：下一次响铃就是强制播报，不给任何关闭入口 */
    fun isForcedBroadcast(c: Context): Boolean = snoozeCount(c) >= MAX_SNOOZE

    /** 打卡完成 / 主动放弃 / 换新的一天：清空贪睡额度 */
    fun resetSnooze(c: Context) {
        prefs(c).edit().remove(KEY_SNOOZE_DAY).remove(KEY_SNOOZE_COUNT).apply()
    }

    /**
     * 当天要播的新闻正文（Flutter 进流程时写好）。
     * 强制播报在响铃页里念，不等 Flutter 引擎起来——锁屏冷启动时引擎要好几秒。
     */
    fun newsSpeech(c: Context): String = prefs(c).getString("newsSpeech", "") ?: ""

    /** 拉起 App 时告诉 Flutter 从哪一步开始（3 = 直接到打卡） */
    fun setFlowStartStep(c: Context, step: Int) {
        prefs(c).edit().putString("flowStartStep", step.toString()).apply()
    }

    // ------------------------------------------------------------ 强制播报保活
    /**
     * 强制播报的「拉回前台」闹钟，每 20 秒一发。
     *
     * 为什么不用 App 内部的 Handler 循环：真机实测（MIUI / HyperOS），按 Home 键后
     * 系统会把整个进程冻结，Handler、TTS 全部停摆——App 内部的循环斗不过系统冻结。
     * 而精确闹钟（setExactAndAllowWhileIdle）由系统代发，触发时强制解冻进程，
     * 接收器里再把响铃页拽回前台。这才是「播报不能被打断、关掉也不可以」的系统级实现。
     */
    private const val BROADCAST_KEEP_ID = -88
    private const val BROADCAST_KEEP_MS = 20_000L

    fun scheduleBroadcastKeep(c: Context) {
        val am = c.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val op = PendingIntent.getBroadcast(
            c, BROADCAST_KEEP_ID,
            Intent(c, AlarmReceiver::class.java).apply {
                action = "cn.morning.morning.BROADCAST_KEEP"
                putExtra("type", "broadcast_keep")
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        try {
            am.setExactAndAllowWhileIdle(
                AlarmManager.RTC_WAKEUP,
                System.currentTimeMillis() + BROADCAST_KEEP_MS,
                op
            )
        } catch (e: Exception) {
            try {
                am.set(AlarmManager.RTC_WAKEUP, System.currentTimeMillis() + BROADCAST_KEEP_MS, op)
            } catch (e2: Exception) {
                // 排不上就只能靠 App 内部循环
            }
        }
    }

    fun cancelBroadcastKeep(c: Context) {
        try {
            val am = c.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            am.cancel(
                PendingIntent.getBroadcast(
                    c, BROADCAST_KEEP_ID,
                    Intent(c, AlarmReceiver::class.java).apply {
                        action = "cn.morning.morning.BROADCAST_KEEP"
                    },
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
            )
        } catch (e: Exception) {
            // 忽略
        }
    }

    // ---------------------------------------------------------------- 追赶
    /**
     * 取下一轮追赶的延迟分钟数，并把计数推进一格。
     * 返回 -1 表示今天的额度用完了——这一轮放弃催他，但不能让他以为「闹钟就没了」，
     * 界面上当天会被记成未打卡。
     */
    fun nextChaseMinutes(c: Context): Int {
        val p = prefs(c)
        val n = if (p.getString(KEY_CHASE_DAY, "") == today()) p.getInt(KEY_CHASE_COUNT, 0) else 0
        if (n >= CHASE_MINUTES.size) return -1
        p.edit().putString(KEY_CHASE_DAY, today()).putInt(KEY_CHASE_COUNT, n + 1).apply()
        return CHASE_MINUTES[n]
    }

    /** 当前已经追了几轮，供界面显示「第 n 次提醒」 */
    fun chaseRound(c: Context): Int =
        if (prefs(c).getString(KEY_CHASE_DAY, "") == today()) prefs(c).getInt(KEY_CHASE_COUNT, 0) else 0

    fun scheduleChase(c: Context, minutes: Int) {
        if (minutes <= 0) return
        val am = c.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val at = System.currentTimeMillis() + minutes * 60_000L
        val op = chaseIntent(c)
        // 不用 setAlarmClock：追赶不该在锁屏上顶掉用户真正设的闹钟时间。
        // setExactAndAllowWhileIdle 在 Doze 下也能准时，分钟级的精度完全够。
        try {
            am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, op)
        } catch (e: Exception) {
            try {
                am.set(AlarmManager.RTC_WAKEUP, at, op)
            } catch (e2: Exception) {
                // 排不上就只能等下次进 App 时补
            }
        }
    }

    /** 撤掉追赶并清零计数。打卡完成、主动放弃、重置流程时都要调。 */
    fun cancelChase(c: Context) {
        try {
            val am = c.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            am.cancel(chaseIntent(c))
        } catch (e: Exception) {
            // 撤不掉最多多弹一次，Flutter 侧会用自己的完成状态挡住
        }
        // 已经弹出来的那条通知也要撤：不然打卡完了它还挂在通知栏上催
        cancelChaseNotification(c)
        prefs(c).edit().remove(KEY_CHASE_COUNT).remove(KEY_CHASE_DAY).apply()
    }

    private fun chaseIntent(c: Context): PendingIntent {
        val i = Intent(c, AlarmReceiver::class.java).apply {
            action = "cn.morning.morning.CHASE"
            putExtra("chase", true)
        }
        return PendingIntent.getBroadcast(c, CHASE_ID, i, flags())
    }

    /**
     * 追赶事件同样只写 prefs、不信任 Intent。
     *
     * MainActivity 是 exported=true 的（桌面图标要能起来），如果靠 extra 传
     * 「你现在该打卡了」，任何应用都能伪造一次把用户拖进流程页。
     * 和 v1.4.1 修掉的 ring 事件漏洞是同一个道理。
     */
    fun pushChaseEvent(c: Context) {
        val o = JSONObject()
        o.put("type", "chase")
        o.put("alarmId", 0)
        prefs(c).edit().putString(KEY_EVENT, o.toString()).apply()
    }

    fun canExact(c: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val am = c.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        return am.canScheduleExactAlarms()
    }

    /**
     * 是否拥有「全屏通知」权限（Android 14 起是独立开关）。
     * 没有它时，系统会把带 fullScreenIntent 的通知降级成普通横幅，锁屏不会弹页。
     */
    fun canUseFsi(c: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return true
        val nm = c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        return nm.canUseFullScreenIntent()
    }

    private fun flags(): Int {
        var f = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) f = f or PendingIntent.FLAG_IMMUTABLE
        return f
    }

    private fun broadcast(c: Context, id: Int, snooze: Boolean, backup: Boolean): PendingIntent {
        val i = Intent(c, AlarmReceiver::class.java).apply {
            action = "cn.morning.morning.RING"
            putExtra("alarmId", id)
            putExtra("backup", backup)
            if (snooze) putExtra("snoozeFlag", true)
        }
        val req = when {
            snooze -> id + SNOOZE_OFFSET
            backup -> id + BACKUP_OFFSET
            else -> id
        }
        return PendingIntent.getBroadcast(c, req, i, flags())
    }

    // ---------------------------------------------------------------- 兜底通知
    const val CHANNEL_ID = "morning_alarm"

    /** 静默的常驻通知通道：铃声已由响铃页循环播放，这里不能再出声，否则两条铃声打架 */
    const val CHANNEL_SILENT = "morning_alarm_ongoing"

    /** 追赶通道：只在「点了起床但一直没打卡」时用，不出声，避免真闹钟响两遍 */
    const val CHANNEL_CHASE = "morning_chase"

    fun ensureChannel(c: Context) {
        val nm = c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            val channel = NotificationChannel(CHANNEL_ID, "晨间闹钟", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "闹钟响铃提醒"
                setSound(
                    RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM),
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                enableVibration(true)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                setBypassDnd(true)
            }
            nm.createNotificationChannel(channel)
        }
        if (nm.getNotificationChannel(CHANNEL_SILENT) == null) {
            val quiet = NotificationChannel(
                CHANNEL_SILENT, "晨间闹钟（常驻提示）", NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "响铃页打开后的常驻入口，不出声"
                setSound(null, null)
                enableVibration(false)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            nm.createNotificationChannel(quiet)
        }
        if (nm.getNotificationChannel(CHANNEL_CHASE) == null) {
            val chase = NotificationChannel(
                CHANNEL_CHASE, "晨间追赶提醒", NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "点了起床但还没打卡时的提醒，不响铃，只振一下"
                setSound(null, null)
                enableVibration(true)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            nm.createNotificationChannel(chase)
        }
    }

    /**
     * 响铃通知（唯一可靠能穿透锁屏的那条路）。
     *
     * 两个实机上踩出来的细节，改不得：
     * 1. 每次响铃必须用**全新的通知 id**。系统只在「新发布的通知」时才评估全屏意图，
     *    复用旧 id 会被当成「更新一条已有通知」，页面不会弹；
     * 2. 发布前先撤掉上一条，避免同时挂两条闹钟通知。
     *
     * @param fsi true 时带全屏意图（锁屏弹页）；false 时只做常驻提示，防止响铃页自己
     *            再发一条全屏通知造成递归弹页。
     * @param silent true 时走静默通道：声音交给响铃页的循环铃声，通知不再出声。
     */
    fun notifyRing(c: Context, id: Int, label: String, fsi: Boolean, silent: Boolean = false) {
        ensureChannel(c)
        val nm = c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        val notifId = 910000 + (System.currentTimeMillis() % 89000).toInt()
        val prev = prefs(c).getInt(KEY_RING_NOTIF_ID, 0)
        if (prev != 0 && prev != notifId) {
            try {
                nm.cancel(prev)
            } catch (e: Exception) {
                // 忽略
            }
        }
        prefs(c).edit().putInt(KEY_RING_NOTIF_ID, notifId).apply()

        // 全屏意图里必须把参数带上，否则响铃页取不到闹钟 id，会显示「闹钟编号 0」
        val ring = Intent(c, RingActivity::class.java).apply {
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_NO_USER_ACTION
            )
            putExtra("alarmId", id)
            putExtra("label", label)
            putExtra("snoozeMinutes", snoozeOf(c, id))
            putExtra("fromNotification", true)
        }
        val full = PendingIntent.getActivity(c, notifId, ring, flags())

        val builder = Notification.Builder(c, if (silent) CHANNEL_SILENT else CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(label)
            .setContentText("该起床了，点开完成今天的晨间流程")
            .setCategory(Notification.CATEGORY_ALARM)
            .setAutoCancel(true)
            .setOngoing(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setContentIntent(full)
            .setOnlyAlertOnce(false)
        if (fsi) builder.setFullScreenIntent(full, true)

        try {
            nm.notify(notifId, builder.build())
        } catch (e: Exception) {
            // 通知权限被拒时静默失败，页面这条路由接收器另行尝试
        }
    }

    /**
     * 追赶通知。
     *
     * 为什么必须带全屏意图：实测（小米 HyperOS 3 / Android 16）从广播里直接
     * startActivity 会被后台启动限制拦掉——闹钟触发了、计数也推进了，用户屏幕上
     * 却什么都没发生，App 还停在桌面。响铃页能弹出来靠的正是这条 FSI 通路，
     * 追赶只能走同一条。
     *
     * 目标故意是 MainActivity 而不是 RingActivity：追赶不该再响一次铃，
     * 只是把人带回流程页；Flutter 侧会读到 chase 事件并推流程。
     */
    fun notifyChase(c: Context, round: Int) {
        ensureChannel(c)
        val nm = c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        // 和响铃一样，每次都用新 id：复用 id 会被当成「更新一条已有通知」，
        // 系统不会重新评估全屏意图，页面就不弹了。
        val notifId = 920000 + (System.currentTimeMillis() % 79000).toInt()
        val prev = prefs(c).getInt(KEY_CHASE_NOTIF_ID, 0)
        if (prev != 0 && prev != notifId) {
            try {
                nm.cancel(prev)
            } catch (e: Exception) {
                // 忽略
            }
        }
        prefs(c).edit().putInt(KEY_CHASE_NOTIF_ID, notifId).apply()

        val open = Intent(c, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val pi = PendingIntent.getActivity(c, notifId, open, flags())

        val text = when (round) {
            1 -> "还差打卡这一步，拍一张照片就结束了"
            2 -> "第二次提醒：闹钟还没结束"
            3 -> "第三次提醒：今天还没打卡"
            else -> "第 $round 次提醒，今天的连续快断了"
        }

        val builder = Notification.Builder(c, CHANNEL_CHASE)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("晨间还没结束")
            .setContentText(text)
            .setCategory(Notification.CATEGORY_REMINDER)
            // 常驻而不是 autoCancel：这条通知的目的就是「赖着不走」。
            // 实测 HyperOS 上无声通道的横幅在桌面上不一定弹出来，那么至少要让
            // 它一直挂在通知栏和锁屏上，用户下拉就能看到、点进去就是流程页。
            .setOngoing(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setContentIntent(pi)
            .setFullScreenIntent(pi, true)

        try {
            nm.notify(notifId, builder.build())
        } catch (e: Exception) {
            // 通知权限被拒时静默失败，下一轮再试
        }
    }

    fun cancelChaseNotification(c: Context) {
        try {
            val nm = c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val id = prefs(c).getInt(KEY_CHASE_NOTIF_ID, 0)
            if (id != 0) nm.cancel(id)
        } catch (e: Exception) {
            // 忽略
        }
        prefs(c).edit().remove(KEY_CHASE_NOTIF_ID).apply()
    }

    fun cancelRingNotification(c: Context) {
        val nm = c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val id = prefs(c).getInt(KEY_RING_NOTIF_ID, 0)
        if (id == 0) return
        try {
            nm.cancel(id)
        } catch (e: Exception) {
            // 忽略
        }
        prefs(c).edit().remove(KEY_RING_NOTIF_ID).apply()
    }

    // ---------------------------------------------------------------- 启动事件
    fun pushEvent(c: Context, alarmId: Int) {
        val o = JSONObject()
        o.put("type", "ring")
        o.put("alarmId", alarmId)
        prefs(c).edit().putString(KEY_EVENT, o.toString()).apply()
    }

    fun consumeEvent(c: Context): Map<String, Any>? {
        val raw = prefs(c).getString(KEY_EVENT, null) ?: return null
        prefs(c).edit().remove(KEY_EVENT).apply()
        return try {
            val o = JSONObject(raw)
            mapOf("type" to o.optString("type", ""), "alarmId" to o.optInt("alarmId", 0))
        } catch (e: Exception) {
            null
        }
    }
}
