// ============================================================================
// 液态水晶视觉系统（v1.17.0）
//
// 用户定的方向：按键要「柔和 + 玻璃感 + 前后分层 + 按动水晶感」，
// 背景光要「跟着一天 24 小时走，太阳到哪边哪边亮一点」。
//
// 这一层是「添加」不是「替换」：
//   * 原来的 6 套配色（kThemes）、3 套质感（kGlassStyles）一个不动；
//   * 新增的按钮 / 卡片 / 背景只在用户选了液态水晶风格时才启用；
//   * 关掉它，App 和旧版一个像素都不差。
//
// 全部用 Flutter 原生绘制，零第三方依赖。
// ============================================================================

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'core.dart';
import 'glass.dart';

/// 液态水晶的一套参数。四种新风格共用同一套结构，只换颜色。
class LiquidTheme {
  final String id;
  final String name;
  final String note;

  /// 背景底色（深色）
  final Color bg;

  /// 光晕颜色
  final Color orb;

  /// 卡片起始色 / 结束色（渐变）
  final Color cardFrom;
  final Color cardTo;

  /// 卡片描边（棱镜色，画成渐变边）
  final Color edgeA;
  final Color edgeB;
  final Color edgeC;

  /// 按钮起始色 / 结束色 / 前景字色
  final Color btnFrom;
  final Color btnTo;
  final Color btnInk;

  /// v1.19.0：卡片上的字色。以前所有液态风格共用纸感主题的 ink/sub，
  /// 曜石深潭那种中亮暗卡上压着近黑字，户外根本看不清。
  /// 每套风格自己带一套字色，亮卡用深字、暗卡用浅字。
  final Color ink;
  final Color sub;
  final Color accent;

  const LiquidTheme({
    required this.id,
    required this.name,
    required this.note,
    required this.bg,
    required this.orb,
    required this.cardFrom,
    required this.cardTo,
    required this.edgeA,
    required this.edgeB,
    required this.edgeC,
    required this.btnFrom,
    required this.btnTo,
    required this.btnInk,
    required this.ink,
    required this.sub,
    required this.accent,
  });
}

/// 四套新风格。原纸是原来的 paper 质感，不在这里——它继续走旧路径。
const List<LiquidTheme> kLiquidThemes = <LiquidTheme>[
  LiquidTheme(
    id: 'champagne',
    name: '香槟晨曦',
    note: '暖白珠光 · 和暖色底子最搭',
    bg: Color(0xFF14110E),
    orb: Color(0xFFF5CD96),
    cardFrom: Color(0xFFFAF5EC),
    cardTo: Color(0xFFE9DCCB),
    edgeA: Color(0xFFE8C9A0),
    edgeB: Color(0xFFFFF2D8),
    edgeC: Color(0xFFD9B98C),
    btnFrom: Color(0xFFFCF6EA),
    btnTo: Color(0xFFE4D3B9),
    btnInk: Color(0xFF2F2519),
    ink: Color(0xFF2F2519),
    sub: Color(0xFF6A5947),
    accent: Color(0xFFB0703D),
  ),
  LiquidTheme(
    id: 'aurora',
    name: '极光棱镜',
    note: '冷紫 + 彩虹边 · 最时尚',
    bg: Color(0xFF101024),
    orb: Color(0xFFA08CF5),
    cardFrom: Color(0xFFEEEAFE),
    cardTo: Color(0xFFC6C0E8),
    edgeA: Color(0xFFE6A8D8),
    edgeB: Color(0xFFA9C8FF),
    edgeC: Color(0xFF9FF0D8),
    btnFrom: Color(0xFFEEEAFE),
    btnTo: Color(0xFFC6C0E8),
    btnInk: Color(0xFF1D1A2E),
    ink: Color(0xFF1D1A2E),
    sub: Color(0xFF5A5672),
    accent: Color(0xFF7C67C9),
  ),
  LiquidTheme(
    id: 'obsidian',
    name: '曜石深潭',
    note: '深色高级 · 按键像点亮的水面',
    bg: Color(0xFF0C1412),
    orb: Color(0xFF3CCDA5),
    // v1.19.0：卡片整体提亮一档、描边加亮；浅字才压得住，太阳底下也读得出。
    cardFrom: Color(0xFF4F6D62),
    cardTo: Color(0xFF2E453D),
    edgeA: Color(0xFF5FB39C),
    edgeB: Color(0xFF9DEBD1),
    edgeC: Color(0xFF59A892),
    btnFrom: Color(0xFFCDF5E6),
    btnTo: Color(0xFF96D7C3),
    btnInk: Color(0xFF153029),
    ink: Color(0xFFF2FAF6),
    sub: Color(0xFFB8D8C9),
    accent: Color(0xFF6FE0B8),
  ),
  LiquidTheme(
    id: 'mint',
    name: '薄荷清露',
    note: '青绿通透 · 清爽夏天感',
    bg: Color(0xFF0E1815),
    orb: Color(0xFF82E1B4),
    // v1.19.0：卡片上下两端拉开亮度，层次更清楚；字改成深墨绿，
    // 比原来的灰褐 sub 对比度高得多，阳光下不再糊成一块。
    cardFrom: Color(0xFFF3FBF7),
    cardTo: Color(0xFFC7E7D8),
    edgeA: Color(0xFFA8E6CF),
    edgeB: Color(0xFFDCEDC1),
    edgeC: Color(0xFF8FD8C0),
    btnFrom: Color(0xFFE6F8F0),
    btnTo: Color(0xFFBEE0D2),
    btnInk: Color(0xFF12312C),
    ink: Color(0xFF12312C),
    sub: Color(0xFF3E6B5E),
    accent: Color(0xFF3E9073),
  ),
];

