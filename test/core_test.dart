import 'package:flutter_test/flutter_test.dart';
import 'package:morning/core.dart';

void main() {
  test('仅一次的闹钟：今天时间已过则顺延到明天', () {
    final a = Alarm(id: 1, hour: 6, minute: 30, days: []);
    final now = DateTime(2026, 11, 19, 7, 0);
    final next = a.nextTrigger(now)!;
    expect(next, DateTime(2026, 11, 20, 6, 30));
  });

  test('工作日闹钟：周五晚上取到的是下周一', () {
    final a = Alarm(id: 2, hour: 6, minute: 30, days: [1, 2, 3, 4, 5]);
    // 2026-11-20 是周五
    final now = DateTime(2026, 11, 20, 22, 0);
    final next = a.nextTrigger(now)!;
    expect(next.weekday, DateTime.monday);
    expect(next.hour, 6);
    expect(next.minute, 30);
  });

  test('关闭的闹钟不返回触发时间', () {
    final a = Alarm(id: 3, hour: 7, minute: 0, days: [1, 2, 3], enabled: false);
    expect(a.nextTrigger(DateTime.now()), isNull);
  });

  test('重复描述文案', () {
    expect(Alarm(id: 1, hour: 6, minute: 0, days: []).repeatText, '仅一次');
    expect(Alarm(id: 1, hour: 6, minute: 0, days: [1, 2, 3, 4, 5, 6, 7]).repeatText, '每天');
    expect(Alarm(id: 1, hour: 6, minute: 0, days: [1, 2, 3, 4, 5]).repeatText, '工作日');
    expect(Alarm(id: 1, hour: 6, minute: 0, days: [6, 7]).repeatText, '周末');
  });

  test('题库按数量抽取且不重复', () {
    final qs = pickQuestions(5);
    expect(qs.length, 5);
    expect(qs.map((e) => e.question).toSet().length, 5);
  });
}
