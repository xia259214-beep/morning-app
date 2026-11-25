import 'package:flutter_test/flutter_test.dart';
import 'package:morning/core.dart';
import 'package:morning/score.dart';

/// 总分的口径测试（v1.22.0 第三版规则）。每一条都会被用户拿来对账，必须钉死。
///
/// 规则：
///   · 答对 +难度分（判断 1 / 单选 2 / 多选 3）
///   · 连对第 3 题起每题额外 +1，封顶 +3
///   · 答错 / 多选漏选 −1（温和扣分）
///   · 跳过 / 偏好题 0，且不打断连击
///   · 旧规则（±1）攒的账冻结成「往期」，不折算
void main() {
  setUp(() {
    Store.settings = {};
    ScoreBook.invalidate();
  });

  test('难度计分：判断 +1、单选 +2、多选 +3，答错固定 −1', () {
    var s = ScoreBook.zero;
    late int d1, d2, d3, d4;
    (s, d1) = s.record(correct: true, lv: 1);
    (s, d2) = s.record(correct: true, lv: 2);
    (s, d3) = s.record(correct: true, lv: 3);
    (s, d4) = s.record(correct: false, lv: 3);

    expect(d1, 1);
    expect(d2, 2);
    expect(d3, 4, reason: '连对第 3 题正好开始给加成：+3 难度 +1 连击');
    expect(d4, -1, reason: '答错固定扣 1，答错不该比答对难题还疼');
    expect(s.right, 3);
    expect(s.wrong, 1);
    expect(s.total, 6);
    expect(s.answered, 4);
    expect(s.accuracy, 75);
  });

  test('连击加成：第 3 题起 +1、第 4 题 +2、第 5 题起封顶 +3', () {
    var s = ScoreBook.zero;
    final gains = <int>[];
    for (var i = 0; i < 6; i++) {
      late int d;
      (s, d) = s.record(correct: true, axis: '科技', lv: 1);
      gains.add(d);
    }
    // 每题难度 1：+1、+1、(+1+1)=2、(+1+2)=3、(+1+3)=4、(+1+3)=4
    expect(gains, [1, 1, 2, 3, 4, 4]);
    expect(s.total, 15);
    expect(ScoreBook.streakBonus(2), 0);
    expect(ScoreBook.streakBonus(3), 1);
    expect(ScoreBook.streakBonus(4), 2);
    expect(ScoreBook.streakBonus(5), 3);
    expect(ScoreBook.streakBonus(99), 3, reason: '封顶 +3，不能无限滚');
  });

  test('答错清连击；跳过和偏好题不打断连击、也不计分', () {
    var s = ScoreBook.zero;
    for (var i = 0; i < 3; i++) {
      s = s.record(correct: true, axis: '科技', lv: 1).$1;
    }
    expect(s.streak, 3);
    s = s.recordSkip();
    expect(s.streak, 3, reason: '跳过不是答错，连击不断');
    expect(s.total, 4, reason: '2+1+1，跳过 0 分');
    s = s.recordPref();
    expect(s.streak, 3);
    late int d;
    (s, d) = s.record(correct: false, axis: '科技', lv: 1);
    expect(d, -1);
    expect(s.streak, 0, reason: '答错连击清零');
    // 再答对从第 1 题重新起算，没有加成
    (s, d) = s.record(correct: true, axis: '科技', lv: 1);
    expect(d, 1);
  });

  test('分数可以是负数，不夹到 0', () {
    var s = ScoreBook.zero;
    for (var i = 0; i < 3; i++) {
      s = s.record(correct: false).$1;
    }
    expect(s.total, -3);
    expect(s.totalText, '-3');
    expect(s.accuracy, 0);
  });

  test('没答过有对错的题时正确率是 0，不是 NaN', () {
    final s = ScoreBook.zero.recordSkip().recordPref();
    expect(s.graded, 0);
    expect(s.accuracy, 0);
    expect(s.total, 0);
  });

  test('load 能读回 settings 里的账（v3 含 base/streak）', () {
    Store.settings = {
      'score':
          '{"base":8,"right":5,"wrong":2,"skipped":1,"pref":0,"streak":2,"axes":{"科技":4},"v":3}',
    };
    final s = ScoreBook.load();
    expect(s.base, 8);
    expect(s.streak, 2);
    expect(s.byAxis['科技'], 4);
    expect(s.total, 12, reason: '往期 8 + 分科 4');
    expect(s.legacy, 8);

    final round = ScoreBook.load().toJson();
    expect(round.contains('"base":8'), isTrue);
    expect(round.contains('"streak":2'), isTrue);
  });

  test('旧账迁移：v2 的总分冻结成往期，一分不丢也不折算', () {
    Store.settings = {
      'score':
          '{"right":5,"wrong":2,"skipped":1,"pref":0,"axes":{"科技":2,"体育":1},"v":2}',
    };
    final s = ScoreBook.load();
    // 旧总分 3，分科 3，往期 = 3 − 3 = 0
    expect(s.base, 0);
    expect(s.total, 3, reason: '迁移后总分和旧版一模一样');
    expect(s.legacy, 0);
    expect(s.streak, 0, reason: '连击是新规则才有的，旧账从零起算');

    // 再答对一道单选（无连击 +2），总分 3 → 5
    final (s2, d) = s.record(correct: true, axis: '科技', lv: 2);
    expect(d, 2);
    expect(s2.total, 5);
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
    final a = ScoreBook(right: 10, wrong: 2, base: 0);
    final b = ScoreBook(right: 3, wrong: 0, base: 0);
    expect(ScoreBook.pickRicher(a, b).answered, 12);
    expect(ScoreBook.pickRicher(b, a).answered, 12);
  });

  test('分科记账：各科净分之和 + 往期 = 总分', () {
    var s = ScoreBook.zero;
    s = s.record(correct: true, axis: '科技', lv: 3).$1;
    s = s.record(correct: true, axis: '科技', lv: 1).$1;
    s = s.record(correct: false, axis: '体育').$1;
    s = s.record(correct: true, axis: '文化', lv: 2).$1;
    // 科技：+3、(+1) = 4；体育 −1；文化 +2；连击到第 4 题给文化加了 2
    expect(s.byAxis['科技'], 4);
    expect(s.byAxis['体育'], -1);
    expect(s.byAxis['文化'], 2,
        reason: '体育那题答错已把连击清零，文化没有加成，只拿难度 2');
    expect(s.axisSum + s.base, s.total, reason: '分科加起来必须等于总分，榜上才敢摆出来');
    expect(s.legacy, 0);
  });

  test('一科被抵成 0 分就不占一行', () {
    final s = ScoreBook.zero
        .record(correct: true, axis: '健康', lv: 1)
        .$1
        .record(correct: false, axis: '健康')
        .$1;
    expect(s.byAxis.containsKey('健康'), isFalse);
    expect(s.total, 0);
  });

  test('不知道科目时落到「未分科」兜底，照样计分不丢账', () {
    final (s, d) = ScoreBook.zero.record(correct: true, lv: 2);
    expect(d, 2);
    expect(s.total, 2);
    expect(s.byAxis[ScoreBook.miscAxis], 2, reason: '兜底科目也是分科账的一员');
    expect(s.legacy, 0);
  });

  test('分科能存能读', () {
    Store.settings = {
      'score':
          '{"base":0,"right":3,"wrong":0,"skipped":0,"pref":0,"streak":3,"axes":{"科技":2,"体育":1},"v":3}',
    };
    final s = ScoreBook.load();
    expect(s.byAxis['科技'], 2);
    expect(s.byAxis['体育'], 1);
    expect(s.axisSum + s.base, s.total);
    expect(s.legacy, 0);
  });
}
