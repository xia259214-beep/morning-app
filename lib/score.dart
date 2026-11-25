// ============================================================================
// 总分钟账本（v1.22.0，规则第三版）
//
// 用户原话（v1.15.0）：「答对一题加 1 分，答错一题扣 1 分。」
// v1.22.0 用户反馈：「现在这个答题的分数不太对」——旧的 +1/−1 每题权重一样，
// 刷十道送分题和啃十道难题涨分一样多，正确率完全没参与，体现不出水平。
//
// 记分口径（写在这里，界面上的说明文字以此为准）：
//   · 难度档：判断题 1 分、单选 2 分、多选 3 分（个别题可在题库显式标注）
//   · 完全答对       +难度分
//   · 连击加成       连对第 3 题起每题额外 +1，封顶额外 +3（第 5 题起）
//   · 答错 / 多选漏选 −1   （固定扣 1 分——错一题罚一口，不该罚到不敢答题）
//   · 主动跳过       0    （跳过是「这块先不问」，不是答错，不该罚；也不清连击）
//   · 偏好题         0    （偏好题没有标准答案，本来就没有对错）
//
// 旧账（v1.15.0~v1.21.x 按 +1/−1 攒的分）：首次用新规则打开时冻结成
// [base]，界面上标「往期」，不折算、不硬拆——那才是编数据。
//   base = 旧总分 − 旧分科分（v1.21 之前攒的部分）
//   新总分 = base + 分科分（新规则的难度分也按领域记进分科账）
//
// 分数可以是负数。这不是 bug——答得比错得少，账就该是负的；
// 把它夹到 0 反而像在替用户遮掩。界面上负数用灰色显示，不做红色警示。
// ============================================================================

import 'dart:convert';

import 'core.dart';

class ScoreBook {
  /// 答错一题扣多少（正数，计算时取负）。旧规则错对同罚 1 分，
  /// 新规则错题固定温和扣 1 分，答对则按难度拿 1~3 分。
  static const int lossWrong = 1;

  /// 连击从第几题开始给加成
  static const int streakFrom = 3;

  /// 连击加成封顶（第 5 题及以后每题额外 +3）
  static const int streakBonusMax = 3;

  /// 往期冻结分：旧规则（+1/−1）攒下、不随新规则重算的部分
  final int base;

  /// 累计答对
  final int right;

  /// 累计答错（含多选漏选）
  final int wrong;

  /// 累计主动跳过
  final int skipped;

  /// 累计偏好题作答（无对错，只计数）
  final int pref;

  /// 当前连对数（答错清零，跳过/偏好题不打断）
  final int streak;

  /// 各领域净得分：答对 +难度分（含连击加成）、答错 −1，按题目的 axis 记。
  /// 新总分 = [base] + 分科分之和。
  final Map<String, int> byAxis;

  ScoreBook({
    this.base = 0,
    this.right = 0,
    this.wrong = 0,
    this.skipped = 0,
    this.pref = 0,
    this.streak = 0,
    Map<String, int>? byAxis,
  }) : byAxis = <String, int>{...?byAxis};

  static final ScoreBook zero = ScoreBook();

  /// 分科分加起来
  int get axisSum => byAxis.values.fold(0, (a, b) => a + b);

  /// 总分 = 往期冻结分 + 分科分
  int get total => base + axisSum;

  /// 往期（旧规则攒的、没分科的部分）。界面上标「往期」，不拆开。
  int get legacy => base;

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
      final right = ((m['right'] ?? 0) as num).toInt();
      final wrong = ((m['wrong'] ?? 0) as num).toInt();
      final axes = _parseAxes(m['axes']);
      final version = ((m['v'] ?? 1) as num).toInt();
      if (version >= 3) {
        return ScoreBook(
          base: ((m['base'] ?? 0) as num).toInt(),
          right: right,
          wrong: wrong,
          skipped: ((m['skipped'] ?? 0) as num).toInt(),
          pref: ((m['pref'] ?? 0) as num).toInt(),
          streak: ((m['streak'] ?? 0) as num).toInt(),
          byAxis: axes,
        );
      }
      // 旧账迁移（v1/v2 是 +1/−1 口径）：旧总分里不属于分科账的那部分
      // 冻结成往期分，答对答错的累计数照留（正确率还要用）。
      return ScoreBook(
        base: right - wrong - axes.values.fold(0, (a, b) => a + b),
        right: right,
        wrong: wrong,
        skipped: ((m['skipped'] ?? 0) as num).toInt(),
        pref: ((m['pref'] ?? 0) as num).toInt(),
        byAxis: axes,
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
        'base': base,
        'right': right,
        'wrong': wrong,
        'skipped': skipped,
        'pref': pref,
        'streak': streak,
        // 空的就不写，旧版本读到旧格式照样能跑
        if (byAxis.isNotEmpty) 'axes': byAxis,
        'v': 3,
      });

  /// 连对到第 [n] 题时的额外加分：第 3 题起 +1、第 4 题 +2、第 5 题起封顶 +3。
  static int streakBonus(int streak) =>
      streak < streakFrom ? 0 : (streak - streakFrom + 1).clamp(0, streakBonusMax);

  /// 没标领域的题落到这个兜底科目上。旧规则总分从 right/wrong 计数算，
  /// 这类题不传领域也不丢分；新规则总分只从分科账来，必须有地方落。
  static const String miscAxis = '未分科';

  /// 记一道有对错的题。[axis] 是这道题所属领域（见 profile.dart 的 kAxes），
  /// 传空则落到 [miscAxis] 兜底科目，照样计分不丢账。
  /// [lv] 是难度档（1~3，见 QItem.difficulty）。
  /// 返回 (新账本, 本题净得分)：净得分为正 = 挣到（难度分 + 连击加成），
  /// 负 = 扣掉，答题面板拿它显示「+2」。
  (ScoreBook, int) record({required bool correct, String axis = '', int lv = 2}) {
    final level = lv.clamp(1, 3);
    final nextStreak = correct ? streak + 1 : 0;
    final delta = correct ? level + streakBonus(nextStreak) : -lossWrong;
    final key = axis.isEmpty ? miscAxis : axis;
    final next = <String, int>{...byAxis};
    next[key] = (next[key] ?? 0) + delta;
    if (next[key] == 0) next.remove(key);
    return (
      _copy(
        right: right + (correct ? 1 : 0),
        wrong: wrong + (correct ? 0 : 1),
        streak: nextStreak,
        byAxis: next,
      ),
      delta,
    );
  }

  /// 记一次主动跳过（不计分，所以没有分科；连击不打断——跳过不是答错）
  ScoreBook recordSkip() => _copy(skipped: skipped + 1);

  /// 记一道没有对错的偏好题（连击同样不打断）
  ScoreBook recordPref() => _copy(pref: pref + 1);

  ScoreBook _copy({
    int? right,
    int? wrong,
    int? skipped,
    int? pref,
    int? streak,
    Map<String, int>? byAxis,
  }) =>
      ScoreBook(
        base: base,
        right: right ?? this.right,
        wrong: wrong ?? this.wrong,
        skipped: skipped ?? this.skipped,
        pref: pref ?? this.pref,
        streak: streak ?? this.streak,
        byAxis: byAxis ?? this.byAxis,
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
