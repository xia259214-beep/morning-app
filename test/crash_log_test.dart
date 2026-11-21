// v1.11.0 本地崩溃日志测试：纯函数行为 + 安装钩子的健壮性
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morning/crash_log.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('formatCrash', () {
    final fixed = DateTime.parse('2026-11-22T01:30:00');

    test('包含来源、时间戳、版本与错误信息', () {
      final out = formatCrash('flutter', StateError('bad state'), null,
          version: '1.11.0', now: fixed);
      expect(out, contains('=== CRASH flutter @ 2026-11-22T01:30:00'));
      expect(out, contains('(v1.11.0)'));
      expect(out, contains('bad state'));
    });

    test('带堆栈时截断到前 40 行，防止单条日志撑爆配额', () {
      final big = StackTrace.current;
      final many = StackTrace.fromString(
          List.generate(120, (i) => '#$i  fake.dart:1:1').join('\n'));
      final out = formatCrash('platform', Exception('x'), many,
          now: fixed);
      // 输出里 fake.dart 行数不超过 40
      final n = out.split('\n').where((l) => l.contains('fake.dart')).length;
      expect(n, lessThanOrEqualTo(40));
      expect(big.toString(), isNotEmpty); // 顺带确认正常堆栈可读
    });

    test('空堆栈不输出 stack 段，也不炸', () {
      final out = formatCrash('flutter', 'oops', null, now: fixed);
      expect(out.contains('--- stack ---'), false);
    });

    test('lastCrashText 初始为空串（可安全展示）', () {
      expect(lastCrashText, '');
    });
  });

  group('installCrashLog', () {
    testWidgets('安装后 FlutterError.onError 与 Platform onError 均被接管',
        (tester) async {
      // 先清空框架自带的处理器，避免链式调用把测试异常上报导致误判失败
      final beforeFlutter = FlutterError.onError;
      final beforePlatform = PlatformDispatcher.instance.onError;
      FlutterError.onError = null;
      PlatformDispatcher.instance.onError = null;
      addTearDown(() {
        FlutterError.onError = beforeFlutter;
        PlatformDispatcher.instance.onError = beforePlatform;
      });
      installCrashLog(version: 'test');
      // 接管器应当吞掉异常而不是向外抛（写盘在测试环境会走 MissingPlugin 分支）
      try {
        FlutterError.onError!(FlutterErrorDetails(exception: Exception('t')));
      } catch (e) {
        fail('崩溃处理器不应抛出: $e');
      }
      try {
        PlatformDispatcher.instance.onError!(Exception('t'), StackTrace.current);
      } catch (e) {
        fail('平台崩溃处理器不应抛出: $e');
      }
      // 格式化产物应已记录到 lastCrashText
      expect(lastCrashText, contains('(vtest)'));
    });
  });
}
