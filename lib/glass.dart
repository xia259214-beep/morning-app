import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'core.dart';

/// flutter_test 会注入 FLUTTER_TEST=true。widget 测试里若开无限动画，
/// pumpAndSettle 永远等不到「画面静止」而超时；真机不受影响。
bool get _inWidgetTest => Platform.environment['FLUTTER_TEST'] == 'true';

/// dart:ui 的 Gradient.linear 省略 colorStops 时只准 2 个颜色；
/// 画多段渐变必须显式给等距 stops，否则 paint() 直接抛异常。
List<double> _evenStops(int n) =>
    [for (var i = 0; i < n; i++) n == 1 ? 0.0 : i / (n - 1)];

// ============================================================================
// 界面质感层（v1.9.0）
//
// 目标：把原来「一层纯色底 + 一堆实心白卡」变成有纵深的水晶界面。
// 全部用 Flutter 自带能力实现，零第三方插件：
//   * 背景：底色 + 斜向渐变 + 若干径向光斑 + 一条玻璃反光斜带，
//           光斑随时间极缓慢漂移/明暗呼吸 —— 这就是「波光粼粼」。
//   * 卡片：BackdropFilter 真模糊 + 半透明渐变 + 高光描边 + 柔和投影。
//
// 省电是硬约束（这台是跑外卖的主力机）：
//   1. 背景用一个 CustomPainter 一次画完，套 RepaintBoundary，页面滚动不触发重绘；
//   2. App 退到后台立刻停掉动画（WidgetsBindingObserver），前台才继续；
//   3. 设置里可以关掉「波光流动」，关掉后背景完全静态、不占 GPU；
//   4. 选「原纸」方案时整个质感层退化为一张纯色底，无任何额外开销。
// ============================================================================

/// 一套质感方案。字段都是「叠加量」，不改文字色，
/// 所以 6 套配色（暖纸/墨夜/青苔…）随便切，文字始终看得清。
class GlassStyle {
  final String id;
  final String name;
  final String desc;

  /// 叠在底色上的斜向渐变（alpha 要低，别把背景压暗到看不清字）
  final List<Color> wash;

  /// 光斑颜色，径向渐变中心色，边缘自动透明
  final List<Color> orbs;

  /// 卡片底色不透明度：越小越透，越能看见背后的光
  final double cardAlpha;

  /// 高光描边不透明度
  final double edgeAlpha;

  /// BackdropFilter 的模糊半径；0 = 不做真模糊（最省电）
  final double blur;

  /// 光斑亮度系数（流光方案更亮一点）
  final double glow;

  /// 是否允许波光流动
  final bool shimmer;

  const GlassStyle({
    required this.id,
    required this.name,
    required this.desc,
    required this.wash,
    required this.orbs,
    required this.cardAlpha,
    required this.edgeAlpha,
    required this.blur,
    required this.glow,
    required this.shimmer,
  });

  bool get isPaper => id == 'paper';
}

/// 三套方案。第一套是原样（安全回退），后两套是真玻璃。
/// 真机对比截图后把 crystal 定为默认。
const kGlassStyles = <GlassStyle>[
  GlassStyle(
    id: 'paper',
    name: '原纸',
    desc: '实心扁平 · 和旧版一模一样，最省电',
    wash: [],
    orbs: [],
    cardAlpha: 1,
    edgeAlpha: 0,
    blur: 0,
    glow: 0,
    shimmer: false,
  ),
  GlassStyle(
    id: 'crystal',
    name: '水晶',
    desc: '浅色薄雾 · 半透明卡片，清透不刺眼',
    // v1.9.0 真机调参：第一版 alpha 只有 8%~16%，在米白底上几乎看不见，
    // 用户要的「波光粼粼」完全没出来。整体提到约两倍，仍保持浅色不刺眼。
    wash: [
      Color(0x2CE0F2FF),
      Color(0x0AFFFFFF),
      Color(0x30FFEBDA),
    ],
    orbs: [
      Color(0x4E7FD8E8), // 薄荷青
      Color(0x46F2B87C), // 淡金
      Color(0x40B9A8F0), // 淡紫
      Color(0x3C8FD3B0), // 青绿
    ],
    cardAlpha: 0.55,
    edgeAlpha: 0.8,
    blur: 10,
    glow: 1.28,
    shimmer: true,
  ),
  GlassStyle(
    id: 'aurora',
    name: '流光',
    desc: '深一点的晕染 · 波光更明显，配「墨夜」最出彩',
    wash: [
      Color(0x1F35507A),
      Color(0x0E2A3F66),
      Color(0x263C2C63),
    ],
    orbs: [
      Color(0x3A38C6D8), // 青
      Color(0x32D45FA8), // 品红
      Color(0x2EF2A55C), // 暖橙
      Color(0x306C7BF0), // 蓝紫
    ],
    cardAlpha: 0.52,
    edgeAlpha: 0.8,
    blur: 14,
    glow: 1.5,
    shimmer: true,
  ),
];

