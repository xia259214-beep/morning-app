import 'dart:convert';

import 'core.dart';

// ============================================================================
// 晨间日志
//
// v1.3.0 之前，「记录」页只有每天一条汇总：答题 3/10、播报已完成、打卡已拍。
// 汇总能回答「今天做了没有」，回答不了「今天我到底听了什么、答了什么」。
// 这个文件补的是流水账：每发生一件事就追加一条，带时间戳。
//
// 设计上的三条约束：
//   1. 只追加，不改写。日志的可信度来自「当时写下的就是当时的」，事后编辑会让它
//      变成回忆录。
//   2. 落盘失败不影响主流程。答完题的下一秒不该被存储卡住。
//   3. 有上限。日志是给人看的，不是归档系统；120 天足够回看，再多就是垃圾。
// ============================================================================

/// 事件类型。数字是给落盘用的稳定编码，别依赖 enum 顺序。
enum JKind {
  wake, // 醒来（点了「我已醒来」）
  quiz, // 答了一题
  news, // 看到 / 听到一条新闻
  checkin, // 出门打卡
}

const Map<JKind, String> kJKindLabel = {
  JKind.wake: '醒来',
  JKind.quiz: '答题',
  JKind.news: '新闻',
  JKind.checkin: '打卡',
};

const Map<JKind, String> kJKindCode = {
  JKind.wake: 'w',
  JKind.quiz: 'q',
  JKind.news: 'n',
  JKind.checkin: 'c',
};

JKind jKindOf(String code) {
  for (final e in kJKindCode.entries) {
    if (e.value == code) return e.key;
  }
  return JKind.wake;
}

/// 一件事。
class JEvent {
  final int ts; // 毫秒时间戳
  final JKind kind;
  final String title; // 一行就能读懂的主文案
  final String detail; // 展开后的详情：解释、摘要、你的选择
  final String tag; // 维度 / 来源，用于右侧小标签
  final String verdict; // right / wrong / neutral（只有知识题会判对错）

  /// 新闻是否朗读过。这是唯一一个允许事后变的字段——
  /// 「看到」在进入那一刻就定了，「听到」发生在之后的任意一秒。
  bool spoken;

  JEvent({
    required this.ts,
    required this.kind,
    required this.title,
    this.detail = '',
    this.tag = '',
    this.verdict = 'neutral',
    this.spoken = false,
  });

  DateTime get time => DateTime.fromMillisecondsSinceEpoch(ts);

  String get dateKey {
    final t = time;
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }

  String get hhmm =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

  bool get isRight => verdict == 'right';
  bool get isWrong => verdict == 'wrong';

  /// 紧凑键名：一条日志平均 180 字节，12 个字段写全了会翻倍。
  Map<String, dynamic> toJson() => {
        't': ts,
        'k': kJKindCode[kind],
        'i': title,
        'd': detail,
        'g': tag,
        'v': verdict == 'neutral' ? '' : verdict,
        's': spoken ? 1 : 0,
      };

  static JEvent fromJson(Map<String, dynamic> m) => JEvent(
        ts: _asInt(m['t']),
        kind: jKindOf(_asText(m['k'], 'w')),
        title: _asText(m['i'], ''),
        detail: _asText(m['d'], ''),
        tag: _asText(m['g'], ''),
        verdict: _asText(m['v'], '') == '' ? 'neutral' : _asText(m['v'], 'neutral'),
        spoken: _asInt(m['s']) == 1,
      );

  // 逐字段容错：prefs 被写坏时（断电、磁盘满、手动改文件），一个类型不对的字段
  // 不该让整条记录连同全部历史一起消失。
  static int _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  static String _asText(Object? v, String fallback) {
    if (v is String) return v;
    if (v == null) return fallback;
    return v.toString();
  }
}

/// 一天的统计。全部由事件派生，不另存一份计数器——
/// 两份数据迟早会打架，而日志是唯一可信的那份。
class DayStat {
  int quizTotal = 0;
  int quizCorrect = 0;
  int news = 0;
  int newsSpoken = 0;
  bool woke = false;
  bool checkedIn = false;
  int wakeAt = 0;
  int checkinAt = 0;

  bool get hasAny => quizTotal > 0 || news > 0 || woke || checkedIn;

  /// 「几杠几」里的分子分母：晨间流程要求的三个动作。
  int get doneCount =>
      (woke ? 1 : 0) + (quizTotal > 0 ? 1 : 0) + (checkedIn ? 1 : 0);
}

class Journal {
  /// 新事件在前。列表顺序即展示顺序，省一次排序。
  static List<JEvent> events = [];

  static const int maxAgeDays = 120;
  static const int maxEvents = 3000;

