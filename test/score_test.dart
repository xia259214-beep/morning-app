import 'package:flutter_test/flutter_test.dart';
import 'package:morning/core.dart';
import 'package:morning/score.dart';

/// 总分的口径测试（v1.22.1 第四版规则：小数分值）。每一条都会被用户拿来
/// 对账，必须钉死。
///
/// 规则：
///   · 答对：判断 +1 / 单选 +1.35 / 多选 +1.55（gain 由调用方传）
///   · 连击：连对 2 题 +0.3、5 题 +0.5、7 题 +0.7、10 题 +0.9、12 题封顶 +1.12
///   · 完全答错 −1 · 纯漏选 −0.01 · 漏选+选错 −1.12 · 跳过 −0.1 · 偏好题 0
///   · 答错/漏选清连击；跳过/偏好题不打断
///   · 旧规则（±1、难度分）攒的账冻结成「往期」，不折算
void main() {
  setUp(() {
    Store.settings = {};
    ScoreBook.invalidate();
  });

  test('题型分值：判断 +1、单选 +1.35、多选 +1.55', () {
    var s = ScoreBook.zero;
    late double d1, d2, d3;
    (s, d1) = s.record(outcome: ScoreOutcome.right, gain: 1.0);
    (s, d2) = s.record(outcome: ScoreOutcome.right, gain: 1.35);
    (s, d3) = s.record(outcome: ScoreOutcome.right, gain: 1.55);

    expect(d1, 1.0, reason: '第 1 题还没连击');
    expect(d2, 1.65, reason: '连对第 2 题：题型分 + 连击 0.3');
    expect(d3, 1.85, reason: '连击档位到 5 题才涨到 0.5');
    expect(s.right, 3);
    expect(s.total, 4.5);
    expect(s.accuracy, 100);
  });

  test('三种错法扣分不一样：完全答错 −1 · 纯漏选 −0.01 · 漏选+选错 −1.12', () {
    var s = ScoreBook.zero;
    late double dw, dm, dmx;
    (s, dw) = s.record(outcome: ScoreOutcome.wrong);
    (s, dm) = s.record(outcome: ScoreOutcome.miss);
    (s, dmx) = s.record(outcome: ScoreOutcome.missWrong);

    expect(dw, -1);
    expect(dm, -0.01, reason: '纯漏选罚一口意思一下');
    expect(dmx, -1.12, reason: '漏选还选错，比纯漏选罚得重');
    expect(s.wrong, 3, reason: '漏选也算答错一题，正确率要用');
    expect(s.total, -2.13);
    expect(s.streak, 0, reason: '没答对就连击清零');
  });

  test('连击档位：2 题 +0.3、5 题 +0.5、7 题 +0.7、10 题 +0.9、12 题 +1.12 封顶', () {
    expect(ScoreBook.streakBonus(1), 0);
    expect(ScoreBook.streakBonus(2), 0.3);
    expect(ScoreBook.streakBonus(4), 0.3);
    expect(ScoreBook.streakBonus(5), 0.5);
    expect(ScoreBook.streakBonus(6), 0.5);
    expect(ScoreBook.streakBonus(7), 0.7);
    expect(ScoreBook.streakBonus(9), 0.7);
    expect(ScoreBook.streakBonus(10), 0.9);
    expect(ScoreBook.streakBonus(11), 0.9);
    expect(ScoreBook.streakBonus(12), 1.12);
    expect(ScoreBook.streakBonus(99), 1.12, reason: '封顶 1.12，不能无限滚');
  });

  test('连击在账里真实生效：连对 5 道单选 = 5×1.35 + 0.3×3 + 0.5', () {
    var s = ScoreBook.zero;
    for (var i = 0; i < 5; i++) {
      (s, _) = s.record(outcome: ScoreOutcome.right, gain: 1.35, axis: '科技');
    }
    // 连对数 1..5 → 加成 0,0.3,0.3,0.3,0.5 = 1.4；6.75 + 1.4
    expect(s.total, 8.15);
    expect(s.byAxis['科技'], s.total);
  });

  test('答错清连击；跳过扣 0.1 但不打断连击；偏好题不计分', () {
    var s = ScoreBook.zero;
    for (var i = 0; i < 2; i++) {
      (s, _) = s.record(outcome: ScoreOutcome.right, gain: 1.0, axis: '科技');
    }
    expect(s.streak, 2);
    s = s.recordSkip(axis: '科技');
    expect(s.streak, 2, reason: '跳过不是答错，连击不断');
    expect(s.total, 2.2, reason: '两题 2.3 分，跳过扣 0.1');
    expect(s.skipped, 1);
    s = s.recordPref();
    expect(s.streak, 2);
    expect(s.total, 2.2, reason: '偏好题不计分');
    late double d;
    (s, d) = s.record(outcome: ScoreOutcome.wrong, axis: '科技');
    expect(d, -1);
    expect(s.streak, 0, reason: '答错连击清零');
    // 再答对从第 1 题重新起算，没有加成
    (s, d) = s.record(outcome: ScoreOutcome.right, gain: 1.0, axis: '科技');
    expect(d, 1.0);
  });

  test('浮点误差不进账本：反复跳过也是干净的两位小数', () {
    var s = ScoreBook.zero;
    for (var i = 0; i < 3; i++) {
      s = s.recordSkip();
    }
    expect(s.total, -0.3, reason: '0.1×3 不能算成 −0.30000000000000004');
    expect(ScoreBook.fmt(s.total), '-0.3');
    expect(ScoreBook.fmt(2.50), '2.5');
    expect(ScoreBook.fmt(88.0), '88');
    expect(ScoreBook.fmt(1.35), '1.35');
    expect(ScoreBook.fmt(-1.12), '-1.12');
  });

  test('分数可以是负数，不夹到 0', () {
    var s = ScoreBook.zero;
    for (var i = 0; i < 3; i++) {
      s = s.record(outcome: ScoreOutcome.wrong).$1;
    }
    expect(s.total, -3);
    expect(s.totalText, '-3');
    expect(s.accuracy, 0);
  });

  test('没答过有对错的题时正确率是 0，不是 NaN', () {
    final s = ScoreBook.zero.recordSkip().recordPref();
    expect(s.graded, 0);
    expect(s.accuracy, 0);
    expect(s.total, -0.1, reason: '跳过那 0.1 还是扣的');
  });

  test('load 能读回 settings 里的账（v4 含小数 base/axes/streak）', () {
    Store.settings = {
      'score':
          '{"base":8.5,"right":5,"wrong":2,"skipped":1,"pref":0,"streak":3,'
          '"axes":{"科技":4.35,"体育":-0.1},"v":4}',
    };
    final s = ScoreBook.load();
    expect(s.base, 8.5);
    expect(s.streak, 3);
    expect(s.byAxis['科技'], 4.35);
    expect(s.byAxis['体育'], -0.1);
    expect(s.total, 12.75, reason: '往期 8.5 + 分科 4.25');
    expect(s.legacy, 8.5);

    final round = ScoreBook.load().toJson();
    expect(round.contains('"base":8.5'), isTrue);
    expect(round.contains('"streak":3'), isTrue);
    expect(round.contains('"v":4'), isTrue);
  });

  test('旧账迁移：v3 难度分冻结成往期，总分一分不丢', () {
    Store.settings = {
      'score':
          '{"base":0,"right":5,"wrong":2,"skipped":1,"pref":0,'
          '"axes":{"科技":2,"体育":1},"v":3}',
    };
    final s = ScoreBook.load();
    expect(s.base, 0);
    expect(s.total, 3, reason: '迁移后总分和旧版一模一样');
    expect(s.legacy, 0);

    // 再答对一道单选（第 1 题，无连击 +1.35），总分 3 → 4.35
    final (s2, d) = s.record(outcome: ScoreOutcome.right, gain: 1.35, axis: '科技');
    expect(d, 1.35);
    expect(s2.total, 4.35);
    expect(s2.legacy, 0, reason: '新账记进了分科，往期不变');
  });

  test('旧账迁移：没分科的旧总分全进往期', () {
    Store.settings = {
      'score': '{"right":5,"wrong":2,"skipped":1,"pref":0,"v":1}',
    };
    final s = ScoreBook.load();
    expect(s.total, 3);
    expect(s.byAxis, isEmpty);
    expect(s.legacy, 3);
  });

  test('坏数据当没记过，不抛异常', () {
    Store.settings = {'score': '这不是 JSON'};
    expect(ScoreBook.load().total, 0);
  });

  test('合并两本账时取答得多的那份，不相加', () {
    final a = ScoreBook(right: 10, wrong: 2);
    final b = ScoreBook(right: 3, wrong: 0);
    expect(ScoreBook.pickRicher(a, b).answered, 12);
    expect(ScoreBook.pickRicher(b, a).answered, 12);
  });

  test('分科记账：各科净分之和 + 往期 = 总分', () {
    var s = ScoreBook.zero;
    s = s.record(outcome: ScoreOutcome.right, gain: 1.55, axis: '科技').$1;
    s = s.record(outcome: ScoreOutcome.right, gain: 1.0, axis: '科技').$1;
    s = s.record(outcome: ScoreOutcome.wrong, axis: '体育').$1;
    s = s.record(outcome: ScoreOutcome.miss, axis: '文化').$1;
    s = s.record(outcome: ScoreOutcome.missWrong, axis: '生活').$1;
    s = s.recordSkip(axis: '健康');
    // 科技 +2.85（连击第 2 题 +0.3）、体育 −1、文化 −0.01、生活 −1.12、健康 −0.1
    expect(s.byAxis['科技'], 2.85);
    expect(s.byAxis['体育'], -1);
    expect(s.byAxis['文化'], -0.01);
    expect(s.byAxis['生活'], -1.12);
    expect(s.byAxis['健康'], -0.1);
    expect(s.axisSum + s.base, s.total, reason: '分科加起来必须等于总分，榜上才敢摆出来');
    expect(s.legacy, 0);
  });

  test('一科被抵成 0 分就不占一行', () {
    var s = ScoreBook.zero;
    s = s.record(outcome: ScoreOutcome.right, gain: 0.1, axis: '健康').$1;
    s = s.recordSkip(axis: '健康');
    expect(s.byAxis.containsKey('健康'), isFalse);
    expect(s.total, 0);
  });

  test('不知道科目时落到「未分科」兜底，照样计分不丢账', () {
    final (s, d) = ScoreBook.zero.record(outcome: ScoreOutcome.right, gain: 1.35);
    expect(d, 1.35);
    expect(s.total, 1.35);
    expect(s.byAxis[ScoreBook.miscAxis], 1.35, reason: '兜底科目也是分科账的一员');
    expect(s.legacy, 0);
  });

  test('榜单入口取整：totalInt 四舍五入', () {
    final s = ScoreBook(byAxis: {'科技': 13.4});
    expect(s.totalInt, 13);
    final s2 = ScoreBook(byAxis: {'科技': 13.5});
    expect(s2.totalInt, 14);
  });
}
