import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core.dart';
import 'crash_log.dart';
import 'glass.dart';
import 'journal.dart';
import 'pages_alarms.dart';
import 'pages_glass.dart';
import 'pages_home.dart';
import 'pages_more.dart';
import 'pages_morning.dart';
import 'pages_news.dart';
import 'pages_setup.dart';

Future<void> main() async {
  // v1.11.0：全局崩溃捕获先装上，后面任何初始化炸了都能留痕。
  // runZonedGuarded 兜住异步区域里逃逸的未捕获异常。
  installCrashLog(version: kAppVersion);
  await runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await Store.load();
    // 日志和记录分开加载：日志坏掉不该把闹钟一起拖下水
    await Journal.load();
    // 上次选的配色在启动时就生效，避免先闪一帧默认色再变
    AppColor.apply(Store.s('themeId', 'paper'));
    // v1.9.0：上次选的界面质感（原纸/水晶/流光）与波光开关一并恢复
    Glass.apply(
      Store.s('glassId', 'crystal'),
      motionOn: Store.b('glassMotion', true),
    );
    _applyStatusBar();
    runApp(const MorningApp());
  }, (error, stack) {
    // 异步区域的漏网之鱼：交给崩溃日志（FlutterError/Platform 已覆盖一部分）
    try {
      Bridge.writeCrashLog(
          formatCrash('async', error, stack, version: kAppVersion));
    } catch (_) {}
  });
}

/// 状态栏图标颜色跟随主题：深色主题要用浅色图标，否则看不见
void _applyStatusBar() {
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: AppColor.isDark ? Brightness.light : Brightness.dark,
  ));
}

class MorningApp extends StatelessWidget {
  const MorningApp({super.key});

  @override
  Widget build(BuildContext context) {
    // 换肤 / 换质感时整棵树重建：AppColor、Glass 都是静态入口，
    // 不重建的话已建好的页面还是旧样子。两个 notifier 都要听。
    return ValueListenableBuilder<String>(
      valueListenable: AppColor.notifier,
      builder: (context, themeId, _) => ValueListenableBuilder<String>(
        valueListenable: Glass.notifier,
        builder: (context, glassId, __) {
          _applyStatusBar();
          return MaterialApp(
            title: '晨序 MORNING',
            debugShowCheckedModeBanner: false,
            theme: buildAppTheme(),
            // 整棵树底下铺一层会呼吸的水晶背景，所有页面共用，
            // 包括 push 出来的流程页、答题页、榜单页。
            builder: (context, child) =>
                GlassBackdrop(child: child ?? const SizedBox.shrink()),
            home: const RootShell(),
          );
        },
      ),
    );
  }
}

