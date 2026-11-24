// ============================================================================
// 总分钟账本（v1.15.0）
//
// 用户原话：「答对一题加 1 分，答错一题扣 1 分，给一个总分。」
//
// 为什么单独开一本账，而不是复用 [PowerChart] 或 [QuizTally]：
//   1. 战力是十维的，用来画雷达图，问的是「你哪块强」，答不出「我一共多少分」；
//   2. QuizTally 只活一轮，退出就没了，用户要的是**跨天累积**的一个数；
//   3. 分数要能跟着备份走（见 portable.dart），单独一个 key 才好搬。
//
// 记分口径（写在这里，界面上的说明文字以此为准）：
//   · 完全答对   +1
//   · 答错 / 多选漏选   -1   （没选全就是没答对，不四舍五入成对）
//   · 主动跳过   0    （跳过是「这块先不问」，不是答错，不该罚）
//   · 偏好题     0    （偏好题没有标准答案，本来就没有对错）
//
// v1.21.0 起按领域分科记账（[byAxis]）：用户要看到榜上每一行的分数是
// 「科技 +6 · 体育 +3」这么凑出来的，光一个总分说不出谁强在哪。
// 旧版本的总分没有分科，[legacy] 把那部分单独留出来，界面上标「往期」，
// 不硬拆成十份假装知道——那才是编数据。
//
// 分数可以是负数。这不是 bug——答得比错得少，账就该是负的；
// 把它夹到 0 反而像在替用户遮掩。界面上负数用灰色显示，不做红色警示。
// ============================================================================

import 'dart:convert';

import 'core.dart';

class ScoreBook {
  /// 答对一题加多少
  static const int gainRight = 1;

  /// 答错一题扣多少（正数，计算时取负）
  static const int lossWrong = 1;

  /// 累计答对
  final int right;

  /// 累计答错（含多选漏选）
  final int wrong;

  /// 累计主动跳过
  final int skipped;

  /// 累计偏好题作答（无对错，只计数）
  final int pref;

  /// 各领域净得分：答对 +1、答错 −1，按题目的 axis 记。
  /// 十项之和就是 [total]——除了 [legacy] 那部分旧账。
  final Map<String, int> byAxis;

  ScoreBook({
    this.right = 0,
    this.wrong = 0,
    this.skipped = 0,
    this.pref = 0,
    Map<String, int>? byAxis,
  }) : byAxis = <String, int>{...?byAxis};

  static final ScoreBook zero = ScoreBook();

  /// 分科分加起来
  int get axisSum => byAxis.values.fold(0, (a, b) => a + b);

  /// 这一版之前攒下的总分：只知道总数，不知道落在哪几科。
  /// 界面标「往期」，不拆开。
  int get legacy => total - axisSum;

  /// 总分 = 答对 ×1 − 答错 ×1
  int get total => right * gainRight - wrong * lossWrong;

  /// 一共做过多少题（含跳过、偏好题）
  int get answered => right + wrong + skipped + pref;

  /// 有对错的题数，算正确率用
  int get graded => right + wrong;

  /// 正确率 0~100；没答过有对错的题时返回 0
  int get accuracy => graded == 0 ? 0 : (right * 100 / graded).round();

  /// 显示用：正数不加号（总分 +128 看着像涨跌幅），负数带负号
  String get totalText => '$total';

  // ---- 缓存：我的页、画像卡、答题页三处都要读，别每次都解一遍 JSON ----
  static ScoreBook? _cached;
  static ScoreBook get instance => _cached ??= load();

  static ScoreBook load() {
    final raw = Store.s('score', '');
    if (raw.isEmpty) return ScoreBook();
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return ScoreBook(
        right: ((m['right'] ?? 0) as num).toInt(),
        wrong: ((m['wrong'] ?? 0) as num).toInt(),
        skipped: ((m['skipped'] ?? 0) as num).toInt(),
        pref: ((m['pref'] ?? 0) as num).toInt(),
        byAxis: _parseAxes(m['axes']),
      );
    } catch (_) {
      // 坏数据当没记过，不阻断答题
      return ScoreBook();
    }
  }

  static Map<String, int> _parseAxes(Object? raw) {
    if (raw is! Map) return const {};
    final out = <String, int>{};
    raw.forEach((k, v) {
      if (v is num && v != 0) out['$k'] = v.toInt();
    });
    return out;
  }

  String toJson() => jsonEncode({
        'right': right,
        'wrong': wrong,
        'skipped': skipped,
        'pref': pref,
        // 空的就不写，旧版本读到旧格式照样能跑
        if (byAxis.isNotEmpty) 'axes': byAxis,
        'v': 2,
      });

  /// 记一道有对错的题。[axis] 是这道题所属领域（见 profile.dart 的 kAxes），
  /// 传空字符串表示不知道该归哪一科，那就只记总分。
  ScoreBook record({required bool correct, String axis = ''}) {
    final next = <String, int>{...byAxis};
    if (axis.isNotEmpty) {
      next[axis] = (next[axis] ?? 0) + (correct ? gainRight : -lossWrong);
      if (next[axis] == 0) next.remove(axis);
    }
    return ScoreBook(
      right: right + (correct ? 1 : 0),
      wrong: wrong + (correct ? 0 : 1),
      skipped: skipped,
      pref: pref,
      byAxis: next,
    );
  }

  /// 记一次主动跳过（不计分，所以没有分科）
  ScoreBook recordSkip() => ScoreBook(
        right: right,
        wrong: wrong,
        skipped: skipped + 1,
        pref: pref,
        byAxis: byAxis,
      );

  /// 记一道没有对错的偏好题
  ScoreBook recordPref() => ScoreBook(
        right: right,
        wrong: wrong,
        skipped: skipped,
        pref: pref + 1,
        byAxis: byAxis,
      );

  /// 一份新账写回。答题面板判完分就调它。
  Future<void> save() async {
    Store.set('score', toJson());
    _cached = this;
    await Store.saveSettings();
  }

  static void invalidate() => _cached = null;

  /// 两本账合并时用（见 portable.dart）：谁答得多听谁的，避免同一道题
  /// 在两台手机上各记一次、合并后分数虚高。
  static ScoreBook pickRicher(ScoreBook a, ScoreBook b) =>
      a.answered >= b.answered ? a : b;
}