/// 液态风格全局开关。null = 用原来的玻璃质感（不启用本系统）。
/// 非空 = 用对应 id 的液态风格。
class Liquid {
  static String? _id;

  static final ValueNotifier<String> notifier = ValueNotifier<String>('');

  static String? get id => _id;
  static bool get on => _id != null;

  static LiquidTheme? get theme {
    if (_id == null) return null;
    return kLiquidThemes.firstWhere(
      (t) => t.id == _id,
      orElse: () => kLiquidThemes.first,
    );
  }

  /// id 传 '' 或 'none' 表示关掉，回到原来的风格
  static void apply(String id) {
    final v = (id.isEmpty || id == 'none') ? null : id;
    if (_id == v) return;
    _id = v;
    notifier.value = id;
  }

  // ---- 给旧容器用的「液态卡片表面色」 ----------------------------------
  //
  // 新闻 / 记录 / 我的等页面里有一大批直接写 AppColor.glassCard 的容器。
  // 它们要能自动跟着液态风格变亮，就从这里取色：固定亮色，不跟随系统
  // 配色（用户设成深色主题时也不会跟着暗下去）。这样卡片与背景的
  // 反差恒定，不会再出现「框子和背景一个色、字看不清」。

  /// 卡片填充色（不透明，保证一定比背景亮）
  static Color surfaceOf(LiquidTheme t) => t.cardFrom;

  /// 卡片描边色（棱镜高光）
  static Color edgeOf(LiquidTheme t) => t.edgeB;

  /// 这套风格的卡片是不是「中亮底 + 浅字」（曜石），其余都是「亮底 + 深字」
  static bool surfaceUsesLightInk(LiquidTheme t) => t.id == 'obsidian';

  /// v1.19.0：液态风格自己的字色 / 强调色。
  /// AppColor 的 ink、sub、accent 在 Liquid.on 时一律从这里取，
  /// 这样「曜石暗卡配浅字」「薄荷亮卡配深字」不再取决于用户选的纸感主题。
  static Color inkOf(LiquidTheme t) => t.ink;
  static Color subOf(LiquidTheme t) => t.sub;
  static Color accentOf(LiquidTheme t) => t.accent;

  /// 相对亮度（0 黑 ~ 1 白）。用来给状态栏图标、onInk 选正反色。
  static double luminance(Color c) =>
      (0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue) / 255;
}

/// 太阳位置：0~1 的屏幕坐标 + 0~1 的高度（夜里 0）。
/// 6 点从正东（右）升起，12 点正南（上），18 点正西（左），0 点正北（下）。
class SunPos {
  final double x;
  final double y;

  /// 0 = 地平线以下，1 = 正午最高
  final double altitude;

  const SunPos(this.x, this.y, this.altitude);