/// 五导航外壳：首页 / 闹钟 / 晨间 / 记录 / 我的
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> with WidgetsBindingObserver {
  int _index = 0;
  int _refreshKey = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 响铃页点「起床」会拉起本页，这里消费一次性事件进入晨间流程
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkLaunchEvent();
      _maybeSetup();
      // v1.9.0：把上次选的播报语速推给原生，双保险（原生自己也读了一份）
      Bridge.setSpeechRate(savedRate());
    });
    // 停在前台不切页时靠它兜住：App 一直开着、流程没走完，也会被推回去。
    // 20 秒一次，开销可以忽略；_resumePendingFlow 自己是幂等的。
    _flowWatch = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) _resumePendingFlow();
    });
  }

  Timer? _flowWatch;

  /// 首次启动先把「能叫醒人」的四项权限过一遍；跳过过的用户不再打扰
  Future<void> _maybeSetup() async {
    if (Store.b('setupDone', false) || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => const SetupPage(),
      fullscreenDialog: true,
    ));
    if (mounted) setState(() => _refreshKey++);
  }

  @override
  void dispose() {
    _flowWatch?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkLaunchEvent();
  }

  /// 处理来自原生的启动事件；**没有事件时**也要检查一次「是否有欠着的流程」。
  ///
  /// 这是 v1.5.0「闹钟不能被关掉」在 Dart 侧的那一半：
  /// 点「起床」进入流程后，按 Home 键回桌面是躲得开的（普通应用拦不住 Home），
  /// 但只要他再打开 App，这里就会把他送回流程页。
  Future<void> _checkLaunchEvent() async {
    final e = await Bridge.consumeLaunchEvent();
    if (!mounted) return;

    if (e == null) {
      _resumePendingFlow();
      return;
    }

    final type = (e['type'] as String?) ?? 'ring';
    final alarmId = (e['alarmId'] as num?)?.toInt() ?? 0;

    // 已经站在流程页上，就别再叠一层
    if (MorningFlowPage.isOpen) return;

    // 追赶弹回来时，今天要是已经打过卡了，就没必要再进流程
    if (type == 'chase') {
      if (Store.todayRecord()?.completed == true) {
        await Bridge.cancelChase();
        return;
      }
      await _pushFlow(alarmId: 0, locked: true);
      return;
    }

    await _pushFlow(alarmId: alarmId, locked: true);
  }

  /// 回到 App 但没有新事件：检查今天是否还有一次没走完的流程
  void _resumePendingFlow() {
    if (MorningFlowPage.isOpen) return;
    if (Store.s('flowPending', '') != Store.today) return;
    if (Store.todayRecord()?.completed == true) {
      Store.set('flowPending', '');
      return;
    }
    _pushFlow(alarmId: 0, locked: true);
  }

  /// 轮询和 resume 可能同时命中，这里挡一下，避免叠出两层流程页
  bool _pushing = false;

  Future<void> _pushFlow({required int alarmId, required bool locked}) async {
    if (_pushing) return;
    _pushing = true;
    try {
      // 记下「今天这次流程还没收尾」，按 Home 回来后靠它把人拽回来
      if (locked) Store.set('flowPending', Store.today);
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => MorningFlowPage(alarmId: alarmId, locked: locked),
      ));
      if (mounted) setState(() => _refreshKey++);
    } finally {
      _pushing = false;
    }
  }

  /// 用户自己点「开始晨间流程」：可以随时退出，不锁
  void _openMorning() {
    _pushFlow(alarmId: 0, locked: false);
  }

  @override
  Widget build(BuildContext context) {
    // v1.9.0：去掉「晨间」这个独立标签页。它只是「看今日进度 + 手动发起流程」
    // 的重复入口，首页那颗「开始今天的晨间流程」按钮已经完全覆盖，
    // 闹钟触发的流程走 _pushFlow，也不经过这里。少一个 tab，底部更清爽。
    final pages = <Widget>[
      HomePage(key: ValueKey('home$_refreshKey'), onStartMorning: _openMorning),
      AlarmsPage(key: ValueKey('alarm$_refreshKey')),
      NewsPage(key: ValueKey('news$_refreshKey')),
      RecordsPage(key: ValueKey('rec$_refreshKey')),
      ProfilePage(key: ValueKey('me$_refreshKey')),
    ];

    return Scaffold(
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: _BottomBar(
        index: _index,
        onTap: (i) => setState(() => _index = i),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  final int index;
  final ValueChanged<int> onTap;

  const _BottomBar({required this.index, required this.onTap});

  static const _items = [
    ('首页', Icons.wb_twilight),
    ('闹钟', Icons.alarm),
    ('新闻', Icons.article_outlined),
    ('记录', Icons.insights),
    ('我的', Icons.person_outline),
  ];

  @override
  Widget build(BuildContext context) {
    final glass = Glass.on;
    final bar = SafeArea(
      top: false,
      child: SizedBox(
        height: 62,
        child: Row(
          children: [
            for (var i = 0; i < _items.length; i++)
              Expanded(
                child: InkWell(
                  onTap: () => onTap(i),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _items[i].$2,
                        size: 22,
                        color: i == index ? AppColor.accent : AppColor.sub,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _items[i].$1,
                        style: TextStyle(
                          fontSize: 11,
                          color: i == index ? AppColor.accent : AppColor.sub,
                          fontWeight: i == index ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    if (!glass) {
      return Container(
        decoration: BoxDecoration(
          color: AppColor.card,
          border: Border(top: BorderSide(color: AppColor.line)),
        ),
        child: bar,
      );
    }
    // 玻璃底栏：真模糊 + 半透明渐变 + 一条上沿高光，像压在水面上的一块玻璃。
    // 不选「原纸」时才做 BackdropFilter，避免多余的 GPU 开销。
    return ClipRRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(
            sigmaX: Glass.style.blur * 1.2, sigmaY: Glass.style.blur * 1.2),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                AppColor.card.withOpacity(Glass.style.cardAlpha + 0.14),
                AppColor.card.withOpacity(Glass.style.cardAlpha + 0.02),
              ],
            ),
            border: Border(
              top: BorderSide(
                color: Colors.white.withOpacity(
                    AppColor.isDark ? 0.16 : Glass.style.edgeAlpha),
                width: 1,
              ),
            ),
          ),
          child: bar,
        ),
      ),
    );
  }
}