/// 质感全局开关。跟 AppColor 一样是静态入口 + ValueNotifier，
/// 切换后整棵树重建，不需要重启。
/// 玻璃卡的轮廓色。
/// 深色底用白色高光（经典水晶边）；浅色底换成一点冷灰，
/// 否则白描边压在米白卡片上根本看不见，卡片会像「浮着一块没边的雾」。
Color glassEdgeColor({double? alpha}) {
  if (!Glass.on) return AppColor.line;
  final s = Glass.style;
  final a = alpha ?? s.edgeAlpha;
  return AppColor.isDark
      ? Colors.white.withOpacity(a * 0.45)
      : const Color(0xFF8296A8).withOpacity(a * 0.58);
}

class Glass {
  static GlassStyle _style = kGlassStyles[1];

  /// 用户可关掉波光流动（省电）
  static bool motion = true;

  static final ValueNotifier<String> notifier =
      ValueNotifier<String>('crystal|1');

  static GlassStyle get style => _style;
  static bool get on => !_style.isPaper;
  static bool get animated => on && _style.shimmer && motion;

  static void apply(String id, {bool? motionOn}) {
    _style = kGlassStyles.firstWhere(
      (s) => s.id == id,
      orElse: () => kGlassStyles[0],
    );
    if (motionOn != null) motion = motionOn;
    // 值里带上 motion，保证只改「波光开关」时也能触发重建
    notifier.value = '${_style.id}|${motion ? 1 : 0}';
  }
}

// ============================================================================
// 全局背景
// ============================================================================

/// 挂在 MaterialApp.builder 上，包住整个 Navigator。
/// 于是所有页面（包括 push 出来的流程页/答题页）都共享同一张会呼吸的背景。
class GlassBackdrop extends StatefulWidget {
  final Widget child;
  const GlassBackdrop({super.key, required this.child});

  @override
  State<GlassBackdrop> createState() => _GlassBackdropState();
}

class _GlassBackdropState extends State<GlassBackdrop>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  AnimationController? _c;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Glass.notifier.addListener(_onGlassChanged);
    _sync();
  }

  void _onGlassChanged() {
    if (!mounted) return;
    setState(() {});
    _sync();
  }

  /// 需要动画时才建 controller，不需要立刻释放 —— 别留空转的 ticker
  void _sync() {
    final need = Glass.animated && !_inWidgetTest;
    if (need && _c == null) {
      _c = AnimationController(
        vsync: this,
        duration: const Duration(seconds: 22),
      );
      if (WidgetsBinding.instance.lifecycleState ==
          AppLifecycleState.resumed) {
        _c!.repeat();
      }
    } else if (!need && _c != null) {
      _c!.dispose();
      _c = null;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _c?.repeat();
    } else {
      _c?.stop();
    }
  }

  @override
  void dispose() {
    Glass.notifier.removeListener(_onGlassChanged);
    WidgetsBinding.instance.removeObserver(this);
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Glass.style;
    if (!Glass.on) {
      return DecoratedBox(
        decoration: BoxDecoration(color: AppColor.bg),
        child: widget.child,
      );
    }
    return Stack(
      children: [
        Positioned.fill(
          child: RepaintBoundary(
            child: _c == null
                ? CustomPaint(painter: _GlassPainter(s, 0.32, AppColor.isDark))
                : AnimatedBuilder(
                    animation: _c!,
                    builder: (_, __) => CustomPaint(
                      painter: _GlassPainter(s, _c!.value, AppColor.isDark),
                    ),
                  ),
          ),
        ),
        widget.child,
      ],
    );
  }
}