  static SunPos of(DateTime now) {
    final h = now.hour + now.minute / 60.0;
    final t = (h - 6) / 24 * 2 * math.pi;
    final x = 0.5 + 0.34 * math.cos(t);
    final y = 0.5 - 0.34 * math.sin(t);
    final alt = math.sin((h - 6) / 12 * math.pi).clamp(0.0, 1.0);
    return SunPos(x, y, alt);
  }
}

/// 液态背景。只在 Liquid.on 时替代原来的 GlassBackdrop 光晕层；
/// 关掉时外层 still 用原来的 GlassBackdrop，本类不会被挂上去。
class LiquidBackdrop extends StatefulWidget {
  final Widget child;
  const LiquidBackdrop({super.key, required this.child});

  @override
  State<LiquidBackdrop> createState() => _LiquidBackdropState();
}

class _LiquidBackdropState extends State<LiquidBackdrop> {
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    // 光不用每秒动——太阳一小时才走 15°，五分钟刷一次肉眼察觉不到跳变。
    Future.delayed(const Duration(minutes: 5), _tick);
  }

  void _tick() {
    if (!mounted) return;
    setState(() => _now = DateTime.now());
    Future.delayed(const Duration(minutes: 5), _tick);
  }

  @override
  Widget build(BuildContext context) {
    final t = Liquid.theme;
    if (t == null) return widget.child;
    return Stack(
      children: [
        Positioned.fill(
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _LiquidSky(t, SunPos.of(_now)),
            ),
          ),
        ),
        widget.child,
      ],
    );
  }
}

class _LiquidSky extends CustomPainter {
  final LiquidTheme t;
  final SunPos sun;

  _LiquidSky(this.t, this.sun);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = t.bg);

    // 太阳光斑：位置由时间定，亮度由太阳高度定
    final cx = size.width * sun.x;
    final cy = size.height * sun.y;
    final r = math.max(size.width, size.height) * 0.72;
    final a = 0.10 + 0.34 * sun.altitude;
    final lit = t.orb.withOpacity(a);
    canvas.drawCircle(
      Offset(cx, cy),
      r,
      Paint()
        ..shader = uiRadial(Offset(cx, cy), r, lit),
    );

    // 第二团冷色补光在对称侧，夜里也在，保证背景不全黑
    final bx = size.width * (1 - sun.x);
    final by = size.height * (1 - sun.y);
    final br = math.max(size.width, size.height) * 0.58;
    canvas.drawCircle(
      Offset(bx, by),
      br,
      Paint()
        ..shader = uiRadial(
            Offset(bx, by), br, t.edgeB.withOpacity(0.05 + 0.12 * (1 - sun.altitude))),
    );
  }

  static Shader uiRadial(Offset c, double r, Color lit) =>
      RadialGradient(
        center: Alignment.center,
        radius: 1,
        colors: [lit, lit.withAlpha(0)],
        tileMode: TileMode.clamp,
      ).createShader(Rect.fromCircle(center: c, radius: r));

  @override
  bool shouldRepaint(covariant _LiquidSky old) => old.t != t || old.sun != sun;
}

/// 液态水晶按钮。按下时光从触点涌开，松手回弹。
class LiquidButton extends StatefulWidget {
  final String text;
  final VoidCallback? onPressed;
  final bool secondary;

  const LiquidButton({
    super.key,
    required this.text,
    this.onPressed,
    this.secondary = false,
  });

  @override
  State<LiquidButton> createState() => _LiquidButtonState();
}

