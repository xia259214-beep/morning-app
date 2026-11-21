import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morning/focus.dart';
import 'package:morning/profile.dart';
import 'package:morning/qbank.dart';
import 'package:morning/topics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('morning/native'),
      (call) async => null,
    );
  });

  group('四门轮值', () {
    test('四门覆盖题库全部十三个一级分支，不重复也不遗漏', () {
      final all = <String>{};
      for (final a in kFocusAreas) {
        for (final r in a.roots) {
          expect(all.add(r), true, reason: '$r 被归进了两门');
        }
      }
      final expected = TopicTree.instance.roots.toSet();
      expect(all, expected, reason: '有分支没归进任何一门，那天就永远问不到它');
    });

    test('每门都有足够题，不会某天没题答', () {
      for (final a in kFocusAreas) {
        final n = QBank.instance.all
            .where((q) => q.topicId.isNotEmpty &&
                a.roots.contains(q.topicId.split('/').first))
            .length;
        // ignore: avoid_print
        print('${a.name}: $n 道');
        expect(n >= 100, true, reason: '${a.name} 只有 $n 道，撑不起一轮');
      }
    });

    test('四天一轮，连续的四天刚好各开一门', () {
      final start = DateTime(2026, 11, 21);
      final seen = <String>[];
      for (var i = 0; i < 4; i++) {
        seen.add(DailyFocus.of(start.add(Duration(days: i))).id);
      }
      expect(seen.toSet().length, 4, reason: '四天里应当四门各开一次');
      expect(DailyFocus.of(start).id, DailyFocus.of(start.add(const Duration(days: 4))).id,
          reason: '第五天应当回到第一门');
    });

    test('同一天内换的时刻，门不变；跨零点才换', () {
      final d = DateTime(2026, 11, 21);
      expect(DailyFocus.of(DateTime(d.year, d.month, d.day, 5, 1)).id,
          DailyFocus.of(DateTime(d.year, d.month, d.day, 23, 59)).id);
    });

    test('daysUntil：今天 0，其余 1~3，且开放日确实开这门', () {
      final now = DateTime(2026, 11, 21, 9);
      final today = DailyFocus.of(now);
      for (final a in kFocusAreas) {
        final d = DailyFocus.daysUntil(a, now: now);
        if (a.id == today.id) {
          expect(d, 0);
        } else {
          expect(d >= 1 && d <= 3, true);
        }
        expect(DailyFocus.of(now.add(Duration(days: d))).id, a.id,
            reason: '${a.name} 说好第 $d 天开放');
      }
    });

    test('置灰说明写明哪天开放', () {
      final now = DateTime(2026, 11, 21, 9);
      final today = DailyFocus.of(now);
      expect(DailyFocus.openHint(today, now: now), '今天开放');
      final other = kFocusAreas.firstWhere((e) => e.id != today.id);
      final hint = DailyFocus.openHint(other, now: now);
      expect(hint.contains('开放'), true);
      // ignore: avoid_print
      print('${other.name}: $hint');
    });
  });

  group('门控确实只放今天这一门', () {
    test('只问生活时，不带生活门以外的一级分支', () {
      final area = kFocusAreas.firstWhere((e) => e.id == 'life');
      final list = pickAdaptive(20, Profile(), onlyRoots: area.rootSet);
      expect(list.isNotEmpty, true);
      for (final q in list) {
        if (q.topicId.isEmpty) continue; // 偏好题不挂分支，是暖场
        expect(area.roots.contains(q.topicId.split('/').first), true,
            reason: '混进了别的门：${q.topicId}');
      }
    });

    test('四门各自抽到的题互不重叠', () {
      final seenByArea = <String, Set<String>>{};
      for (final a in kFocusAreas) {
        final list = pickAdaptive(20, Profile(), onlyRoots: a.rootSet);
        seenByArea[a.id] = list.where((e) => e.topicId.isNotEmpty).map((e) => e.id).toSet();
      }
      final ids = kFocusAreas.map((e) => e.id).toList();
      for (var i = 0; i < ids.length; i++) {
        for (var j = i + 1; j < ids.length; j++) {
          expect(seenByArea[ids[i]]!.intersection(seenByArea[ids[j]]!).isEmpty, true,
              reason: '${ids[i]} 和 ${ids[j]} 出了同一道题');
        }
      }
    });

    test('选「全部」档时四门全开，不受今日之门限制', () {
      final area = kFocusAreas.firstWhere((e) => e.id == 'life');
      final list = pickAdaptive(-1, Profile(), onlyRoots: area.rootSet);
      expect(list.length, QBank.instance.total,
          reason: '全部档应当还是整个题库，不能被门控截短');
    });
  });
}
