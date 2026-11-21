import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morning/profile.dart';
import 'package:morning/qbank.dart';
import 'package:morning/rank.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('morning/native'),
      (call) async => null,
    );
  });

  group('段位', () {
    test('门槛从小到大，最后一段落在题库尽头', () {
      for (var i = 1; i < kTiers.length; i++) {
        expect(kTiers[i].at > kTiers[i - 1].at, true,
            reason: '${kTiers[i].name} 的门槛没有比前一段高');
      }
      expect(kTiers.first.at, 0);
      expect(kTiers.last.at <= QBank.instance.total, true,
          reason: '最后一段的门槛不能超过题库总量，否则永远到不了');
    });

    test('边界：差一题就还是下一段', () {
      expect(Rank.tierIndex(0), 0);
      expect(Rank.tierIndex(29), 0);
      expect(Rank.tierIndex(30), 1);
      expect(Rank.tierIndex(99), 1);
      expect(Rank.tierIndex(100), 2);
      expect(Rank.tierIndex(99999), kTiers.length - 1);
    });

    test('段内进度与剩余题数自洽', () {
      final p = Rank.progress(65); // 30→100 区间，走了 35/70
      expect(p > 0.45 && p < 0.55, true, reason: '实际 $p');
      expect(Rank.toNext(65), 35);
      expect(Rank.progress(kTiers.last.at), 1.0);
      expect(Rank.toNext(kTiers.last.at), 0);
    });
  });

  group('对拼码', () {
    test('生成再解析，数字不变', () {
      final code = Rank.codeOf(answered: 128, streak: 7, correct: 96);
      // ignore: avoid_print
      print('对拼码：$code');
      final m = Rank.parseCode(code)!;
      expect(m['answered'], 128);
      expect(m['streak'], 7);
      expect(m['correct'], 96);
    });

    test('改一个数字就会被识破', () {
      final code = Rank.codeOf(answered: 128, streak: 7, correct: 96);
      final parts = code.split('-');
      parts[1] = '12800';
      expect(Rank.parseCode(parts.join('-')), isNull,
          reason: '手抖多打一个 0 不该被当成真的');
    });

    test('乱写的东西解析不出来，不会崩', () {
      expect(Rank.parseCode(''), isNull);
      expect(Rank.parseCode('随便一句'), isNull);
      expect(Rank.parseCode('CX1-1-2'), isNull);
      expect(Rank.parseCode('CX1-a-b-c-dd'), isNull);
    });

    test('答对数不会超过已答数（画像清空、日志还在时）', () {
      // 画像里只答过 1 道，日志里却留着很多历史 right——
      // 对拼码不能报出「答 1 道、对 17 道」这种自相矛盾的数。
      final c = Rank.correctOf();
      expect(c >= 0, true);
      expect(c <= Profile.load().answered.length, true);
    });
  });

  group('题数档位', () {
    test('最后一档是全部，标签不显示数字', () {
      expect(kQuizCounts.last, -1);
      expect(quizCountLabel(-1), '全部');
      expect(quizCountLabel(10), '10 道');
      // 前面的档位都该是正数，-1 只能出现在最后
      for (final c in kQuizCounts.take(kQuizCounts.length - 1)) {
        expect(c > 0, true);
      }
    });

    test('选「全部」真的把整个题库端出来', () {
      final p = Profile();
      final list = pickAdaptive(-1, p);
      expect(list.length, QBank.instance.total);
      // 一道不该重复
      expect(list.map((e) => e.id).toSet().length, list.length);
    });
  });
}