/// 一次画完的底层：底色 → 斜向渐变 → 4 个漂移光斑 → 一条玻璃反光带。
class _GlassPainter extends CustomPainter {
  final GlassStyle s;
  final double t;
  final bool dark;

  _GlassPainter(this.s, this.t, this.dark);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // 1) 主题底色（文字色就是按它配的，必须保留）
    canvas.drawRect(rect, Paint()..color = AppColor.bg);

    // 2) 斜向渐变，给背景一层「从上到下不一样」的纵深
    if (s.wash.length >= 2) {
      final shader = ui.Gradient.linear(
        Offset(0, 0),
        Offset(size.width, size.height),
        s.wash,
        _evenStops(s.wash.length),
      );
      canvas.drawRect(rect, Paint()..shader = shader);
    }

    // 3) 光斑：位置用两条不同频率的正弦缓动，半径呼吸，亮度也呼吸。
    //    周期 22 秒，动得很慢，不会晃眼。
    final phase = t * 2 * math.pi;
    for (var i = 0; i < s.orbs.length; i++) {
      final p = phase + i * 2.17;
      final cx = size.width * (0.5 + 0.34 * math.sin(p * 0.63 + i * 0.8));
      final cy = size.height *
          (0.12 + i * 0.27 + 0.09 * math.cos(p * 0.81 + i * 0.5));
      final r = size.width *
          (0.52 + 0.14 * math.sin(p * 1.1 + i)) *
          (dark ? 1.05 : 1);
      final beat = 0.72 + 0.28 * math.sin(p + i * 1.3);
      final c = s.orbs[i];
      final lit = Color.fromARGB(
        (c.alpha * beat * s.glow).clamp(0, 255).toInt(),
        c.red,
        c.green,
        c.blue,
      );
      final shader = ui.Gradient.radial(
        Offset(cx, cy),
        r,
        [lit, lit.withAlpha(0)],
        null,
        ui.TileMode.clamp,
      );
      canvas.drawCircle(Offset(cx, cy), r, Paint()..shader = shader);
    }

    // 4) 玻璃反光斜带：一条很淡的白色斜光，让背景像隔着一层玻璃
    canvas.save();
    canvas.translate(size.width * 0.5, size.height * 0.5);
    canvas.rotate(-0.62);
    final bandH = size.height * 1.9;
    final band = Rect.fromLTWH(-size.width * 0.06, -bandH / 2,
        size.width * 0.12, bandH);
    final alpha = dark ? 0.055 : 0.085;
    final bandColors = [
      Colors.white.withOpacity(0),
      Colors.white.withOpacity(alpha),
      Colors.white.withOpacity(0),
    ];
    final bandShader = ui.Gradient.linear(
      Offset(band.left, 0),
      Offset(band.right, 0),
      bandColors,
      _evenStops(bandColors.length),
    );
    canvas.drawRect(band, Paint()..shader = bandShader);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GlassPainter old) =>
      old.t != t || old.s.id != s.id || old.dark != dark;
}

// ============================================================================
// 玻璃卡片
// ============================================================================

