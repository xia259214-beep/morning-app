# 晨序 MORNING

让每一个清晨都有意义。Android 智能闹钟 + 晨间闭环（唤醒 → 答题 → 新闻播报 → 拍照打卡）。

V1 只做本地闭环：不联网、不注册、数据只存本机。

## 结构

```
lib/
  main.dart           入口 + 五导航外壳 + 响铃拉起跳转
  core.dart           设计系统 / 数据模型 / 原生桥 / 本地存储 / 题库与新闻示例
  pages_home.dart     首页
  pages_alarms.dart   闹钟列表 + 编辑
  pages_morning.dart  晨间标签页 + 晨间流程
  pages_more.dart     记录 / 我的 / 权限诊断
android/app/src/main/
  kotlin/cn/morning/morning/
    MainActivity.kt   原生桥（13 个方法）
    AlarmStore.kt     闹钟调度中枢（setAlarmClock / 降级 / 兜底通知）
    AlarmReceiver.kt  到点入口
    RingActivity.kt   全屏响铃页（原生，锁屏直达）
    BootReceiver.kt   开机 / 改时间 / 升级后重注册
```

关键设计：核心能力全走 Kotlin 原生，不依赖第三方 Flutter 插件；Flutter 与原生共读同一份 SharedPreferences，避免双份数据。

## 构建

需要 JDK 17、Android SDK 34、Flutter 3.24.5+。

```bash
export JAVA_HOME=/d/dev/tool/jdk/jdk-17.0.2
export ANDROID_HOME=/d/dev/tool/android-sdk
flutter pub get
flutter build apk --release
# 产物：build/app/outputs/flutter-apk/app-release.apk
```

国内网络可加镜像：

```bash
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
```

## 测试

```bash
flutter test          # 5 个逻辑测试 + 4 个界面冒烟测试
```

界面测试需要本机有中文字体（默认加载 `C:\Windows\Fonts\Deng.ttf`），否则测试字体会把文字画成方块、误报布局溢出。

## 发版前要改的地方

1. `android/app/build.gradle`：release 目前用 debug 签名（下载即可装），正式发布换自己的 keystore，否则后续版本无法覆盖升级。
2. `applicationId` 目前是 `cn.morning.morning`，确定正式包名后再改，改了就不能覆盖安装。
3. 应用图标仍是 Flutter 默认图标，替换 `android/app/src/main/res/mipmap-*/ic_launcher.png`。

## 已知边界

- 不承诺百分之百不漏响：用户手动「强行停止」、极端省电策略会让任何第三方闹钟失效。
- ~~新闻为内置示例数据，实时新闻需要 V2 的采集引擎。~~ → v1.8.0 起新闻页接真实引擎，v1.10.0 起晨间播报同源。
- 无账号/云同步，卸载或换机丢数据。 → 上云路线见 `docs/上云路线图_第4第5步.md`（进行中）。

## 版本历史

- **v1.12.1**（2026-11-22）— 播报音色修复：真实新闻退回系统 TTS 时，从引擎可用音色里自动挑选本地中文女声（此前被动用引擎默认音，小米引擎上单薄刺耳）；挑不出时不改动引擎默认。仅本地音色，不联网，保证断网可用。
- **v1.12.0**（2026-11-22）— 品牌视觉对齐：启动图标换新（定稿「立体晨金·波纹」款），补齐 Android 8+ adaptive icon（前景/背景分层，小米/OPPO 等新系统不套白边）；应用名统一为「晨序MORNING」（与 Bugly 产品一致）。测试 182 项全过。
- **v1.11.0**（2026-11-22）— 零依赖本地崩溃日志：三层全局捕获（FlutterError / PlatformDispatcher / 异步区域），堆栈落盘 `crash_log.txt`（64KB 滚动），预留 Bugly 云端监控接入点（见 `docs/Bugly接入指南.md`）。测试 182 项全过。
- **v1.10.0**（2026-11-21）— 晨间播报接入真实新闻引擎（`morning_news.dart`，与新闻页同源同算法、断网回落示例）；文本净化补漏（裸域名 / emoji / 断句优化）。
- **v1.9.0** — 玻璃质感三档（原纸/水晶/流光）、播报语速三档、导航收敛为五 tab。

## 发布渠道

- GitHub Releases：`https://github.com/xia259214-beep/morning-app/releases`（资产 `morning-vX.Y.Z.apk`，注意文件名用 ASCII）
- 官网下载页：`gh-pages` 分支 `site/index.html`（Pages 需仓库公开后启用）
