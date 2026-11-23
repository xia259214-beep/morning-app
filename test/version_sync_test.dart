import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:morning/core.dart';

/// 版本号有三个来源：pubspec.yaml、编译期常量 kAppVersion、原生 versionName。
/// 前两个必须一致——不一致的时候崩溃日志会写着旧版本，排查等于白干
/// （v1.15.0 时 kAppVersion 还停在 1.12.1，就是这条测试要防的事）。
void main() {
  test('kAppVersion 与 pubspec.yaml 的 version 一致', () {
    final pub = File('pubspec.yaml').readAsStringSync();
    final m = RegExp(r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+(\d+)',
            multiLine: true)
        .firstMatch(pub);
    expect(m, isNotNull, reason: 'pubspec.yaml 里找不到 version: x.y.z+n');
    expect(kAppVersion, m!.group(1),
        reason: '改了 pubspec 版本号却没改 lib/core.dart 的 kAppVersion');
    expect(int.parse(m.group(2)!), greaterThan(0),
        reason: 'versionCode 必须递增');
  });
}
