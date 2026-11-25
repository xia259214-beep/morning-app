// ============================================================================
// 总分钟账本（v1.22.1，规则第四版：小数分值）
//
// v1.22.1 用户定的精确分值（在第三版「难度加权」基础上细化）：
//   · 答对       判断 +1 · 单选 +1.35 · 多选 +1.55（分值见 QItem.gain）
//   · 完全答错   −1     （没碰到任何正确选项）
//   · 纯漏选     −0.01  （多选只选了正确项但没选全——罚一口意思一下）
//   · 漏选+选错  −1.12  （既碰了正确项又选了错误项）
//   · 跳过       −0.1   （跳过是有成本的，但罚得很轻）
//   · 偏好题     0      （没有标准答案，本来就没有对错）
//   · 连击       连对第 2 题起每题额外 +0.3，第 5 题 +0.5、第 7 题 +0.7、
//                第 10 题 +0.9、第 12 题起封顶 +1.12；答错/漏选清零，
//                跳过和偏好题不打断。
//
// 为什么改小数：1.35 / 1.55 / 1.12 这些值没法用整数表达。账本内部全部
// 用 double，但**每次记账都四舍五入到两位小数**——0.1 + 0.2 这类浮点误差
// 不许在账本里滚雪球。榜单和云端是整数列，入口处取整（见 leaderboard.dart）。
//
// 旧账（v1.15~v1.21 按 ±1 攒的分、v1.22.0 的难度分）：首次打开时冻结成
// [base]，界面上标「往期」，不折算、不硬拆——那才是编数据。
//   新总分 = base + 分科分之和（分科含「未分科」兜底科目）
//
// 分数可以是负数。这不是 bug——答得比错得少，账就该是负的；
// 把它夹到 0 反而像在替用户遮掩。界面上负数用灰色显示，不做红色警示。
// ============================================================================

import 'dart:convert';

import 'core.dart';

/// 一道有对错的题判出来是哪种结果。由 qbank.dart 的 [gradeOf] 给出。
enum ScoreOutcome {
  /// 完全答对
  right,

  /// 纯漏选：多选只选了正确项但没选全
  miss,

  /// 漏选+选错：碰了正确项，也选了错误项
  missWrong,

  /// 完全答错：没碰到任何正确选项
  wrong,
}

class ScoreBook {
  /// 完全答错扣多少
  static const double lossWrong = 1;

  /// 纯漏选扣多少（意思一下的罚）
  static const double lossMiss = 0.01;

  /// 漏选+选错扣多少
  static const double lossMissWrong = 1.12;

  /// 跳过一题扣多少
  static const double lossSkip = 0.1;

  /// 连击第一档：连对满 2 题开始给加成
  static const int streakFrom = 2;

  /// 往期冻结分：旧规则攒下、不随新规则重算的部分
  final double base;

  /// 累计答对
  final int right;

  /// 累计答错（含漏选、漏选+选错）
  final int wrong;

  /// 累计主动跳过
  final int skipped;

  /// 累计偏好题作答（无对错，只计数）
  final int pref;

  /// 当前连对数（答错/漏选清零，跳过/偏好题不打断）
  final int streak;

  /// 各领域净得分，按题目的 axis 记。新总分 = [base] + 分科分之和。
  final Map<String, double> byAxis;

  ScoreBook({
    this.base = 0,
    this.right = 0,
    this.wrong = 0,
    this.skipped = 0,
    this.pref = 0,
    this.streak = 0,
    Map<String, double>? byAxis,
  }) : byAxis = <String, double>{...?byAxis};

  static final ScoreBook zero = ScoreBook();

  /// 没标领域的题落到这个兜底科目上。旧规则总分从 right/wrong 计数算，
  /// 这类题不传领域也不丢分；新规则总分只从分科账来，必须有地方落。
  static const String miscAxis = '未分科';

  /// 四舍五入到两位小数。浮点误差（0.1+0.2=0.30000000000000004）不许进账本。
  static double r2(double v) => (v * 100).roundToDouble() / 100;

  /// 分科分加起来
  double get axisSum => r2(byAxis.values.fold(0.0, (a, b) => a + b));

  /// 总分 = 往期冻结分 + 分科分
  double get total => r2(base + axisSum);

  /// 榜单/云端用整数分：四舍五入，整数列存不下 1.35 这种精度
  int get totalInt => total.round();

  /// 往期（旧规则攒的、没分科的部分）。界面上标「往期」，不拆开。
  double get legacy => base;

  /// 一共做过多少题（含跳过、偏好题）
  int get answered => right + wrong + skipped + pref;

  /// 有对错的题数，算正确率用
  int get graded => right + wrong;

  /// 正确率 0~100；没答过有对错的题时返回 0
  int get accuracy => graded == 0 ? 0 : (right * 100 / graded).round();

