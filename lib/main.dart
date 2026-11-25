import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core.dart';
import 'crash_log.dart';
import 'glass.dart';
import 'journal.dart';
import 'liquid.dart';
import 'pages_alarms.dart';
import 'pages_glass.dart';
import 'pages_home.dart';
import 'pages_more.dart';
import 'pages_morning.dart';
import 'pages_news.dart';
import 'pages_setup.dart';
import 'pages_update.dart';
import 'skins.dart';

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
    // v1.17.0：液态水晶风格（香槟/极光/曜石/薄荷）。空串=沿用原来的风格。
    final liquidId = Store.s('liquidId', '');
    Liquid.apply(liquidId);
    // v1.21.3：按键材质皮肤包（七档）。空串=跟随当前液态风格；未知 id 自动回退。
    CtaSkin.restore();
    // v1.17.1：亮卡配深字。历史组合「墨夜配色 + 亮系液态」会把浅字压在亮卡上，
    // 看不清；启动时自动校回暖纸。曜石是中亮暗卡，配墨夜正好，不动。
    if (Liquid.on && !Liquid.surfaceUsesLightInk(Liquid.theme!)) {
      if (AppColor.isDark) {
        AppColor.apply('paper');
        Store.set('themeId', 'paper');
      }
    }
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
    // v1.19.0：液态风格自己带字色，状态栏图标要跟着「实际字色」走，
    // 不能只看纸感主题。曜石深潭卡是暗的，纸感却可能是暖纸。
    statusBarIconBrightness: AppColor.textIsLight ? Brightness.light : Brightness.dark,
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
        builder: (context, glassId, __) => ValueListenableBuilder<String>(
          valueListenable: Liquid.notifier,
          builder: (context, liquidId, ___) => ValueListenableBuilder<String>(
            valueListenable: CtaSkin.notifier,
            builder: (context, skinId, ____) {
          _applyStatusBar();
          return MaterialApp(
            title: '晨序MORNING',
            debugShowCheckedModeBanner: false,
            theme: buildAppTheme(),
            // 液态风格用太阳光晕背景；没开就用原来的呼吸水晶背景。
            builder: (context, child) => Liquid.on
                ? LiquidBackdrop(child: child ?? const SizedBox.shrink())
                : GlassBackdrop(child: child ?? const SizedBox.shrink()),
            home: const RootShell(),
          );
            },
          ),
        ),
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

  /// v1.19.0：以前这里只有 IndexedStack + 底栏按钮，左右滑一点反应都没有。
  /// 换成 PageView 后，手势切页和点底栏两条路都走同一个 controller。
  final PageController _pageController = PageController();

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
      _scheduleUpdateCheck();
    });
    // 停在前台不切页时靠它兜住：App 一直开着、流程没走完，也会被推回去。
    // 20 秒一次，开销可以忽略；_resumePendingFlow 自己是幂等的。
    _flowWatch = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) _resumePendingFlow();
    });
  }

  Timer? _flowWatch;
  Timer? _updateWatch;

  /// v1.16.0：开屏后静默问一句「有没有新版」。
  ///
  /// 延迟 3 秒，把启动那几百毫秒先留给闹钟与流程判断；这期间要是已经被
  /// 闹钟叫进流程页，或者首次引导还没走完，就不打扰了。
  /// 检查本身受 12 小时节流约束，失败也闭嘴，不会连着弹。
  ///
  /// 用可取消的 Timer 而不是 `Future.delayed`：页面提前销毁时（widget 测试
  /// 尤其明显）定时器还挂着会被判成「泄漏」。
  void _scheduleUpdateCheck() {
    _updateWatch?.cancel();
    _updateWatch = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      if (!Store.b('setupDone', false)) return;
      if (MorningFlowPage.isOpen) return;
      checkUpdateOnLaunch(context);
    });
  }

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
    _updateWatch?.cancel();
    _pageController.dispose();
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
    // v1.13.2：恢复时带上上次走到哪一步。以前只推 locked 流程、步骤归零，
    // 强制播报点「我已出门」后按 Home 再回来，流程从唤醒重走——
    // 要答满 8 题才见得到打卡页，拍照按钮"不弹出"就是这个原因。
    _pushFlow(alarmId: 0, locked: true, resumeStep: Store.i('flowPendingStep', 0));
  }

  /// 轮询和 resume 可能同时命中，这里挡一下，避免叠出两层流程页
  bool _pushing = false;

  Future<void> _pushFlow({required int alarmId, required bool locked, int resumeStep = 0}) async {
    if (_pushing) return;
    _pushing = true;
    try {
      // 记下「今天这次流程还没收尾」，按 Home 回来后靠它把人拽回来
      if (locked) Store.set('flowPending', Store.today);
      // v1.13.0：强制播报模式点了「我已出门」后，原生写 flowStartStep=3，
      // 流程直接从打卡开始。读完立刻清掉，否则下次正常流程也会跳到打卡。
      // 注意必须走 Bridge 实时读：Store.settings 是启动时载入的内存副本，
      // 原生侧刚写进去的值在这里是看不到的（真机实测踩过）。
      var startStep = resumeStep;
      if (locked && startStep == 0) {
        final raw = await Bridge.getPref('flowStartStep');
        startStep = (int.tryParse(raw ?? '') ?? 0).clamp(0, 3);
        if (startStep != 0) await Bridge.setPref('flowStartStep', '0');
      }
      // 步骤随 flowPending 一起持久化：流程没收尾之前，恢复几条路都回到同一步
      if (locked) Store.set('flowPendingStep', startStep.toString());
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) =>
            MorningFlowPage(alarmId: alarmId, locked: locked, startStep: startStep),
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
      body: PageView(
        controller: _pageController,
        onPageChanged: (i) => setState(() => _index = i),
        children: pages,
      ),
      bottomNavigationBar: _BottomBar(
        index: _index,
        onTap: (i) {
          // 点底栏也要走 controller，否则手势滑过去之后 controller 的
          // 页码和 _index 会脱节，下一次滑动直接从旧页跳。
          setState(() => _index = i);
          if (_pageController.hasClients) {
            _pageController.animateToPage(
              i,
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOut,
            );
          }
        },
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
