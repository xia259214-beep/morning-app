import 'package:flutter_test/flutter_test.dart';
import 'package:morning/core.dart';
import 'package:morning/score.dart';

/// 总分的口径测试。规则只有三条，但每一条都会被用户拿来对账，必须钉死。
void main() {
  setUp(() {
    Store.settings = {};
    ScoreBook.invalidate();
  });

  test('答对 +1、答错 -1、跳过与偏好题不计分', () {
    var s = ScoreBook.zero.record(correct: true);
    s = s.record(correct: true);
    s = s.record(correct: false);
    s = s.recordSkip();
    s = s.recordPref();

    expect(s.right, 2);
    expect(s.wrong, 1);
    expect(s.total, 1, reason: '2 对 − 1 错 = 1 分');
    expect(s.answered, 5, reason: '跳过和偏好题算做过，但不算对错');
    expect(s.graded, 3);
    expect(s.accuracy, 67);
  });

  test('分数可以是负数，不夹到 0', () {
    var s = ScoreBook.zero;
    for (var i = 0; i < 3; i++) {
      s = s.record(correct: false);
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

  test('load 能读回 settings 里的账', () {
    Store.settings = {
      'score': '{"right":5,"wrong":2,"skipped":1,"pref":0}',
    };
    final s = ScoreBook.load();
    expect(s.right, 5);
    expect(s.wrong, 2);
    expect(s.total, 3);

    final round = ScoreBook.load().toJson();
    expect(round.contains('"right":5'), isTrue);
  });

  test('坏数据当没记过，不抛异常', () {
    Store.settings = {'score': '这不是 JSON'};
    expect(ScoreBook.load().total, 0);
  });

  test('合并两本账时取答得多的那份，不相加', () {
    final a = ScoreBook(right: 10, wrong: 2);
    final b = ScoreBook(right: 3, wrong: 0);
    expect(ScoreBook.pickRicher(a, b).total, 8);
    expect(ScoreBook.pickRicher(b, a).total, 8);
  });

  test('分科记账：各科净分之和 = 总分', () {
    var s = ScoreBook.zero.record(correct: true, axis: '科技');
    s = s.record(correct: true, axis: '科技');
    s = s.record(correct: false, axis: '体育');
    s = s.record(correct: true, axis: '文化');

    expect(s.byAxis['科技'], 2);
    expect(s.byAxis['体育'], -1);
    expect(s.byAxis['文化'], 1);
    expect(s.axisSum, s.total, reason: '分科加起来必须等于总分，榜上才敢摆出来');
    expect(s.legacy, 0);
  });

  test('一科被抵成 0 分就不占一行', () {
    final s = ScoreBook.zero
        .record(correct: true, axis: '健康')
        .record(correct: false, axis: '健康');
    expect(s.byAxis.containsKey('健康'), isFalse);
    expect(s.total, 0);
  });

  test('不知道科目时只记总分，算成「往期」', () {
    final s = ScoreBook.zero.record(correct: true);
    expect(s.total, 1);
    expect(s.byAxis, isEmpty);
    expect(s.legacy, 1, reason: '没分科的分要能单独认出来');
  });

  test('分科能存能读', () {
    Store.settings = {
      'score': '{"right":3,"wrong":0,"skipped":0,"pref":0,"axes":{"科技":2,"体育":1}}',
    };
    final s = ScoreBook.load();
    expect(s.byAxis['科技'], 2);
    expect(s.byAxis['体育'], 1);
    expect(s.axisSum, s.total);
    expect(s.legacy, 0);
  });

  test('旧格式（没有 axes）读进来当往期，不报错', () {
    Store.settings = {
      'score': '{"right":5,"wrong":2,"skipped":1,"pref":0,"v":1}',
    };
    final s = ScoreBook.load();
    expect(s.total, 3);
    expect(s.byAxis, isEmpty);
    expect(s.legacy, 3);
  });
}