  /// 显示用：整数不带小数点（88 不显示成 88.0），小数最多两位去掉尾零
  static String fmt(double v) {
    if (v == v.roundToDouble()) return v.round().toString();
    var t = v.toStringAsFixed(2);
    if (t.contains('.')) {
      t = t.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    }
    return t;
  }

  /// 总分的显示文本
  String get totalText => fmt(total);

  // ---- 缓存：我的页、画像卡、答题页三处都要读，别每次都解一遍 JSON ----
  static ScoreBook? _cached;
  static ScoreBook get instance => _cached ??= load();

  static double _d(Object? raw) => r2(((raw ?? 0) as num).toDouble());

  static ScoreBook load() {
    final raw = Store.s('score', '');
    if (raw.isEmpty) return ScoreBook();
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final right = ((m['right'] ?? 0) as num).toInt();
      final wrong = ((m['wrong'] ?? 0) as num).toInt();
      final axes = _parseAxes(m['axes']);
      final version = ((m['v'] ?? 1) as num).toInt();
      if (version >= 4) {
        return ScoreBook(
          base: _d(m['base']),
          right: right,
          wrong: wrong,
          skipped: ((m['skipped'] ?? 0) as num).toInt(),
          pref: ((m['pref'] ?? 0) as num).toInt(),
          streak: ((m['streak'] ?? 0) as num).toInt(),
          byAxis: axes,
        );
      }
      // 旧账迁移（v1~v3）：旧总分里不属于分科账的那部分冻结成往期分，
      // 答对答错的累计数照留（正确率还要用）。
      return ScoreBook(
        base: r2(right.toDouble() -
            wrong.toDouble() -
            axes.values.fold(0.0, (a, b) => a + b)),
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

  static Map<String, double> _parseAxes(Object? raw) {
    if (raw is! Map) return const {};
    final out = <String, double>{};
    raw.forEach((k, v) {
      if (v is num && v != 0) out['$k'] = _d(v);
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
        'v': 4,
      });

  /// 连对到第 [n] 题时的额外加分。
  /// 用户定的档：连对 2 题 +0.3、5 题 +0.5、7 题 +0.7、10 题 +0.9、12 题封顶 +1.12。
  static double streakBonus(int streak) {
    if (streak >= 12) return 1.12;
    if (streak >= 10) return 0.9;
    if (streak >= 7) return 0.7;
    if (streak >= 5) return 0.5;
    if (streak >= streakFrom) return 0.3;
    return 0;
  }

  /// 记一道有对错的题。[outcome] 是判分结果（见 [ScoreOutcome]），
  /// [gain] 是答对的分值（判断 1 / 单选 1.35 / 多选 1.55，见 QItem.gain），
  /// [axis] 是题目领域，传空落到 [miscAxis] 兜底科目。
  /// 返回 (新账本, 本题净得分)，答题面板拿它显示「+1.35」。
  (ScoreBook, double) record({
    required ScoreOutcome outcome,
    String axis = '',
    double gain = 1,
  }) {
    final nextStreak = outcome == ScoreOutcome.right ? streak + 1 : 0;
    final double delta = switch (outcome) {
      ScoreOutcome.right => r2(gain + streakBonus(nextStreak)),
      ScoreOutcome.miss => -lossMiss,
      ScoreOutcome.missWrong => -lossMissWrong,
      ScoreOutcome.wrong => -lossWrong,
    };
    final key = axis.isEmpty ? miscAxis : axis;
    final next = <String, double>{...byAxis};
    next[key] = r2((next[key] ?? 0) + delta);
    if (next[key] == 0) next.remove(key);
    return (
      _copy(
        right: right + (outcome == ScoreOutcome.right ? 1 : 0),
        wrong: wrong + (outcome == ScoreOutcome.right ? 0 : 1),
        streak: nextStreak,
        byAxis: next,
      ),
      delta,
    );
  }

  /// 记一次主动跳过：扣 0.1 分（跳过是有成本的，但罚得很轻），
  /// 连击不打断——跳过不是答错。[axis] 传空落到 [miscAxis] 兜底科目。
  ScoreBook recordSkip({String axis = ''}) {
    final key = axis.isEmpty ? miscAxis : axis;
    final next = <String, double>{...byAxis};
    next[key] = r2((next[key] ?? 0) - lossSkip);
    if (next[key] == 0) next.remove(key);
    return _copy(skipped: skipped + 1, byAxis: next);
  }

  /// 记一道没有对错的偏好题（不计分，连击同样不打断）
  ScoreBook recordPref() => _copy(pref: pref + 1);

  ScoreBook _copy({
    int? right,
    int? wrong,
    int? skipped,
    int? pref,
    int? streak,
    Map<String, double>? byAxis,
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