  static Future<void> load() async {
    final raw = await Bridge.getPref('journal');
    if (raw == null || raw.isEmpty) {
      events = [];
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        events = [];
        return;
      }
      // 逐条解析：整表 catch 的写法会让「一条坏了」升级成「一百二十天全没了」，
      // 而这两件事对用户的代价完全不是一个量级。
      final out = <JEvent>[];
      for (final e in decoded) {
        try {
          if (e is Map) out.add(JEvent.fromJson(Map<String, dynamic>.from(e)));
        } catch (_) {
          // 丢掉这一条，其余照常恢复
        }
      }
      out.sort((a, b) => b.ts.compareTo(a.ts));
      events = out;
    } catch (_) {
      // 连 JSON 都不是，只能丢掉重来；用户损失的是历史，不是功能。
      events = [];
    }
  }

  static Future<void> _persist() async {
    try {
      await Bridge.setPref('journal', jsonEncode(events.map((e) => e.toJson()).toList()));
    } catch (_) {
      // 见文件头第 2 条：落盘失败不打断主流程
    }
  }

  /// 记一件事。这是唯一的写入口。返回刚写下的那条，方便调用方之后回填。
  static JEvent add(
    JKind kind,
    String title, {
    String detail = '',
    String tag = '',
    String verdict = 'neutral',
    bool spoken = false,
    DateTime? at,
  }) {
    final t = at ?? DateTime.now();
    final e = JEvent(
      ts: t.millisecondsSinceEpoch,
      kind: kind,
      title: title,
      detail: detail,
      tag: tag,
      verdict: verdict,
      spoken: spoken,
    );
    events.insert(0, e);
    _trim();
    _persist();
    return e;
  }

  /// 把某条标成「已朗读」，并落盘。不新增事件，只改标记。
  static void markSpoken(JEvent e) {
    if (e.spoken) return;
    e.spoken = true;
    _persist();
  }

  static void _trim() {
    final cutoff =
        DateTime.now().subtract(const Duration(days: maxAgeDays)).millisecondsSinceEpoch;
    events.removeWhere((e) => e.ts < cutoff);
    if (events.length > maxEvents) {
      events = events.sublist(0, maxEvents);
    }
  }

  static List<JEvent> onDay(String date) => events.where((e) => e.dateKey == date).toList();

  static List<JEvent> inMonth(int year, int month) =>
      events.where((e) => e.time.year == year && e.time.month == month).toList();

  /// 某天的统计。
  ///
  /// 兼容老数据：v1.3.0 及以前只留了每日汇总，没有流水。那些天用
  /// [legacy] 兜底，否则升级后整段历史会突然变空——看起来像丢了数据。
  static DayStat statOf(String date, {MorningRecord? legacy}) {
    final s = DayStat();
    for (final e in events) {
      if (e.dateKey != date) continue;
      switch (e.kind) {
        case JKind.wake:
          s.woke = true;
          if (s.wakeAt == 0) s.wakeAt = e.ts;
        case JKind.quiz:
          s.quizTotal++;
          if (e.isRight) s.quizCorrect++;
        case JKind.news:
          s.news++;
          if (e.spoken) s.newsSpoken++;
        case JKind.checkin:
          s.checkedIn = true;
          s.checkinAt = e.ts;
      }
    }
    if (!s.hasAny && legacy != null) {
      s.woke = legacy.completed || legacy.quizTotal > 0;
      s.quizTotal = legacy.quizTotal;
      s.quizCorrect = legacy.quizCorrect;
      s.news = legacy.newsDone ? 1 : 0;
      s.checkedIn = legacy.photoPath.isNotEmpty;
    }
    return s;
  }

  /// 本月的汇总。
  static MonthStat statOfMonth(int year, int month) {
    final ms = MonthStat();
    final seenDays = <String>{};
    final checkinDays = <String>{};
    for (final e in inMonth(year, month)) {
      // 有任意一条流水就算「这一天有记录」。
      // 只认「醒来」那一条会低估：中途开始答题、只补了打卡的日子也该算。
      seenDays.add(e.dateKey);
      switch (e.kind) {
        case JKind.wake:
          break;
        case JKind.quiz:
          ms.quizTotal++;
          if (e.isRight) ms.quizCorrect++;
        case JKind.news:
          ms.news++;
        case JKind.checkin:
          checkinDays.add(e.dateKey);
      }
    }
    // 老数据兜底：只有汇总、没有流水的日子。
    //
    // 必须跳过已经有流水的日期。否则同一天会被算两遍——今天既在流水里、
    // 又在 records 里，真机测试时就撞到过「答了 8 题、本月显示 11 道」。
    for (final r in Store.records) {
      if (seenDays.contains(r.date)) continue;
      final p = r.date.split('-');
      if (p.length != 3) continue;
      if (int.tryParse(p[0]) != year || int.tryParse(p[1]) != month) continue;
      if (!r.completed) continue;
      seenDays.add(r.date);
      ms.quizTotal += r.quizTotal;
      ms.quizCorrect += r.quizCorrect;
      if (r.photoPath.isNotEmpty) checkinDays.add(r.date);
    }
    ms.activeDays = seenDays.length;
    ms.checkinDays = checkinDays.length;
    return ms;
  }

  /// 清空（画像重置时一起调用，避免「画像清空了、日志还记着旧偏好」）
  static Future<void> clear() async {
    events = [];
    await _persist();
  }
}

class MonthStat {
  int activeDays = 0;
  int checkinDays = 0;
  int quizTotal = 0;
  int quizCorrect = 0;
  int news = 0;
}
