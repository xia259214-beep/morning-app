import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morning/core.dart';
import 'package:morning/main.dart';
import 'package:morning/pages_morning.dart';

/// 加载本机中文字体，让测试里的文字宽度接近真机
/// （默认测试字体会把每个字符画成方块，宽度失真，容易误报布局溢出）
Future<void> _loadRealFont() async {
  const candidates = [
    r'C:\Windows\Fonts\Deng.ttf',
    r'C:\Windows\Fonts\simhei.ttf',
    r'C:\Windows\Fonts\msyh.ttc',
  ];
  for (final path in candidates) {
    final file = File(path);
    if (!file.existsSync()) continue;
    try {
      final bytes = file.readAsBytesSync();
      final loader = FontLoader('Roboto')
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
      return;
    } catch (_) {
      continue;
    }
  }
}

/// 「我的」页加入画像卡之后变长了，部分入口落到首屏之下。
/// 先滚到目标可见再操作，否则测试会因为「视口外」误报。
Future<void> _revealInProfile(WidgetTester tester, String text) async {
  // 画像卡从 v1.7.0 起多了「纹理」一段，页面更长，
  // 滚一次不一定够——反复滚到看见为止，最多滚六屏。
  final target = find.text(text);
  for (var i = 0; i < 6; i++) {
    if (target.evaluate().isNotEmpty) return;
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -260));
    await tester.pumpAndSettle();
  }
}

/// v1.9.0：底部去掉「晨间」tab 后，手动流程改从首页那颗按钮进。
/// 按钮在首页靠下的位置，先滚到看得见再点。
Future<void> _openMorningFromHome(WidgetTester tester) async {
  final btn = find.textContaining('晨间流程');
  for (var i = 0; i < 6; i++) {
    if (btn.evaluate().isNotEmpty) {
      try {
        await tester.ensureVisible(btn.first);
        await tester.pumpAndSettle();
        break;
      } catch (_) {
        // 还没进视口，继续滚
      }
    }
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -260));
    await tester.pumpAndSettle();
  }
  await tester.tap(btn.first);
  await tester.pumpAndSettle();
}

