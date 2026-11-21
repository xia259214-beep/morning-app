/// 新闻的时间表。
///
/// 用户要的节奏很具体：早上 5:00 到 8:30 放「为他定制」的新闻——刚起床那段
/// 时间该看到跟自己相关的事；8:30 之后换成「外面正在发生什么」；19:00 之后
/// 不再刷新；第二天 5:00 重新开始。刷新本身不用频繁，隔 5 小时一次就够。
///
/// 这个文件只管「什么时候刷、现在该用哪种排序」，不碰网络也不碰界面，
/// 这样可以拿假时间跑单测——时间边界是最容易写错、又最不容易被手测发现的地方。
library;

import 'dart:math' as math;

/// 当前处于哪个时段
enum NewsSlot {
  /// 19:00 - 05:00：不刷新，只看已经拿到的
  silent,

  /// 05:00 - 08:30：按个人画像排，刚起床看跟自己有关的事
  custom,

  /// 08:30 - 19:00：按新闻价值排，外面正在发生什么
  general,
}

class NewsSchedule {
  /// 定制时段起点 05:00（分钟）
  static const int customStartMin = 5 * 60;

  /// 定制时段终点 08:30，同时也是「换台」的时刻
  static const int customEndMin = 8 * 60 + 30;

  /// 停止刷新的时刻 19:00
  static const int stopMin = 19 * 60;

  /// 两次联网之间至少隔这么久
  static const Duration gap = Duration(hours: 5);

  static int minuteOf(DateTime t) => t.hour * 60 + t.minute;

  static NewsSlot slotOf(DateTime t) {
    final m = minuteOf(t);
    if (m >= customStartMin && m < customEndMin) return NewsSlot.custom;
    if (m >= customEndMin && m < stopMin) return NewsSlot.general;
    return NewsSlot.silent;
  }

  /// 这个点允不允许联网
  static bool inWindow(DateTime t) => slotOf(t) != NewsSlot.silent;

  /// 当天 08:30 这一刻。用来判断「今天换过台了没有」。
  static DateTime noonSwitch(DateTime t) => DateTime(t.year, t.month, t.day, 8, 30);

  /// 该不该现在去联网。
  ///
  /// [lastTry] 是上一次**尝试**的时间（失败也记），[lastOk] 是上一次**成功**的时间。
  /// 两个分开记是有原因的：只记成功的话，没网的时候每次打开都会重试一遍，
  /// 手机在地铁里就一直空转超时；只记尝试的话，失败之后五小时内都不再试，
  /// 万一只是那一秒断网，用户就白等五小时。用尝试时间控频、成功时间控「换台」。
  static bool shouldFetch({
    required DateTime now,
    DateTime? lastTry,
    DateTime? lastOk,
  }) {
    if (!inWindow(now)) return false;
    if (lastTry == null) return true;

    // 8:30 之后、且今天还没在 8:30 之后刷过：强制刷一次。
    // 这一条是为了兑现「8:30 之后放的是外面正在发生的事」——
    // 5:00 那批到了 8:30 已经旧了三个半小时，直接沿用会让用户觉得「没更新」。
    if (minuteOf(now) >= customEndMin) {
      final sw = noonSwitch(now);
      final done = lastOk != null && lastOk.isAfter(sw);
      if (!done && now.isAfter(sw)) return true;
    }

    return now.difference(lastTry) >= gap;
  }

  /// 下一次大概什么时候会去拿新的。给人看的一句话。
  static String statusText(DateTime now, {DateTime? lastOk}) {
    final slot = slotOf(now);
    final ago = lastOk == null ? '' : _ago(now.difference(lastOk));

    if (slot == NewsSlot.silent) {
      return '今晚 19:00 之后不再刷新，明早 5:00 恢复${ago.isEmpty ? '' : ' · 上次 $ago'}';
    }
    final next = nextFetchAt(now, lastTry: lastOk);
    final tail = next == null ? '' : ' · 下次 ${_hm(next)}';
    return '${_slotName(slot)}${ago.isEmpty ? '' : ' · 上次 $ago'}$tail';
  }

  /// 下一次允许刷新的时刻。null 表示「现在就可以刷」。
  static DateTime? nextFetchAt(DateTime now, {DateTime? lastTry}) {
    if (!inWindow(now)) {
      final tomorrow = DateTime(now.year, now.month, now.day).add(const Duration(days: 1));
      return DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 5, 0);
    }
    if (lastTry == null) return null;

    final base = lastTry.add(gap);
    if (!base.isAfter(now)) return null;

    // 落在关窗之后的，顺延到明早 5 点
    final sameDay = DateTime(base.year, base.month, base.day, base.hour, base.minute);
    if (minuteOf(sameDay) >= stopMin) {
      final tomorrow = DateTime(base.year, base.month, base.day).add(const Duration(days: 1));
      return DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 5, 0);
    }
    return sameDay;
  }

  static String _slotName(NewsSlot s) => switch (s) {
        NewsSlot.custom => '早间 · 按你的关注排',
        NewsSlot.general => '日间 · 正在发生',
        NewsSlot.silent => '已停止刷新',
      };

  static String _hm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  static String _ago(Duration d) {
    if (d.inMinutes < 1) return '刚刚';
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
    if (d.inHours < 24) return '${d.inHours} 小时前';
    return '${d.inDays} 天前';
  }

  /// 定制时段给个性化高权重，日间时段压得很低——日间要的是「外面发生了什么」，
  /// 不是「你想看什么」。两者混在一起，日间的新闻就会变成回音壁。
  static double personaFactor(NewsSlot s) => switch (s) {
        NewsSlot.custom => 2.2,
        NewsSlot.general => 0.5,
        NewsSlot.silent => 0.5,
      };

  /// 时间衰减：5 小时左右衰减到 1/e。夜里不刷新时，早上 5 点看到的
  /// 仍然是最新那批，不会因为「过了 8 小时」就全部沉底。
  static double freshness(int ageMinutes) =>
      8.0 * math.exp(-ageMinutes.clamp(0, 100000) / 300.0);
}
