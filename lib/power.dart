// ============================================================================
// 领域战力（V4）
//
// 跟画像 score 分开记账：画像只增不减，用来挑新闻；战力有加有扣，用来画
// 那张多边形战力图——答对这个领域 +分，答错扣分，跳过/不熟也扣分。
// 用户原话：「回答了哪个方面的问题，就给你加哪方面的分，回答错了哪个方面，
// 你不喜欢哪个方面，它那个分就相继的扣。」
//
// 每个维度从 50 起（中性），范围 0~100。不答不该是 0 分——那会画出一个
// 塌掉的角，像在说「你很差」；50 是「还没看清」，答了才有起伏。
// ============================================================================

import 'dart:convert';

import 'core.dart';
import 'profile.dart';

class PowerChart {
  static const double initial = 50;
  static const double min = 0;
  static const double max = 100;

  /// 答对 / 多选漏选 / 答错 / 跳过 / 偏好题选了这个领域
  static const double gainRight = 6;
  static const double gainPartial = 1.5;
  static const double lossWrong = -5;
  static const double lossSkip = -3;
  static const double gainPref = 2;

  final Map<String, double> values;

  PowerChart([Map<String, double>? v])
      : values = {
          for (final a in kAxes)
            a: ((v?[a] ?? initial) as num).toDouble().clamp(min, max).toDouble(),
        };

  static PowerChart? _cached;
  static PowerChart get instance => _cached ??= load();

  /// 排序固定按 kAxes，雷达图的十个角不能今天换一个明天换一个
  List<double> get ordered => [for (final a in kAxes) values[a] ?? initial];

  /// 0~1，给雷达图用
  List<double> get normalized => [for (final v in ordered) (v / max).clamp(0.0, 1.0)];

  double of(String axis) => values[axis] ?? initial;

  void _add(String axis, double delta) {
    if (!values.containsKey(axis)) return;
    values[axis] = (values[axis]! + delta).clamp(min, max).toDouble();
  }

  void recordRight(String axis, {bool partial = false}) =>
      _add(axis, partial ? gainPartial : gainRight);

  void recordWrong(String axis, {bool partial = false}) =>
      _add(axis, partial ? gainPartial : lossWrong);

  void recordSkip(String axis) => _add(axis, lossSkip);

  /// 偏好题没有对错，选了只给一点正向证据
  void recordPref(String axis) => _add(axis, gainPref);

  /// 一次判分的总入口，答题面板用
  void apply({
    required String axis,
    bool? correct,
    bool partial = false,
    bool skipped = false,
    bool pref = false,
  }) {
    if (skipped) {
      recordSkip(axis);
    } else if (pref) {
      recordPref(axis);
    } else if (correct == true) {
      recordRight(axis, partial: partial);
    } else {
      recordWrong(axis, partial: partial);
    }
  }

  String toJson() => jsonEncode(values);

  static PowerChart load() {
    final raw = Store.s('power', '');
    if (raw.isEmpty) return PowerChart();
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return PowerChart({
        for (final a in kAxes) a: ((m[a] ?? initial) as num).toDouble(),
      });
    } catch (_) {
      return PowerChart();
    }
  }

  Future<void> save() async {
    Store.set('power', toJson());
    await Store.saveSettings();
  }

  static void invalidate() => _cached = null;

  // ---- 对拼码里的紧凑编码 ------------------------------------------------
  //
  // 每维 0~99 两位十进制，十维正好 20 个字符。CX2 码带上它，对方贴进来
  // 就能看到彼此的战力图——谁的数据都不上传，还是靠那一段码交换。

  String toCode() => kAxes
      .map((a) => values[a]!.round().clamp(0, 99).toString().padLeft(2, '0'))
      .join();

  static PowerChart? fromCode(String s) {
    if (s.length != kAxes.length * 2) return null;
    final m = <String, double>{};
    for (var i = 0; i < kAxes.length; i++) {
      final n = int.tryParse(s.substring(i * 2, i * 2 + 2));
      if (n == null || n < 0 || n > 99) return null;
      m[kAxes[i]] = n.toDouble();
    }
    return PowerChart(m);
  }
}
