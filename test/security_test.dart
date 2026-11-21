import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morning/bank.dart';
import 'package:morning/core.dart';
import 'package:morning/journal.dart';

// ============================================================================
// 安全与容错测试
//
// 这里测的不是「功能对不对」，而是「坏输入进来会怎样」：
//   · 落盘数据被写坏（断电、磁盘满、跨版本字段变更）
//   · 外部传入的路径 / 名称不合法
//   · 随机化路径长时间跑会不会出界
//
// 这类问题平时看不出来，一旦触发都是「用户数据没了」或「应用起不来」。
// ============================================================================

const _channel = MethodChannel('morning/native');

/// 打桩原生通道，用内存 Map 冒充 SharedPreferences
void _mockPrefs(Map<String, String?> store) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
    final args = call.arguments is Map ? call.arguments as Map : const {};
    switch (call.method) {
      case 'getPref':
        return store[args['key'] as String?];
      case 'setPref':
        store[args['key'] as String? ?? ''] = args['value'] as String?;
        return true;
      case 'syncAlarms':
        return true;
      default:
        return null;
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, String?> prefs;

  setUp(() {
    prefs = {};
    _mockPrefs(prefs);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    Journal.events = [];
    Store.alarms = [];
    Store.records = [];
    Store.settings = {};
  });

  group('落盘数据损坏时不能连坐', () {
    test('日志整体不是 JSON：清空但不抛', () async {
      prefs['journal'] = '{这不是 json';
      await Journal.load();
      expect(Journal.events, isEmpty);
    });

    test('日志里混入坏条目：好的必须留下', () async {
      prefs['journal'] = jsonEncode([
        {'t': 1000, 'k': 'w', 'i': '醒来'},
        'not a map', // 类型都不对
        {'t': 2000, 'k': 'q', 'i': '答题', 'v': 'right'},
        {'t': 'oops', 'k': 123, 'i': 456}, // 字段类型错位
      ]);
      await Journal.load();
      // 字符串那条被丢弃，其余三条按新到旧排列
      expect(Journal.events.length, 3);
      expect(Journal.events.first.ts, 2000);
      expect(Journal.events.first.title, '答题');
      // 类型错位的字段要退化到默认值，而不是让整条消失
      expect(Journal.events.last.ts, 0);
      expect(Journal.events.last.title, '456');
    });

    test('日志时间戳是字符串时按数字解析', () async {
      prefs['journal'] = jsonEncode([
        {'t': '1700000000000', 'k': 'c', 'i': '打卡'},
      ]);
      await Journal.load();
      expect(Journal.events.single.ts, 1700000000000);
    });

    test('闹钟 JSON 解析失败时，不覆盖原数据、也不写默认闹钟', () async {
      const broken = '[{"id":"不是数字"}]';
      prefs['alarms'] = broken;
      await Store.load();
      expect(Store.alarms, isEmpty);
      // 关键断言：原字符串必须原样保留。
      // 覆盖掉的后果是用户所有闹钟静默消失，次日不会被叫醒。
      expect(prefs['alarms'], broken);
    });

    test('闹钟里部分条目坏掉时，好的仍能读出来', () async {
      prefs['alarms'] = jsonEncode([
        {'id': 1, 'hour': 7, 'minute': 15, 'label': '上班', 'days': [1], 'snooze': 9},
        {'id': 'bad'}, // Alarm.fromJson 会在 toInt 处抛
        {'id': 3, 'hour': 9, 'minute': 0, 'label': '周末', 'days': [6, 7]},
      ]);
      await Store.load();
      expect(Store.alarms.map((e) => e.id), [1, 3]);
      expect(Store.alarms.first.snoozeMinutes, 9);
    });

    test('用户删光闹钟后重启，不会被强塞一个默认闹钟', () async {
      prefs['alarms'] = '[]';
      await Store.load();
      // 只有「从来没写过」才补默认。写空数组是用户的明确决定，要尊重。
      expect(Store.alarms, isEmpty);
    });

    test('从未写过闹钟时才补默认值', () async {
      expect(prefs.containsKey('alarms'), isFalse);
      await Store.load();
      expect(Store.alarms.length, 1);
      expect(Store.alarms.single.id, 1);
    });
  });

  group('音频键必须是固定形态', () {
    test('预生成的 20 条全部匹配 n\\d\\d', () {
      for (final n in kNews.take(kNewsWithSample)) {
        final key = newsSampleKey(n);
        expect(RegExp(r'^n\d{2}$').hasMatch(key), isTrue,
            reason: '键「$key」不合法，原生侧会拒绝播放并退回系统音色');
      }
    });

    test('不在内置列表里的新闻返回空键，调用方应跳过播放', () {
      const stranger = NewsItem('外部新闻源的一条', '摘要', '来源', '科技', '科技');
      expect(newsSampleKey(stranger), '');
    });

    test('同一对象多次取键结果稳定', () {
      final n = kNews[3];
      expect(newsSampleKey(n), newsSampleKey(n));
    });
  });

  group('随机化路径不出界', () {
    test('连续抽题 1000 次：不重复、答案下标合法', () {
      final p = Profile();
      for (var round = 0; round < 1000; round++) {
        final qs = pickMixed(10, p);
        expect(qs.length, 10);
        final ids = qs.map((e) => e.id).toSet();
        expect(ids.length, 10, reason: '同一轮出现了重复题');
        for (final q in qs) {
          expect(q.options, isNotEmpty);
          expect(q.answer, greaterThanOrEqualTo(-1));
          expect(q.answer, lessThan(q.options.length));
          for (var i = 0; i < q.options.length; i++) {
            // 权重表里不该出现未定义的维度，否则画像会静默丢分
            final w = q.weightOf(i);
            for (final k in w.keys) {
              expect(kAxes.contains(k), isTrue, reason: '未知维度 $k');
            }
          }
        }
      }
    });

    test('题库自检：id 唯一、题干非空、选项至少两个', () {
      final all = [...kKnowBank, ...kPrefBank];
      expect(all.map((e) => e.id).toSet().length, all.length);
      for (final q in all) {
        expect(q.question.trim(), isNotEmpty);
        expect(q.options.length, greaterThanOrEqualTo(2));
        expect(q.options.where((o) => o.trim().isEmpty), isEmpty);
      }
    });

    test('画像累积 3000 次：分数不越界、不产生 NaN', () {
      final p = Profile();
      final all = [...kKnowBank, ...kPrefBank];
      for (var i = 0; i < 3000; i++) {
        final q = all[i % all.length];
        p.apply(q, [0, 1, 2, 3][i % 4] % q.options.length);
      }
      for (final a in kAxes) {
        final v = p.score[a] ?? 0;
        expect(v.isNaN, isFalse);
        expect(v.isFinite, isTrue);
        expect(v, greaterThanOrEqualTo(0));
      }
      // 置信度是 0..1 的比例，越界会让进度条画出屏幕
      for (final a in kAxes) {
        final c = p.confidenceOf(a);
        expect(c, inInclusiveRange(0.0, 1.0));
      }
    });
  });
}
