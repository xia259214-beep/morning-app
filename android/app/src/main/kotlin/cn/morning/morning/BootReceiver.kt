package cn.morning.morning

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * 开机 / 改时间 / 改时区 / 应用升级后重新注册全部闹钟。
 * Android 的闹钟在重启后会丢失，这一步是「重启可恢复」的关键。
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            Intent.ACTION_TIME_CHANGED,
            Intent.ACTION_TIMEZONE_CHANGED,
            "android.intent.action.QUICKBOOT_POWERON" -> {
                try {
                    AlarmStore.syncAll(context)
                } catch (e: Exception) {
                    // 忽略：下次启动 App 时会再次同步
                }
            }
        }
    }
}
