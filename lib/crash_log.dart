/// v1.11.0 本地崩溃日志（零依赖）。
///
/// 目标：App 崩了至少「有人知道」——堆栈自动落盘，问题可复现、可排查。
/// 这是接腾讯 Bugly 之前的兜底方案，也与其互补：云端监控断了、没网了，
/// 本地这份永远在。接入 Bugly 时（TODO：拿 AppID/AppKey 后）保留本模块
/// 作为离线兜底，初始化点就在 [installCrashLog]。
library;

import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show FlutterError;

import 'core.dart' show Bridge;

/// 上一条崩溃的格式化文本（测试与排查用）。
String lastCrashText = '';

/// 把一次崩溃格式化成一段可读的日志文本。
///
/// [source] 标记崩溃来源（flutter / platform），[version] 是 App 版本号，
/// 都是为了排查时不用猜「这是哪个版本、哪一侧炸的」。
/// 纯函数，便于单测。
String formatCrash(String source, Object error, StackTrace? stack,
    {String version = '', DateTime? now}) {
  final t = now ?? DateTime.now();
  final ts = t.toIso8601String();
  final buf = StringBuffer()
    ..writeln('=== CRASH $source @ $ts (v$version) ===')
    ..writeln(error.toString());
  final st = stack?.toString() ?? '';
  if (st.isNotEmpty) {
    // 堆栈可能很长，只留前 40 行，够定位且不把 64KB 配额吃光
    final lines = st.split('\n');
    buf
      ..writeln('--- stack ---')
      ..writeln(lines.take(40).join('\n'));
  }
  buf.writeln();
  return buf.toString();
}

/// 安装全局崩溃捕获。在 main() 里 runApp 之前调用一次。
///
/// 三层兜底：
/// 1. [FlutterError.onError] —— Flutter 框架内的错误（构建/布局/绘制）
/// 2. [PlatformDispatcher.instance.onError] —— 平台调度层的未捕获异常
/// 3. runZonedGuarded 由调用方按需包一层（main.dart 已包）
/// 写盘失败绝不二次抛出——崩溃处理器自己不能再崩。
void installCrashLog({String version = ''}) {
  void writeCrash(String source, Object error, StackTrace? stack) {
    try {
      lastCrashText = formatCrash(source, error, stack, version: version);
      Bridge.writeCrashLog(lastCrashText);
    } catch (_) {
      // 崩溃处理器里禁止再抛
    }
  }

  final prevFlutter = FlutterError.onError;
  FlutterError.onError = (details) {
    writeCrash('flutter', details.exception, details.stack);
    prevFlutter?.call(details);
  };

  final prevPlatform = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    writeCrash('platform', error, stack);
    return prevPlatform?.call(error, stack) ?? false;
  };
}
