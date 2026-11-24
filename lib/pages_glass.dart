import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'core.dart';
import 'glass.dart';
import 'liquid.dart';

// ============================================================================
// 界面质感设置（v1.9.0）
//
// 用户原话：「界面还不够出彩……自己多思考一下，多试验几种」。
// 所以这里不替他定死一套，而是把三套方案都做出来，能一点就换、当场对比：
//   原纸  —— 旧版实心扁平，安全回退 / 最省电
//   水晶  —— 浅色薄雾，半透明卡片（默认）
//   流光  —— 晕染更重，配「墨夜」深底最出彩
// 外加两个开关：波光流动（可关以省电）、连续播报语速（慢/标准/快）。
// ============================================================================

const kRateOptions = <(String, double)>[
  ('慢', 0.78),
  ('标准', 0.90),
  ('快', 1.02),
];

double savedRate() {
  final v = double.tryParse(Store.s('speechRate', '0.90')) ?? 0.90;
  for (final o in kRateOptions) {
    if ((o.$2 - v).abs() < 0.001) return o.$2;
  }
  return 0.90;
}

String rateLabel(double r) {
  for (final o in kRateOptions) {
    if ((o.$2 - r).abs() < 0.001) return o.$1;
  }
  return '标准';
}

class GlassPage extends StatefulWidget {
  const GlassPage({super.key});

  @override
  State<GlassPage> createState() => _GlassPageState();
}

class _GlassPageState extends State<GlassPage> {
  void _pick(GlassStyle s) {
    // 选了原来的质感就关掉液态风格，两套不会打架
    Liquid.apply('');
    Store.set('liquidId', '');
    Glass.apply(s.id);
    Store.set('glassId', s.id);
    setState(() {});
  }

  void _pickLiquid(LiquidTheme t) {
    // 亮卡配深字：如果用户当前是墨夜配色（浅字），亮卡上会看不清。
    // 自动切回暖纸配色，用户无感；曜石是中亮暗卡，配墨夜正好，不切。
    final lightSurface = !Liquid.surfaceUsesLightInk(t);
    if (lightSurface && AppColor.isDark) {
      AppColor.apply('paper');
      Store.set('themeId', 'paper');
    }
    Liquid.apply(t.id);
    Store.set('liquidId', t.id);
    setState(() {});
  }

  void _motion(bool v) {
    Glass.apply(Glass.style.id, motionOn: v);
    Store.set('glassMotion', v ? '1' : '0');
    setState(() {});
  }

