import 'package:flutter_test/flutter_test.dart';
import 'package:morning/core.dart';
import 'package:morning/grade.dart';
import 'package:morning/power.dart';
import 'package:morning/profile.dart';

/// A–F 的边界口径。六个档位就是六条边界，错一条整张图就读错了。
void main() {
  setUp(() {
    Store.settings = {};
    PowerChart.invalidate();
  });

  test('边界：85 / 68 / 50 / 35 / 20 各归哪一档', () {
    const cases = <List<Object>>[
      [100.0, 'A'],
      [85.0, 'A'],
      [84.9, 'B'],
      [68.0, 'B'],
      [67.9, 'C'],
      [50.0, 'C'],
      [49.9, 'D'],
      [35.0, 'D'],
      [34.9, 'E'],
      [20.0, 'E'],
      [19.9, 'F'],
      [0.0, 'F'],
    ];
    for (final c in cases) {
      final v = c[0] as double;
      expect(AxisGrade.of(v), c[1], reason: '$v 应该读作 ${c[1]}');
    }
  });

  test('刚装上 App：十维都是 50，全 C、综合 C——是「还没看清」不是「你不行」', () {
    final p = PowerChart();
    expect(p.ordered.every((v) => v == 50), isTrue);
    expect(AxisGrade.axesOf(p), List<String>.filled(kAxes.length, 'C'));
    expect(AxisGrade.overallOf(p), 'C');
  });

  test('十维加成满分时综合是 A', () {
    final p = PowerChart({for (final a in kAxes) a: 100.0});
    expect(AxisGrade.overallOf(p), 'A');
    expect(AxisGrade.axesOf(p).every((g) => g == 'A'), isTrue);
  });

  test('综合取平均，不是取最弱那科', () {
    // 九科 90、一科 0 → 平均 81 → B；取最低会读成 F
    final p = PowerChart({
      for (final a in kAxes) a: a == kAxes.first ? 0.0 : 90.0,
    });
    expect(AxisGrade.overallOf(p), 'B');
  });

  test('每个字母都有一句人话', () {
    for (final g in AxisGrade.letters) {
      expect(AxisGrade.wordOf(g).isNotEmpty, isTrue);
    }
    expect(AxisGrade.wordOf('C'), '还没看清');
  });
}