class _LiquidButtonState extends State<LiquidButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  Offset? _touch;
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _down(TapDownDetails d) {
    if (!Liquid.on) return;
    setState(() {
      _touch = d.localPosition;
      _pressed = true;
    });
    _ctrl.forward(from: 0);
  }

  void _up() {
    if (_pressed) setState(() => _pressed = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = Liquid.theme;
    if (t == null) {
      // 没开液态风格：退回原来的 FilledButton，一个像素都不差
      return FilledButton(
        onPressed: widget.onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: AppColor.ink,
          foregroundColor: AppColor.onInk,
          padding: const EdgeInsets.symmetric(vertical: 15),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        child: Text(widget.text),
      );
    }

    final ink = widget.secondary ? t.edgeB : t.btnInk;
    return GestureDetector(
      onTapDown: _down,
      onTapUp: (_) => _up(),
      onTapCancel: _up,
      onTap: widget.onPressed,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        height: widget.secondary ? 52 : 56,
        transform: Matrix4.diagonal3Values(
            _pressed ? 0.975 : 1, _pressed ? 0.975 : 1, 1),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.secondary ? 26 : 20),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: widget.secondary
                ? [t.cardFrom.withOpacity(0.5), t.cardTo.withOpacity(0.35)]
                : [t.btnFrom, t.btnTo],
          ),
          border: Border.all(
            color: widget.secondary ? t.edgeB.withOpacity(0.5) : t.edgeB,
            width: 1.2,
          ),
          boxShadow: _pressed
              ? [
                  BoxShadow(
                      color: Colors.black.withOpacity(0.28),
                      blurRadius: 12,
                      offset: const Offset(0, 4))
                ]
              : [
                  BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 20,
                      offset: const Offset(0, 9)),
                ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(widget.secondary ? 26 : 20),
          child: Stack(
            alignment: Alignment.center,
            children: [
              // 内部缓慢漂移的光晕
              Positioned(
                left: -30,
                top: -50,
                child: IgnorePointer(
                  child: Container(
                    width: 160,
                    height: 160,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [t.orb.withOpacity(0.35), t.orb.withAlpha(0)],
                      ),
                    ),
                  ),
                ),
              ),
              // 按下时从触点涌开的光
              if (_touch != null)
                AnimatedBuilder(
                  animation: _ctrl,
                  builder: (context, _) {
                    final v = _ctrl.value;
                    return CustomPaint(
                      painter: _SurgePainter(
                        center: _touch!,
                        progress: v,
                        color: t.edgeB,
                      ),
                      size: Size.infinite,
                    );
                  },
                ),
              Text(
                widget.text,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: ink,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SurgePainter extends CustomPainter {
  final Offset center;
  final double progress;
  final Color color;

  _SurgePainter({
    required this.center,
    required this.progress,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final r = math.max(size.width, size.height) * 1.4 * progress;
    final opacity = (1 - progress) * 0.75;
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..shader = RadialGradient(
          center: Alignment.center,
          radius: 1,
          colors: [color.withOpacity(opacity), color.withAlpha(0)],
          tileMode: TileMode.clamp,
        ).createShader(Rect.fromCircle(center: center, radius: r)),
    );
  }

  @override
  bool shouldRepaint(covariant _SurgePainter old) => old.progress != progress;
}

/// 液态玻璃卡片。三层：外发光 + 渐变玻璃 + 棱镜描边 + 顶部一道反光。
class LiquidFrame extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool featured;

  const LiquidFrame({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.featured = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = Liquid.theme;
    if (t == null) {
      // 没开液态风格：退回原来的玻璃卡
      return GlassCard(padding: padding, child: child);
    }
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: t.orb.withOpacity(featured ? 0.22 : 0.12),
            blurRadius: 26,
            spreadRadius: -6,
          ),
        ],
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _PrismBorder(t: t, featured: featured),
            ),
          ),
          Padding(padding: padding, child: child),
        ],
      ),
    );
  }
}

class _PrismBorder extends CustomPainter {
  final LiquidTheme t;
  final bool featured;

  _PrismBorder({required this.t, required this.featured});

  @override
  void paint(Canvas canvas, Size size) {
    final r = 20.0;
    final rect = Offset.zero & size;
    final rr = RRect.fromRectAndRadius(rect, Radius.circular(r));

    // 卡片本体：斜向渐变
    canvas.drawRRect(
      rr,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [t.cardFrom, t.cardTo],
        ).createShader(rect),
    );

    // 棱镜描边：三色渐变
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        rect.deflate(0.8),
        Radius.circular(r - 0.8),
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = featured ? 1.8 : 1.2
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [t.edgeA, t.edgeB, t.edgeC],
        ).createShader(rect),
    );

    // 顶部一道高光
    final hi = Paint()
      ..shader = LinearGradient(
        colors: [
          Colors.white.withAlpha(0),
          Colors.white.withOpacity(0.6),
          Colors.white.withAlpha(0),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, 1.4));
    canvas.drawRect(
      Rect.fromLTWH(r, 0, size.width - 2 * r, 1.4),
      hi,
    );
  }

  @override
  bool shouldRepaint(covariant _PrismBorder old) =>
      old.t != t || old.featured != featured;
}