/// 一张水晶卡片。真模糊 + 半透明渐变 + 高光描边 + 顶部一条反光。
/// 选「原纸」时自动退化成普通的实心卡（不加 BackdropFilter）。
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final double radius;
  final bool featured;

  /// 强调色（正在播放 / 选中态）。为空用主题高光色
  final Color? accent;

  /// 要不要做真模糊。列表里普通条目可以关掉，省 GPU
  final bool blur;
  final VoidCallback? onTap;

  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.margin = const EdgeInsets.only(bottom: 10),
    this.radius = 16,
    this.featured = false,
    this.accent,
    this.blur = true,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final s = Glass.style;
    final glass = Glass.on;
    final br = BorderRadius.circular(radius);

    Widget box = _body(glass, s, br);
    if (onTap != null) {
      box = GestureDetector(onTap: onTap, behavior: HitTestBehavior.opaque, child: box);
    }
    if (margin != EdgeInsets.zero) box = Padding(padding: margin, child: box);
    return box;
  }

  Widget _body(bool glass, GlassStyle s, BorderRadius br) {
    if (!glass) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: AppColor.card,
          borderRadius: br,
          border: Border.all(color: accent ?? AppColor.line),
        ),
        child: Padding(padding: padding, child: child),
      );
    }

    final base = AppColor.card;
    final fillA = base.withOpacity(s.cardAlpha);
    final fillB = base.withOpacity((s.cardAlpha - 0.16).clamp(0.08, 1.0));
    final hi = accent ?? glassEdgeColor();

    final deco = BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color.lerp(fillA, Colors.white, AppColor.isDark ? 0.02 : 0.16)!,
          fillB,
        ],
      ),
      borderRadius: br,
      border: Border.all(color: hi, width: featured ? 1.35 : 1.0),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(AppColor.isDark ? 0.30 : 0.055),
          blurRadius: featured ? 24 : 15,
          offset: const Offset(0, 7),
        ),
      ],
    );

    // 顶部一条高光：水晶的上沿
    final inner = Stack(
      children: [
        Padding(padding: padding, child: child),
        Positioned(
          left: radius * 0.8,
          right: radius * 0.8,
          top: 0,
          height: 1.4,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [
                  Colors.white.withOpacity(0),
                  Colors.white.withOpacity(AppColor.isDark ? 0.22 : 0.62),
                  Colors.white.withOpacity(0),
                ]),
              ),
            ),
          ),
        ),
      ],
    );

    Widget body = inner;
    if (blur && s.blur > 0) {
      body = BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: s.blur, sigmaY: s.blur),
        child: body,
      );
    }
    return ClipRRect(
      borderRadius: br,
      child: DecoratedBox(decoration: deco, child: body),
    );
  }
}

/// 给不方便改结构的容器用：直接塞进 Container(decoration: ...)。
/// 例如分段栏的小胶囊、标签 chip。
BoxDecoration glassDecoration({
  double radius = 12,
  Color? accent,
  bool selected = false,
  double alpha = 0.5,
  Color? flatFill,
  Color? flatBorder,
}) {
  if (!Glass.on) {
    // 原纸模式：完全回到旧版那一套实心配色，一个像素都不多画
    return BoxDecoration(
      color: selected ? AppColor.ink : (flatFill ?? AppColor.card),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: selected ? AppColor.ink : (flatBorder ?? AppColor.line)),
    );
  }
  final s = Glass.style;
  // 选中态用强调色轻微染色，别只靠描边区分——半透明之后细描边不够醒目
  final tint = (selected && accent != null)
      ? accent.withOpacity((s.cardAlpha * 0.55).clamp(0.18, 0.5))
      : null;
  final base = tint ?? AppColor.card.withOpacity(s.cardAlpha * alpha.clamp(0, 1) + 0.2);
  final tail = base.withOpacity((base.opacity - 0.12).clamp(0.06, 1.0));
  return BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [base, tail],
    ),
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(
      color: accent ?? glassEdgeColor(alpha: s.edgeAlpha * (selected ? 1.1 : 0.8)),
      width: selected ? 1.4 : 1,
    ),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withOpacity(AppColor.isDark ? 0.22 : 0.05),
        blurRadius: 12,
        offset: const Offset(0, 5),
      ),
    ],
  );
}
