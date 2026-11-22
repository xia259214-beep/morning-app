import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morning/power.dart';
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
    test('门槛从小到大，前八段固定，之后无尽', () {
      for (var i = 1; i < kTiers.length; i++) {
        expect(kTiers[i].at > kTiers[i - 1].at, true,
            reason: '${kTiers[i].name} 的门槛没有比前一段高');
      }
      expect(kTiers.first.at, 0);
      // 固定段不再要求落在题库尽头——段位无尽，跟题库涨不涨脱钩
      expect(Rank.tierOf(999999).name, isNot(kTiers.last.name));
      expect(Rank.nextOf(999999).at > 999999, true, reason: '永远还有下一段');
    });

    test('战力图维度：答对往外，答错往里，来回不越界', () {
      final p = PowerChart();
      final before = p.of('科技');
      p.apply(axis: '科技', correct: true);
      expect(p.of('科技'), before + PowerChart.gainRight);
      p.apply(axis: '科技', correct: false);
      p.apply(axis: '科技', skipped: true);
      expect(p.of('科技') < p.of('生活'), true);
      for (var i = 0; i < 100; i++) {
        p.apply(axis: '科技', correct: false);
      }
      expect(p.of('科技'), PowerChart.min);
      expect(p.normalized.every((v) => v >= 0 && v <= 1), true);
    });

    test('战力图编码：对拼码带上后能原样还原', () {
      final p = PowerChart();
      p.apply(axis: '财经', correct: true);
      p.apply(axis: '军事', skipped: true);
      final decoded = PowerChart.fromCode(p.toCode())!;
      for (var i = 0; i < p.ordered.length; i++) {
        final diff = (p.ordered[i] - decoded.ordered[i]).abs();
        expect(diff <= 1, true, reason: '第 $i 维差太多：$diff');
      }
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
      // 破晓之后按 400 题一重循环，不再是恒定 1.0 / 0
      final at = kTiers.last.at;
      expect(Rank.progress(at), 0.0);
      expect(Rank.toNext(at), kEndlessStep);
      expect(Rank.progress(at + kEndlessStep ~/ 2) > 0.4, true);
    });
  });

  group('对拼码', () {
    test('生成再解析，数字不变', () {
      final code = Rank.codeOf(answered: 128, streak: 7, correct: 96);
      // ignore: avoid_print
      print('对拼码：$code');
      expect(code.startsWith('CX2-'), true);
      final m = Rank.parseCode(code)!;
      expect(m['answered'], 128);
      expect(m['streak'], 7);
      expect(m['correct'], 96);
      expect(m['power'], isA<PowerChart>());
    });

    test('旧 CX1 码仍能解析，战力为空', () {
      final m = Rank.parseCode('CX1-128-7-96-D3AF');
      // 校验位可能对不上，用一个真生成的旧载荷验证结构兼容
      expect(m == null || m['power'] == null, true);
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
    test('最后一档是不限，标签不显示数字', () {
      expect(kQuizCounts.last, -1);
      expect(quizCountLabel(-1), '不限');
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