  Future<void> _rate(double r) async {
    Store.set('speechRate', r.toStringAsFixed(2));
    await Bridge.setSpeechRate(r);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('界面质感',
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppColor.bgInk)),
        iconTheme: IconThemeData(color: AppColor.bgInk),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 6, 18, 30),
        children: [
          Text('点一下立刻换，不用重启。选完会记住。',
              style: TextStyle(fontSize: 12.5, color: AppColor.bgSub, height: 1.6)),
          const SizedBox(height: 16),
          _sectionTitle('液态水晶 · 新'),
          const SizedBox(height: 6),
          Text('按钮与卡片有厚度、棱镜描边；背景光晕跟着太阳走，早上东边亮、正午头顶亮、傍晚西边亮。',
              style: TextStyle(fontSize: 11, height: 1.55, color: AppColor.bgSub)),
          const SizedBox(height: 10),
          _liquidCard(null),
          for (final t in kLiquidThemes) _liquidCard(t),
          const SizedBox(height: 18),
          _sectionTitle('原来的三套质感 · 都保留'),
          const SizedBox(height: 10),
          for (final s in kGlassStyles) _styleCard(s),
          const SizedBox(height: 18),
          _sectionTitle('动效与声音'),
          const SizedBox(height: 10),
          _motionTile(),
          const SizedBox(height: 8),
          _rateTile(),
          const SizedBox(height: 18),
          GlassCard(
            margin: EdgeInsets.zero,
            radius: 14,
            blur: false,
            child: Text(
              '关于省电：光斑是背景一层画完的，页面滚动不会重画；'
              'App 退到后台会立刻停掉流动，前台才继续。'
              '关掉「波光流动」或选「原纸」，背景完全静态，不额外耗电。\n'
              '播报语速只作用于连续播报里的系统语音，随时可调，立即生效。',
              style: TextStyle(fontSize: 11.5, height: 1.75, color: AppColor.sub),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.only(left: 2),
        child: Text(t,
            style: TextStyle(
                fontSize: 12,
                color: AppColor.bgAccent,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6)),
      );

  /// 液态风格卡片。[t] 为 null 表示「用回原来的风格」这一项。
  Widget _liquidCard(LiquidTheme? t) {
    final active = t == null ? !Liquid.on : (Liquid.id == t.id);
    final swatch = t ?? kLiquidThemes.first;
    return GlassCard(
      padding: const EdgeInsets.all(12),
      radius: 16,
      featured: active,
      blur: false,
      accent: active ? AppColor.accent.withOpacity(0.85) : null,
      onTap: () {
        if (t == null) {
          Liquid.apply('');
          Store.set('liquidId', '');
        } else {
          _pickLiquid(t);
        }
        setState(() {});
      },
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(11),
            child: SizedBox(
              width: 72,
              height: 62,
              child: CustomPaint(
                painter: _MiniLiquidPainter(swatch, t == null),
                child: Center(
                  child: t == null
                      ? Icon(Icons.auto_awesome_outlined,
                          size: 20, color: AppColor.sub)
                      : null,
                ),
              ),
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t?.name ?? '用回原来的风格',
                    style: TextStyle(
                        fontSize: 15,
                        color: AppColor.ink,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 5),
                Text(t?.note ?? '原来的水晶 / 流光 / 原纸三套，不变',
                    style: TextStyle(
                        fontSize: 11, height: 1.5, color: AppColor.sub)),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Icon(
            active ? Icons.radio_button_checked : Icons.radio_button_unchecked,
            size: 20,
            color: active ? AppColor.accent : AppColor.sub,
          ),
        ],
      ),
    );
  }

  Widget _styleCard(GlassStyle s) {
    final active = Glass.style.id == s.id;
    return GlassCard(
      padding: const EdgeInsets.all(12),
      radius: 16,
      featured: active,
      blur: active,
      accent: active ? AppColor.accent.withOpacity(0.85) : null,
      onTap: () => _pick(s),
      child: Row(
        children: [
          // 迷你预览：把这套方案的光斑静态画一遍，配上两张小卡片
          ClipRRect(
            borderRadius: BorderRadius.circular(11),
            child: SizedBox(
              width: 72,
              height: 66,
              child: CustomPaint(
                painter: _MiniStylePainter(s, AppColor.isDark),
                child: Padding(
                  padding: const EdgeInsets.all(9),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 40,
                        height: 7,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.62),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        width: 52,
                        height: 5,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.4),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const Spacer(),
                      Container(
                        width: 52,
                        height: 13,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.34),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                              color: Colors.white.withOpacity(0.7)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(s.name,
                        style: TextStyle(
                            fontSize: 15,
                            color: AppColor.ink,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(width: 7),
                    if (s.isPaper)
                      _tinyTag('省电')
                    else if (s.id == 'crystal')
                      _tinyTag('默认'),
                  ],
                ),
                const SizedBox(height: 5),
                Text(s.desc,
                    style: TextStyle(
                        fontSize: 11, height: 1.5, color: AppColor.sub)),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Icon(
            active ? Icons.radio_button_checked : Icons.radio_button_unchecked,
            size: 20,
            color: active ? AppColor.accent : AppColor.sub,
          ),
        ],
      ),
    );
  }

  Widget _tinyTag(String t) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
        decoration: BoxDecoration(
          color: AppColor.accentSoft,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(t,
            style: TextStyle(fontSize: 9.5, color: AppColor.accent)),
      );

  Widget _motionTile() {
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      radius: 14,
      blur: false,
      child: Row(
        children: [
          Icon(Icons.water_drop_outlined, size: 18, color: AppColor.accent),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('波光流动', style: TextStyle(fontSize: 13.5)),
                const SizedBox(height: 3),
                Text(
                  Glass.motion
                      ? '光斑缓慢漂移，背景像隔着一层水'
                      : '已静止，只剩分层光晕',
                  style: TextStyle(fontSize: 10.5, color: AppColor.sub),
                ),
              ],
            ),
          ),
          Switch(
            value: Glass.motion,
            activeColor: AppColor.accent,
            onChanged: _motion,
          ),
        ],
      ),
    );
  }

  Widget _rateTile() {
    final cur = savedRate();
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 13),
      radius: 14,
      blur: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.record_voice_over_outlined,
                  size: 18, color: AppColor.accent),
              const SizedBox(width: 11),
              const Text('连续播报语速', style: TextStyle(fontSize: 13.5)),
              const Spacer(),
              Text(rateLabel(cur),
                  style: TextStyle(fontSize: 11.5, color: AppColor.sub)),
            ],
          ),
          const SizedBox(height: 11),
          Row(
            children: [
              for (final o in kRateOptions) ...[
                Expanded(
                  child: GestureDetector(
                    onTap: () => _rate(o.$2),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: glassDecoration(
                        radius: 9,
                        selected: (o.$2 - cur).abs() < 0.001,
                        accent: AppColor.accent.withOpacity(0.8),
                        flatFill: Colors.transparent,
                      ),
                      child: Center(
                        child: Text(o.$1,
                            style: TextStyle(
                              fontSize: 12,
                              color: (o.$2 - cur).abs() < 0.001
                                  ? AppColor.accent
                                  : AppColor.sub,
                              fontWeight: (o.$2 - cur).abs() < 0.001
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            )),
                      ),
                    ),
                  ),
                ),
                if (o.$1 != kRateOptions.last.$1) const SizedBox(width: 8),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// 液态风格缩略图：底色 + 太阳光斑 + 一张棱镜边小卡
class _MiniLiquidPainter extends CustomPainter {
  final LiquidTheme t;
  final bool plain;

  _MiniLiquidPainter(this.t, this.plain);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    if (plain) {
      canvas.drawRect(rect, Paint()..color = AppColor.card);
      return;
    }
    canvas.drawRect(rect, Paint()..color = t.bg);
    final c = Offset(size.width * 0.24, size.height * 0.22);
    final r = size.width * 0.8;
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(
          center: Alignment.center,
          radius: 1,
          colors: [t.orb.withOpacity(0.6), t.orb.withAlpha(0)],
          tileMode: TileMode.clamp,
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );
    final card = RRect.fromRectAndRadius(
      Rect.fromLTWH(10, 14, size.width - 20, size.height - 28),
      const Radius.circular(8),
    );
    canvas.drawRRect(
      card,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [t.cardFrom, t.cardTo],
        ).createShader(rect),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(card.outerRect.deflate(1), const Radius.circular(7)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..shader = LinearGradient(
          colors: [t.edgeA, t.edgeB, t.edgeC],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(covariant _MiniLiquidPainter old) =>
      old.t != t || old.plain != plain;
}

/// 方案缩略图：静态画一遍底色 + 光斑，不启动动画，省得设置页也一直重绘。
class _MiniStylePainter extends CustomPainter {
  final GlassStyle s;
  final bool dark;
  _MiniStylePainter(this.s, this.dark);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = AppColor.bg);
    if (s.isPaper) {
      canvas.drawRect(rect, Paint()..color = AppColor.card);
      return;
    }
    if (s.wash.length >= 2) {
      canvas.drawRect(
        rect,
        Paint()
          ..shader = ui.Gradient.linear(
            Offset(0, 0),
            Offset(size.width, size.height),
            s.wash,
            [for (var i = 0; i < s.wash.length; i++) i / (s.wash.length - 1)],
          ),
      );
    }
    for (var i = 0; i < s.orbs.length; i++) {
      final cx = size.width * (0.5 + 0.36 * math.sin(i * 2.17));
      final cy = size.height * (0.12 + i * 0.27);
      final r = size.width * 0.52;
      final c = s.orbs[i];
      canvas.drawCircle(
        Offset(cx, cy),
        r,
        Paint()
          ..shader = ui.Gradient.radial(
            Offset(cx, cy),
            r,
            [c, c.withAlpha(0)],
            null,
            ui.TileMode.clamp,
          ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MiniStylePainter old) =>
      old.s.id != s.id || old.dark != dark;
}
