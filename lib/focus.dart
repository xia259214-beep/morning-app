// ============================================================================
// 今日之门：四个领域按天轮值
//
// 用户的话：「这 4 个其实每天只放出来一个，其他三个都禁掉。这样子也是
// 有一口喘气的机会，但是都放出来，反而人的懒惰性是处理不了的。」
//
// 四个领域同时摆着，人会挑自己熟的那门答、或者干脆一门都不点；每天只开
// 一门，今天该做什么不用选，四天轮一遍，覆盖反而更全。
//
// 门控是硬约束：不只是首页格子置灰，抽题层也只从今天这门里出题。
// 唯一的例外是用户主动选「全部」档——那是一次走完整座山，属于他自己
// 决定今天不喘气，不算「放出来让人挑」。
// ============================================================================

/// 一个领域。四门加起来覆盖题库全部十三个一级分支，不落下一道题。
class FocusArea {
  final String id;
  final String name;
  final String note;

  /// 这一门包含的一级分支
  final List<String> roots;

  /// 轮值序号 0~3
  final int index;

  const FocusArea({
    required this.id,
    required this.name,
    required this.note,
    required this.roots,
    required this.index,
  });

  Set<String> get rootSet => roots.toSet();
}

const List<FocusArea> kFocusAreas = <FocusArea>[
  FocusArea(
    id: 'life',
    name: '生活',
    note: '吃住行、身体、钱和身边的事',
    roots: ['生活', '健康', '钱', '社会', '环境'],
    index: 0,
  ),
  FocusArea(
    id: 'tool',
    name: '工具',
    note: '手里的东西，和它们怎么运转',
    roots: ['工具', '科技'],
    index: 1,
  ),
  FocusArea(
    id: 'hobby',
    name: '爱好',
    note: '闲下来你在做什么、关心什么',
    roots: ['爱好', '文化', '体育', '世界', '军事'],
    index: 2,
  ),
  FocusArea(
    id: 'work',
    name: '职业',
    note: '你靠什么吃饭，手上是什么活',
    roots: ['职业'],
    index: 3,
  ),
];

class DailyFocus {
  /// 本地日期序号。用本地零点而不是 UTC 零点，保证国内凌晨换日时
  /// 不会提前八小时把门换了。
  static int dayIndex(DateTime day) =>
      DateTime(day.year, day.month, day.day).millisecondsSinceEpoch ~/ 86400000;

  static FocusArea of(DateTime day) => kFocusAreas[dayIndex(day) % kFocusAreas.length];

  static FocusArea get today => of(DateTime.now());

  static Set<String> get todayRoots => today.rootSet;

  /// 距下一次开放还有几天；今天开放返回 0
  static int daysUntil(FocusArea a, {DateTime? now}) {
    final n = now ?? DateTime.now();
    for (var i = 0; i <= kFocusAreas.length + 1; i++) {
      if (of(n.add(Duration(days: i))).id == a.id) return i;
    }
    return kFocusAreas.length;
  }

  /// 置灰格子上的说明：哪天开放
  static String openHint(FocusArea a, {DateTime? now}) {
    final n = now ?? DateTime.now();
    final d = daysUntil(a, now: n);
    if (d == 0) return '今天开放';
    final at = n.add(Duration(days: d));
    final w = '一二三四五六日'[at.weekday - 1];
    final label = d == 1 ? '明天' : (d == 2 ? '后天' : '$d 天后');
    return '$label（${at.month}/${at.day} 周$w）开放';
  }

  /// 四门的名字，用于说明文案
  static String get roster => kFocusAreas.map((e) => e.name).join(' → ');
}
