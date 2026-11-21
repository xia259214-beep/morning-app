import 'package:flutter_test/flutter_test.dart';
import 'package:morning/bank.dart';
import 'package:morning/core.dart';

/// 题库与画像的纯逻辑测试，不依赖 Flutter 渲染和原生通道。
void main() {
  group('题库体检', () {
    test('id 不重复、答案合法、选项至少两个', () {
      final issues = auditBank();
      expect(issues, isEmpty, reason: '题库有问题：${issues.join(', ')}');
    });

    test('题量符合 V2 规划（≥300 道）', () {
      expect(kBank.length, greaterThanOrEqualTo(300));
      expect(kBankKnowCount, greaterThanOrEqualTo(200));
      expect(kBankPrefCount, greaterThanOrEqualTo(100));
    });

    test('每道题挂的维度都在十维之内', () {
      for (final q in kBank) {
        if (q is KnowledgeItem) {
          expect(q.axes, isNotEmpty, reason: '${q.id} 没有归属维度');
          for (final a in q.axes) {
            expect(kAxes.contains(a), true, reason: '${q.id} 用了未知维度 $a');
          }
        } else if (q is PrefItem) {
          expect(q.weights.length, q.opts.length, reason: '${q.id} 选项与权重数量不一致');
          for (final w in q.weights) {
            expect(w, isNotEmpty, reason: '${q.id} 有选项没挂权重');
            for (final a in w.keys) {
              expect(kAxes.contains(a), true, reason: '${q.id} 用了未知维度 $a');
            }
          }
        }
      }
    });

    test('知识题的解释不为空——答错要有得看', () {
      for (final q in kKnowBank) {
        expect(q.explain.trim(), isNotEmpty, reason: '${q.id} 缺少解释');
      }
    });
  });

  group('抽题', () {
    test('按要求的数量出题', () {
      final p = Profile();
      for (final n in [3, 8, 12, 16]) {
        expect(pickMixed(n, p).length, n, reason: '要求 $n 道');
      }
    });

    test('第一题一定是偏好题——刚醒来不适合先算数', () {
      for (var i = 0; i < 20; i++) {
        final q = pickMixed(8, Profile());
        expect(q.first.isKnowledge, false, reason: '第 ${i + 1} 次抽题首题是知识题');
      }
    });

    test('同一轮里不出现重复题', () {
      final q = pickMixed(16, Profile());
      expect(q.map((e) => e.id).toSet().length, q.length);
    });

    test('选项顺序被打乱，但「正确答案」仍然指向原来那句话', () {
      // 位置偏好会污染画像：不打乱的话，习惯性选 A 的用户会被判成
      // 「只关心选项 A 常挂的那几个维度」。这里验证打乱后答案没跑偏。
      for (var round = 0; round < 30; round++) {
        final drawn = pickMixed(16, Profile());
        for (final q in drawn) {
          if (q is! KnowledgeItem) continue;
          final source = kKnowBank.firstWhere((e) => e.id == q.id);
          // 选项内容集合不变
          expect(q.options.toSet(), source.options.toSet(), reason: '${q.id} 选项被改坏了');
          // 正确答案指向的文本与原题一致
          expect(q.options[q.answer], source.options[source.answer],
              reason: '${q.id} 打乱后答案错位');
        }
      }
    });

    test('偏好题的权重跟着选项一起搬家', () {
      for (var round = 0; round < 20; round++) {
        final drawn = pickMixed(16, Profile());
        for (final q in drawn) {
          if (q is! PrefItem) continue;
          final source = kPrefBank.firstWhere((e) => e.id == q.id);
          for (var i = 0; i < q.opts.length; i++) {
            final srcIdx = source.opts.indexOf(q.opts[i]);
            expect(srcIdx, greaterThanOrEqualTo(0), reason: '${q.id} 选项文本对不上');
            expect(q.weights[i], source.weights[srcIdx],
                reason: '${q.id} 的「${q.opts[i]}」权重没跟着走');
          }
        }
      }
    });

    test('已答过的题会被排到后面', () {
      // 先造一份「知识题全答过」的画像，抽 8 道仍应尽量给没答过的
      final p = Profile();
      for (final k in kKnowBank) {
        p.answered.add(k.id);
      }
      final q = pickMixed(8, p);
      final seen = q.where((e) => e.isKnowledge && p.answered.contains(e.id)).length;
      // 知识题池已耗尽，允许回落到旧题，但不应该是「优先挑旧题」
      expect(seen, lessThanOrEqualTo(3));
    });
  });

  group('新闻按画像排序', () {
    test('关心科技的人，播报里科技排前面', () {
      final p = Profile();
      // 把科技答到有足够置信度
      for (var i = 0; i < 4; i++) {
        // p098 选项 0「先研究原理再说」挂的是科技
        p.apply(kPrefBank.firstWhere((e) => e.id == 'p098'), 0);
      }
      final news = pickNews(p, 3);
      expect(news.first.topic, '科技');
    });

    test('一次播报里不重复同一个维度', () {
      final p = Profile();
      for (var round = 0; round < 10; round++) {
        final news = pickNews(p, 3);
        expect(news.length, 3);
        expect(news.map((e) => e.topic).toSet().length, 3);
      }
    });

    test('画像是空的时候也能正常出三条', () {
      final news = pickNews(Profile(), 3);
      expect(news.length, 3);
    });

    test('新闻库覆盖全部十个维度', () {
      final topics = kNews.map((e) => e.topic).toSet();
      for (final a in kAxes) {
        expect(topics.contains(a), true, reason: '缺少「$a」方向的内容');
      }
    });
  });

  group('画像累积', () {
    test('答题只会让对应维度增加，不串味', () {
      final p = Profile();
      final item = kPrefBank.firstWhere((e) => e.id == 'p001'); // 选项 A = 财经
      p.apply(item, 0);
      expect(p.score['财经'], greaterThan(0));
      expect(p.hits['财经'], 1);
      expect(p.score['体育'], 0);
    });

    test('答对给满权重，答错给三成', () {
      final k = kKnowBank.first; // k001，答案下标 2
      final right = Profile()..apply(k, k.answer);
      final wrong = Profile()..apply(k, 0);
      expect(right.score['科技']! > wrong.score['科技']!, true);
      expect(wrong.score['科技']! > 0, true, reason: '答错也说明接触过这个领域');
    });

    test('置信度随次数上升，但不会到 1', () {
      final p = Profile();
      double last = 0;
      for (var i = 0; i < 30; i++) {
        p.apply(kPrefBank.firstWhere((e) => e.id == 'p001'), 0);
        final c = p.confidenceOf('财经');
        expect(c, greaterThanOrEqualTo(last));
        expect(c, lessThan(1));
        last = c;
      }
      expect(last, greaterThan(0.95));
    });

    test('样本不足时说的是「看不清」，不硬编结论', () {
      final p = Profile();
      expect(p.describe().contains('看不清'), true);
      expect(p.clarity, 0);
    });

    test('看不清的维度就是 hits 最少的那个', () {
      final p = Profile();
      for (var i = 0; i < 5; i++) {
        p.apply(kPrefBank.firstWhere((e) => e.id == 'p001'), 0); // 财经
      }
      expect(p.vaguestAxis() == '财经', false);
    });
  });
}
