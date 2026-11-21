import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morning/core.dart';
import 'package:morning/profile.dart';
import 'package:morning/qbank.dart';
import 'package:morning/topics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 这一层是纯逻辑，原生通道打个桩让它吞掉即可
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('morning/native'),
      (call) async => null,
    );
  });

  setUp(() {
    Store.settings.clear();
  });

  test('题库规模与自检', () {
    final t = TopicTree.instance;
    final s = t.stats();
    final b = QBank.instance;

    // 打出来看，别只是断言
    // ignore: avoid_print
    print('事实卡 ${s['facts']} 张 / 节点 ${s['topics']} 个 / '
        '单选 ${s['single']} / 判断 ${s['judge']} / 多选 ${s['multi']} / '
        '实际生成 ${b.total}（含偏好 ${b.pref.length}）');

    expect(s['facts']! >= 400, true, reason: '事实卡太少');
    expect(b.total >= 3000, true, reason: '总题量不足三千，实际 ${b.total}');
    expect(auditQBank(), isEmpty);
  });

  test('树的结构：一级分支齐全，深度不超过四层', () {
    final t = TopicTree.instance;
    for (final root in kRootAxis.keys) {
      expect(t.nodes.containsKey(root), true, reason: '缺一级分支 $root');
    }
    var deep = 0;
    for (final n in t.nodes.values) {
      if (n.depth > deep) deep = n.depth;
    }
    expect(deep, 4);
  });

  test('三种题型都能抽到，且答案越界数为零', () {
    final kinds = <QKind>{};
    for (final q in QBank.instance.all) {
      kinds.add(q.kind);
      if (q.kind == QKind.multi) {
        expect(q.answers.length >= 2, true, reason: '多选题答案少于两条：${q.id}');
      }
      if (q.kind == QKind.judge) {
        expect(q.options.length, 2);
        expect(q.answers.length, 1);
      }
    }
    expect(kinds.contains(QKind.single), true);
    expect(kinds.contains(QKind.multi), true);
    expect(kinds.contains(QKind.judge), true);
    expect(kinds.contains(QKind.pref), true);
  });

  test('多选题：全对才算对，漏选算部分对', () {
    final q = QBank.instance.all.firstWhere((e) => e.kind == QKind.multi);
    expect(gradeOf(q, {...q.answers}).correct, true);

    final missing = q.answers.toList()..removeLast();
    final g = gradeOf(q, {...missing});
    expect(g.correct, false);
    expect(g.partial, true, reason: '漏选应该记为部分对，画像照样记');

    final extra = {...q.answers, 99}.where((e) => e < q.options.length).toSet();
    if (extra.length > q.answers.length) {
      expect(gradeOf(q, extra).correct, false, reason: '多选了错误项不能算对');
    }
  });

  test('抽十道：题型混合，且第一题是偏好题', () {
    final p = Profile();
    final list = pickAdaptive(10, p, rng: math.Random(7));
    expect(list.length, 10);
    expect(list.first.kind, QKind.pref);

    final kinds = list.map((e) => e.kind).toSet();
    expect(kinds.length >= 3, true, reason: '题型太单一：$kinds');

    // 同一节点不该在一轮里刷屏
    final perTopic = <String, int>{};
    for (final q in list) {
      if (q.topicId.isEmpty) continue;
      perTopic[q.topicId] = (perTopic[q.topicId] ?? 0) + 1;
    }
    for (final e in perTopic.entries) {
      expect(e.value <= 4, true, reason: '${e.key} 一轮出了 ${e.value} 道');
    }
  });

  test('答得越多，越往那条路的下钻', () {
    final p = Profile();
    // 先把「制造业/数控加工/数控车工」答三次
    const node = '职业/制造业/数控加工/数控车工';
    for (var i = 0; i < 3; i++) {
      p.recordAnswer(id: 'x$i', topicId: node, axis: '社会', credit: 1);
    }

    final order = TopicTree.instance.drillOrder(
      hits: p.topicHits,
      skips: p.topicSkips,
      rng: math.Random(1),
    );
    final idxSelf = order.indexOf(node);
    expect(idxSelf < 20, true, reason: '走过三次的路应该还在前排');

    final c = p.topicConfidence(node);
    expect(c > 0.7, true, reason: '答三次应该够清楚了，实际 $c');
    expect(p.drillDepth, 4);
  });

  test('父节点问得多，子节点跟着热——这才是往下钻', () {
    final p = Profile();
    for (var i = 0; i < 5; i++) {
      p.recordAnswer(id: 'p$i', topicId: '生活/吃', axis: '生活', credit: 1);
    }
    final order = TopicTree.instance.drillOrder(
      hits: p.topicHits,
      skips: p.topicSkips,
      rng: math.Random(3),
    );
    // 「吃」这一支下的子节点，应该排在一条完全没碰过的分支前面
    final child = order.indexOf('生活/吃/做饭');
    final stranger = order.indexOf('钱/借贷/房贷');
    expect(child >= 0 && stranger >= 0, true);
    expect(child < stranger, true,
        reason: '父节点答了五次，子节点应该比陌生分支靠前');
  });

  test('跳过算「这块不关心」，跳多了降权但不清零', () {
    final p = Profile();
    const node = '爱好/钓/台钓';
    for (var i = 0; i < 3; i++) {
      p.recordSkip(node);
    }
    expect(p.topicSkips[node], 3);

    final order = TopicTree.instance.drillOrder(
      hits: p.topicHits,
      skips: p.topicSkips,
      rng: math.Random(2),
    );
    final idx = order.indexOf(node);
    final untouched = order.indexOf('职业/数控加工/数控车工');
    expect(idx > untouched, true, reason: '跳过的分支应该排到没碰过的后面');
    expect(idx >= 0, true, reason: '降权不等于删除，还在队里');
  });

  test('跳过不写进 answered，但要排到队尾', () {
    final p = Profile();
    p.recordSkip('生活/吃/做饭', id: 'q123-a');
    expect(p.answered, isEmpty, reason: '跳过不算答过');
    expect(p.skippedItems['q123-a'], 1, reason: '要记下来，免得下一轮立刻重问');
  });

  test('画像能取存，且旧数据不丢', () async {
    final p = Profile();
    p.recordAnswer(id: 'a1', topicId: '职业/焊接/氩弧焊', axis: '社会', credit: 1);
    p.recordAnswer(id: 'a2', topicId: '职业/焊接/氩弧焊', axis: '社会', credit: 0.35);
    p.recordSkip('军事/装备/航母');
    await p.save();

    final back = Profile.load();
    expect(back.topicHits['职业/焊接/氩弧焊'], 2);
    expect(back.topicScore['职业/焊接/氩弧焊']! > 1.3, true);
    expect(back.topicSkips['军事/装备/航母'], 1);
    expect(back.answered.contains('a1'), true);
  });

  test('看清了哪几条路：只列答过两次以上的', () {
    final p = Profile();
    p.recordAnswer(id: 'b1', topicId: '工具/家电/冰箱', axis: '科技', credit: 1);
    expect(p.clearestTopics(5), isEmpty, reason: '只答一次不该下结论');

    p.recordAnswer(id: 'b2', topicId: '工具/家电/冰箱', axis: '科技', credit: 1);
    p.recordAnswer(id: 'b3', topicId: '钱/借贷/房贷', axis: '财经', credit: 1);
    p.recordAnswer(id: 'b4', topicId: '钱/借贷/房贷', axis: '财经', credit: 1);

    final list = p.clearestTopics(5);
    expect(list.length, 2);
    expect(list.first.label.contains('·'), true);
  });

  test('偏好题没有对错，但仍喂十维', () {
    final pref = QBank.instance.pref.first;
    expect(gradeOf(pref, {0}).correct, null);

    final p = Profile();
    p.recordPref(pref.id, pref.weights[0]);
    expect(p.hits.values.any((e) => e > 0), true);
    expect(p.topicHits, isEmpty, reason: '偏好题不挂主题节点');
  });

  test('新人第一轮：题要铺开，先摸大方向', () {
    final p = Profile();
    final list = pickAdaptive(10, p, rng: math.Random(11));
    final roots = <String>{};
    for (final q in list) {
      if (q.topicId.isEmpty) continue;
      roots.add(q.topicId.split('/').first);
    }
    // ignore: avoid_print
    print('新人第一轮覆盖的一级分支：${roots.length} 条 $roots');
    expect(roots.length >= 8, true,
        reason: '注册当天只答得完二三十道，前十道必须是大方向，不能一头钻进某个工种');
  });

  test('铺完轮廓就收敛：三十题之后同一条路会再被问到', () {
    final p = Profile();
    // 跨轮会有重复题，所以多答一轮，凑够三十道有效样本
    for (var round = 0; round < 4; round++) {
      final list = pickAdaptive(10, p, rng: math.Random(100 + round));
      for (final q in list) {
        if (q.topicId.isEmpty) {
          if (q.weights.isNotEmpty) p.recordPref(q.id, q.weights.first);
        } else {
          p.recordAnswer(id: q.id, topicId: q.topicId, axis: q.axis, credit: 1);
        }
      }
    }
    expect(p.answered.length >= 30, true,
        reason: '先得答满广度配额，实际 ${p.answered.length}');

    final after = pickAdaptive(10, p, rng: math.Random(7));
    final byTopic = <String, int>{};
    for (final q in after) {
      if (q.topicId.isEmpty) continue;
      byTopic[q.topicId] = (byTopic[q.topicId] ?? 0) + 1;
    }
    // ignore: avoid_print
    print('三十题后的一轮分布：$byTopic');
    expect(byTopic.length <= 6, true, reason: '轮廓铺完了就该集中，一直散着攒不出纹理');
    expect(byTopic.values.any((e) => e >= 2), true,
        reason: '同一条路要被问到第二次，纹理才攒得起来');
  });

  test('连答八轮：越走越深', () {
    final p = Profile();
    for (var round = 0; round < 8; round++) {
      final list = pickAdaptive(10, p, rng: math.Random(100 + round));
      for (final q in list) {
        if (q.topicId.isEmpty) {
          if (q.weights.isNotEmpty) p.recordPref(q.id, q.weights.first);
        } else {
          p.recordAnswer(id: q.id, topicId: q.topicId, axis: q.axis, credit: 1);
        }
      }
    }
    final clear = p.clearestTopics(10);
    // ignore: avoid_print
    print('八轮后看清的路：${clear.map((e) => '${e.label}(${e.hits})').toList()}');
    expect(clear.length >= 3, true, reason: '八轮下来至少该有三条路看清了');
    expect(p.drillDepth >= 3, true, reason: '前三十题铺轮廓，之后就该往下钻了');
  });

  test('答穿以后不会没题', () {
    final p = Profile();
    for (final q in QBank.instance.all) {
      p.answered.add(q.id);
    }
    final list = pickAdaptive(12, p, rng: math.Random(9));
    expect(list.length, 12);
  });
}
