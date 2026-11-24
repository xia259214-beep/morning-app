// ============================================================================
// 十维等级：A B C D E F（v1.21.0）
//
// 用户原话：「它旁边不是有个圈吗？什么科技、生活、军事、环境什么的，
// 要有一个欧美的评分系统，那个评分就叫 A B C D E F。」
//
// 为什么不是直接显示 0~100 的数：十维的 63 分和 68 分差在哪，肉眼看不出来，
// 一百个数字摆在一张图上只剩噪声。A~F 六个字母一眼就知道强弱，也是
// 学校成绩单那套熟悉的语言，不需要再解释。
//
// 分档口径（与 PowerChart 的 0~100 对齐）：
//   A ≥ 85   这一段是「问得住」
//   B ≥ 68   稳
//   C ≥ 50   中性——刚进来每一维都从 50 起，所以初始就是 C，
//            读作「还没看清」，不是「你不行」
//   D ≥ 35   偏弱
//   E ≥ 20   弱
//   F < 20   这块基本没答过 / 答错得多
//
// 阈值刻意让 50 落在 C 的正中间：一个刚装上 App 的人打开这张图，
// 看到十个 C，是「还不知道」，不是一屏红叉。
// ============================================================================

import 'power.dart';
import 'profile.dart';

class AxisGrade {
  /// 从强到弱，界面上按这个顺序画图例
  static const List<String> letters = <String>['A', 'B', 'C', 'D', 'E', 'F'];

  static const double aLine = 85;
  static const double bLine = 68;
  static const double cLine = 50;
  static const double dLine = 35;
  static const double eLine = 20;

  /// 一个 0~100 的战力值 → 字母
  static String of(double value) {
    final v = value.isNaN ? 0.0 : value;
    if (v >= aLine) return 'A';
    if (v >= bLine) return 'B';
    if (v >= cLine) return 'C';
    if (v >= dLine) return 'D';
    if (v >= eLine) return 'E';
    return 'F';
  }

  /// 每个字母一句人话，给图例用
  static String wordOf(String letter) {
    switch (letter) {
      case 'A':
        return '问得住';
      case 'B':
        return '稳';
      case 'C':
        return '还没看清';
      case 'D':
        return '偏弱';
      case 'E':
        return '弱';
      default:
        return '基本空白';
    }
  }

  /// 十维各自的等级，顺序同 kAxes
  static List<String> axesOf(PowerChart p) =>
      <String>[for (final a in kAxes) of(p.of(a))];

  /// 综合等级：十维取平均再换字母。
  /// 用平均而不是「取最低」，是因为这张图问的是「整体在哪一档」；
  /// 单科的弱项在雷达图上自己会塌下去，不需要在这里重复罚一次。
  static String overallOf(PowerChart p) {
    final vals = p.ordered;
    if (vals.isEmpty) return 'C';
    final avg = vals.reduce((a, b) => a + b) / vals.length;
    return of(avg);
  }
}