/// 把原生通道打桩，模拟一台权限齐全的 Android 手机，然后像用户一样点一遍。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await _loadRealFont();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('morning/native'), (call) async {
      switch (call.method) {
        case 'getPref':
          return null;
        case 'setPref':
        case 'syncAlarms':
        case 'ringTest':
        case 'speak':
        case 'stopSpeak':
        case 'setSpeechRate':
        case 'openSettings':
          return true;
        case 'canScheduleExact':
        case 'hasNotificationPermission':
        case 'canUseFsi':
        case 'isIgnoringBattery':
          return true;
        case 'requestPermission':
          return (call.arguments as Map)['what'] == 'check_camera';
        case 'deviceInfo':
          return {'brand': 'Xiaomi', 'model': 'TestPhone', 'sdk': '34'};
        case 'consumeLaunchEvent':
          return null;
        case 'takePhoto':
          return null;
        default:
          return null;
      }
    });
  });

  Future<void> boot(WidgetTester tester, {bool setupDone = true}) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await Store.load();
    // 除「首次启动」用例之外，其余用例都当作已经走完引导
    if (setupDone) {
      Store.settings['setupDone'] = '1';
    } else {
      Store.settings.remove('setupDone');
    }
    await tester.pumpWidget(const MorningApp());
    await tester.pumpAndSettle();
  }

  testWidgets('五个导航页都能正常渲染（晨间 tab 已移除）', (tester) async {
    await boot(tester);

    expect(find.text('下一个闹钟'), findsOneWidget);
    expect(find.text('今日晨间'), findsOneWidget);
    // v1.13.6：晨间流程已去掉答题，只留新闻播报 / 出门打卡两步
    expect(find.text('晨间答题'), findsNothing);
    expect(find.text('新闻播报'), findsOneWidget);
    // v1.9.0：底部去掉「晨间」独立 tab，首页仍留手动流程入口
    expect(find.byIcon(Icons.self_improvement), findsNothing);
    expect(find.byIcon(Icons.wb_twilight), findsOneWidget);
    expect(find.byIcon(Icons.alarm), findsOneWidget);
    expect(find.byIcon(Icons.article_outlined), findsOneWidget);
    expect(find.byIcon(Icons.insights), findsOneWidget);
    expect(find.byIcon(Icons.person_outline), findsOneWidget);

    // 闹钟
    await tester.tap(find.byIcon(Icons.alarm));
    await tester.pumpAndSettle();
    expect(find.text('06:30'), findsWidgets);

    // 新闻（v1.5.0 新增的第 6 个 tab；v1.6.0 拆成 今日 / 本地 / 全部 三栏）
    await tester.tap(find.byIcon(Icons.article_outlined));
    await tester.pumpAndSettle();
    expect(find.text('新闻'), findsWidgets);
    expect(find.text('今日'), findsOneWidget);
    expect(find.text('本地'), findsOneWidget);
    expect(find.text('全部'), findsOneWidget);
    // v1.8.0：顶部多了时段状态条，播报入口仍在
    expect(find.textContaining('连续播报今日'), findsOneWidget);

    // 本地栏：地区条 + 政策办事（不依赖联网，排在最前）
    await tester.tap(find.text('本地'));
    await tester.pumpAndSettle();
    expect(find.textContaining('南陵县'), findsWidgets);
    expect(find.text('政策与办事'), findsOneWidget);
    expect(find.textContaining('连续播报这一栏'), findsOneWidget);
    expect(find.textContaining('城乡居民医保'), findsWidgets);

    // 联网那一段在下面，滚一屏才进视口
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -900));
    await tester.pumpAndSettle();
    expect(find.text('本地要闻'), findsOneWidget);
    expect(find.text('联网刷新'), findsOneWidget);

    // 记录：现在是「今天 / 本月」两张视图 + 分类筛选
    await tester.tap(find.byIcon(Icons.insights));
    await tester.pumpAndSettle();
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('打卡'), findsWidgets);
    expect(find.textContaining('完成一次晨间流程'), findsOneWidget);

    // 我的
    await tester.tap(find.byIcon(Icons.person_outline));
    await tester.pumpAndSettle();
    await _revealInProfile(tester, '权限诊断');
    expect(find.text('权限诊断'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('v1.19.0：左右滑动切页与底栏点击保持同步', (tester) async {
    await boot(tester);
    final pv = find.byType(PageView);
    expect(pv, findsOneWidget);

    double currentPage() => tester.widget<PageView>(pv).controller!.page ?? -1;
    expect(currentPage(), 0.0);

    // 手指往左拖 = 看右边的闹钟页。用慢速拖，快速 drag 带惯性会翻多页。
    await tester.timedDrag(pv, const Offset(-300, 0), const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(currentPage(), 1.0, reason: '从首页往右滑没进闹钟页');

    // 往右拖回首页
    await tester.timedDrag(pv, const Offset(300, 0), const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(currentPage(), 0.0, reason: '往左滑没回首页');

    // 点底栏直达末页，再滑一次 —— 验证按钮和手势共用同一个 controller
    await tester.tap(find.byIcon(Icons.person_outline));
    await tester.pumpAndSettle();
    expect(currentPage(), 4.0, reason: '点底栏没切页');

    await tester.timedDrag(pv, const Offset(300, 0), const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(currentPage(), 3.0, reason: '底栏跳页后手势失灵，页码脱节');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('闹钟编辑页可打开并保存', (tester) async {
    await boot(tester);
    await tester.tap(find.byIcon(Icons.alarm));
    await tester.pumpAndSettle();

    await tester.tap(find.text('06:30').first);
    await tester.pumpAndSettle();
    expect(find.text('编辑闹钟'), findsOneWidget);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(Store.alarms.isNotEmpty, true);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('晨间流程可以从唤醒走到完成', (tester) async {
    await boot(tester);
    await _openMorningFromHome(tester);
    expect(find.text('我已醒来，去门口拍照'), findsOneWidget);

    await tester.tap(find.text('我已醒来，去门口拍照'));
    await tester.pumpAndSettle();

    // v1.13.3：醒了的唯一下一步就是打卡——不再经过答题/播报。
    // 点完「我已醒来」相机应自动弹出（mock 返回 null → 页面提示未获取到照片）。
    expect(find.text('出门打卡'), findsOneWidget);
    expect(find.text('拍照'), findsOneWidget);

    // v1.5.0：不再有「相机不可用，先跳过」这种一键跳过。
    // 唯一的出口要按住 3 秒，代价是今天记为未打卡（连续天数归零）。
    final giveUp = find.text('真的拍不了？（按住 3 秒）');
    expect(giveUp, findsOneWidget);
    final g = await tester.startGesture(tester.getCenter(giveUp));
    await tester.pump(const Duration(milliseconds: 1200));
    expect(find.text('继续按住…'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    await g.up();
    await tester.pumpAndSettle();

    expect(find.text('今天没有打卡'), findsOneWidget);
    // 记录必须落成「未完成」——以前这里写的是 completed = true
    expect(Store.todayRecord()?.completed, false);

    await tester.tap(find.text('收好，开始今天'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('闹钟拉起的流程：返回键退不掉', (tester) async {
    await boot(tester);

    // 单独支一个栈：把「锁着的流程页」push 进去，模拟闹钟点「起床」那一次
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(ctx).push(
                MaterialPageRoute(builder: (_) => const MorningFlowPage(alarmId: 1)),
              ),
              child: const Text('进来'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('进来'));
    await tester.pumpAndSettle();
    expect(find.text('我已醒来，去门口拍照'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    // 还在流程里。这条断言就是 v1.5.0 的核心：
    // 以前按一下返回 / 划一下手势就回桌面了，闹钟等于被关掉。
    expect(find.text('我已醒来，去门口拍照'), findsOneWidget);
    expect(find.text('进来'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('手动打开的流程可以随时退出，不会把人困住', (tester) async {
    await boot(tester);
    await _openMorningFromHome(tester);
    expect(find.text('我已醒来，去门口拍照'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    // v1.9.0：回到底部导航（首页）——手动探索流程不该被锁
    expect(find.byIcon(Icons.wb_twilight), findsOneWidget);
    expect(find.text('我已醒来，去门口拍照'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('权限诊断页展示四项检查', (tester) async {
    await boot(tester);
    await tester.tap(find.byIcon(Icons.person_outline));
    await tester.pumpAndSettle();

    await _revealInProfile(tester, '权限诊断');
    await tester.tap(find.text('权限诊断'));
    await tester.pumpAndSettle();

    expect(find.text('精准闹钟'), findsOneWidget);
    expect(find.text('通知权限'), findsOneWidget);
    expect(find.text('相机权限'), findsOneWidget);

    // 「最近一次触发」在小屏上位于折叠线以下，先滚下去再断言
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.text('最近一次触发'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('首页有常驻答题入口，四门格子今天只开一个', (tester) async {
    await boot(tester);

    // 用户踩过的坑：点过「重新开始」之后翻遍整个 App 找不到答题入口。
    // 这一条就是那个入口的回归防线。
    expect(find.text('下一个闹钟'), findsOneWidget);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -600));
    await tester.pumpAndSettle();

    expect(find.text('答题'), findsWidgets);
    expect(find.text('榜单 ›'), findsOneWidget);
    // 四个领域格子都在，但只有一个写着「今天 · 去答」
    for (final name in ['生活', '工具', '爱好', '职业']) {
      expect(find.text(name), findsWidgets, reason: '少了 $name 门');
    }
    expect(find.text('今天 · 去答 →'), findsOneWidget);
    expect(find.textContaining('四天轮一遍'), findsOneWidget);

    // 点亮的门能真的进答题页
    await tester.tap(find.text('今天 · 去答 →'));
    await tester.pumpAndSettle();
    expect(find.text('答题'), findsWidgets);
    expect(find.byKey(const ValueKey('opt0')), findsOneWidget);
    expect(find.textContaining('第 1'), findsWidgets);
  });

  testWidgets('首次启动弹出权限引导页，全绿后可进入主界面', (tester) async {
    await boot(tester, setupDone: false);

    expect(find.text('开始之前'), findsOneWidget);
    expect(find.text('通知权限'), findsOneWidget);
    expect(find.text('全屏通知'), findsOneWidget);
    expect(find.text('电池不限制'), findsOneWidget);
    expect(find.text('四项已就绪，可以开始了'), findsOneWidget);

    // 主按钮在长页底部，先滚到底
    await tester.drag(find.byType(ListView), const Offset(0, -700));
    await tester.pumpAndSettle();
    await tester.tap(find.text('四项已就绪，开始使用'));
    await tester.pumpAndSettle();

    expect(find.text('下一个闹钟'), findsOneWidget);
    expect(Store.b('setupDone', false), true);

    await tester.pumpWidget(const SizedBox());
  });
}
