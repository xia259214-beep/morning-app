# Bugly 接入指南（30 分钟完工版）

> 状态：等待用户提供 AppID / AppKey。本文档写于 2026-11-22 凌晨。
> 原则：接入后本地崩溃日志（crash_log.dart）保留作离线兜底，两套并存。

## 第 0 步：用户提供的两样东西

- AppID（Bugly 产品页「产品设置」里，形如 `xxxxxxb01`）
- AppKey（UUID 形如 `aef434ba-...`）

## 第 1 步：加依赖（pubspec.yaml）

```yaml
dependencies:
  bugly_pro_flutter: ^1.0.0   # 以 pub.dev 最新稳定版为准
```

> 这是项目第一个第三方依赖，会打破"零依赖"纪录——已经用户确认接受。

## 第 2 步：Android 配置

`android/app/build.gradle` 确认 minSdk ≥ 19（当前满足），无需其他改动。

## 第 3 步：初始化（lib/crash_log.dart 的 installCrashLog 处）

```dart
// TODO(Bugly): 拿到 AppID 后取消注释
// import 'package:bugly_pro_flutter/bugly.dart';
// await Bugly().init(appId: 'xxxxxxb01', appKey: '...', debugMode: false);
```

放在 `installCrashLog()` 之后、`runZonedGuarded` 内 `WidgetsFlutterBinding` 之后，即用户隐私同意后的首个初始化点。

## 第 4 步：把本地日志也喂给 Bugly（可选增强）

在 `crash_log.dart` 的 `writeCrash` 里追加一行 `Bugly().reportException(...)`，
保证 Bugly 断网丢失的崩溃下次联网补报时，本地文件仍有底。

## 第 5 步：验证

1. `flutter test`（182 项基线不回退）
2. 打一个 debug 包故意 `throw`，1 分钟后 Bugly 后台看到上报
3. 版本升 1.12.0+18，重打 Release

## 回退方案

接入后如出现兼容问题：删除依赖 + 恢复 installCrashLog 注释即可，本地日志方案不受影响。
