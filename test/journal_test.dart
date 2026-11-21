import 'package:flutter_test/flutter_test.dart';
import 'package:morning/bank.dart';
import 'package:morning/core.dart';
import 'package:morning/journal.dart';

/// 日志层的纯逻辑测试。
///
/// 这一层没有渲染、没有原生依赖：落盘失败会被吞掉（见 Journal._persist），
/// 所以测试里不必给 MethodChannel 打桩。
void main() {
  setUp(() {
    Journal.events = [];
    Store.records = [];
  });

  group('写入与读取', () {
    test('记一条就能取回来，并按时间倒序', () {
      Journal.add(JKind.wake, '醒来', at: DateTime(2026, 11, 20, 7, 10));
      Journal.add(JKind.checkin, '出门打卡', at: DateTime(2026, 11, 20, 8, 5));

      final day = Journal.onDay('2026-11-20');
      expect(day.length, 2);
      expect(day.first.kind, JKind.checkin, reason: '新的应该在最上面');
      expect(day.first.hhmm, '08:05');
      expect(day.last.hhmm, '07:10');
    });

    test('不同日期不会混在一起', () {
      Journal.add(JKind.wake, 'A', at: DateTime(2026, 11, 19, 7, 0));
      Journal.add(JKind.wake, 'B', at: DateTime(2026, 11, 20, 7, 0));
      expect(Journal.onDay('2026-11-19').length, 1);
      expect(Journal.onDay('2026-11-20').single.title, 'B');
    });

    test('超过 120 天的事件在写入时被裁掉', () {
      Journal.add(JKind.wake, '很久以前',
          at: DateTime.now().subtract(const Duration(days: 200)));
      expect(Journal.events, isEmpty);
    });
  });

  group('当天统计', () {
    test('答题分对错，新闻分听到和只看到', () {
      final at = DateTime(2026, 11, 20, 7, 0);
      Journal.add(JKind.wake, '醒来', at: at);
      Journal.add(JKind.quiz, '题一', at: at, verdict: 'right');
      Journal.add(JKind.quiz, '题二', at: at, verdict: 'wrong');
      Journal.add(JKind.quiz, '偏好题', at: at);
      final n = Journal.add(JKind.news, '新闻一', at: at);
      Journal.add(JKind.news, '新闻二', at: at);

      final s = Journal.statOf('2026-11-20');
      expect(s.woke, isTrue);
      expect(s.quizTotal, 3);
      expect(s.quizCorrect, 1, reason: '偏好题不计入正确数');
      expect(s.news, 2);
      expect(s.newsSpoken, 0);

      Journal.markSpoken(n);
      expect(Journal.statOf('2026-11-20').newsSpoken, 1);
    });

    test('打卡只算一次', () {
      final at = DateTime(2026, 11, 20, 8, 0);
      Journal.add(JKind.checkin, '出门打卡', at: at);
      final s = Journal.statOf('2026-11-20');
      expect(s.checkedIn, isTrue);
      expect(s.doneCount, 1, reason: '只记了打卡，醒来和答题都没记');
    });

    test('没有流水的老日子用每日汇总兜底', () {
      // v1.3.0 及以前只留了汇总，升级后这些天不该凭空消失
      final rec = MorningRecord(
        date: '2026-11-01',
        alarmId: 1,
        wokeAt: DateTime(2026, 11, 1, 7).millisecondsSinceEpoch,
        quizCorrect: 2,
        quizTotal: 5,
        newsDone: true,
        photoPath: '/tmp/x.jpg',
        completed: true,
      );
      final s = Journal.statOf('2026-11-01', legacy: rec);
      expect(s.woke, isTrue);
      expect(s.quizTotal, 5);
      expect(s.quizCorrect, 2);
      expect(s.checkedIn, isTrue);
    });

    test('有流水时不采用兜底，避免重复计数', () {
      final at = DateTime(2026, 11, 2, 7, 0);
      Journal.add(JKind.quiz, '题', at: at, verdict: 'right');
      final rec = MorningRecord(
        date: '2026-11-02',
        alarmId: 1,
        wokeAt: at.millisecondsSinceEpoch,
        quizCorrect: 9,
        quizTotal: 10,
        completed: true,
      );
      final s = Journal.statOf('2026-11-02', legacy: rec);
      expect(s.quizTotal, 1, reason: '应以流水为准');
      expect(s.quizCorrect, 1);
    });
  });

  group('本月统计', () {
    test('跨天累计，且把老汇总算进来', () {
      Journal.add(JKind.quiz, '题', at: DateTime(2026, 11, 20, 7), verdict: 'right');
      Journal.add(JKind.quiz, '题', at: DateTime(2026, 11, 19, 7), verdict: 'wrong');
      Journal.add(JKind.wake, '醒来', at: DateTime(2026, 11, 19, 7));
      Journal.add(JKind.wake, '上个月的', at: DateTime(2026, 10, 31, 7));

      Store.records = [
        MorningRecord(
          date: '2026-11-05',
          alarmId: 1,
          wokeAt: DateTime(2026, 11, 5, 7).millisecondsSinceEpoch,
          quizCorrect: 3,
          quizTotal: 4,
          photoPath: '/tmp/a.jpg',
          completed: true,
        ),
      ];

      final m = Journal.statOfMonth(2026, 11);
      expect(m.quizTotal, 6, reason: '2 条流水 + 老汇总的 4 道');
      expect(m.quizCorrect, 4, reason: '1 + 3');
      expect(m.activeDays, 3, reason: '11-19、11-20 有流水，11-05 有汇总');
      expect(m.checkinDays, 1);
    });
    test('同一天既有流水又有旧汇总时不重复计数', () {
      // 真机上撞到过：答了 8 题，本月显示 11 道（8 条流水 + 当天旧汇总的 3 道）
      Journal.add(JKind.quiz, '题', at: DateTime(2026, 11, 20, 7), verdict: 'right');
      Store.records = [
        MorningRecord(
          date: '2026-11-20',
          alarmId: 1,
          wokeAt: DateTime(2026, 11, 20, 6).millisecondsSinceEpoch,
          quizCorrect: 1,
          quizTotal: 3,
          completed: true,
        ),
      ];

      final m = Journal.statOfMonth(2026, 11);
      expect(m.quizTotal, 1, reason: '有流水的日子不再采用旧汇总');
      expect(m.quizCorrect, 1);
      expect(m.activeDays, 1);
    });
  });

  group('音频键', () {
    test('前 20 条新闻各有唯一键，且与声明顺序一致', () {
      final keys = <String>{};
      for (var i = 0; i < kNewsWithSample && i < kNews.length; i++) {
        final k = newsSampleKey(kNews[i]);
        expect(k, 'n${(i + 1).toString().padLeft(2, '0')}');
        keys.add(k);
      }
      expect(keys.length, kNewsWithSample.clamp(0, kNews.length));
    });

    test('挑出来的新闻对象仍能拿到键（不是副本）', () {
      // pickNews 如果哪天改成返回深拷贝，音频就会静默对不上号：
      // 播出来还是人声，只是念的是别人那条。
      final picked = pickNews(Profile(), 3);
      expect(picked, isNotEmpty);
      for (final n in picked) {
        expect(newsSampleKey(n), isNotEmpty);
      }
    });
  });
}
