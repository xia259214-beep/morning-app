// ============================================================================
// 战力图：十边形雷达图（零第三方依赖，CustomPainter 原生绘制）
//
// 用户要的是「像游戏里那种六角线、八角线、十角线，一个多边形，不是圆形」。
// 十维对应 kAxes 正好十个角；对拼时把对方的战力也画进来，两种描边一比就
// 看得出谁在哪一块强。
// ============================================================================

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'core.dart';
import 'profile.dart';

/// 一张十边形战力图。[values] 与 [rival] 都是 0~1，顺序按 kAxes。
///
/// [grades] 给每个角配一个字母等级（A~F，见 grade.dart）。给了就把角标画成
/// 两行：科目名 + 字母。用户看这张图要的不是「63 分」，是「这科什么档」。
class PowerRadar extends StatelessWidget {
  final List<double> values;
  final List<double>? rival;
  final double size;

  /// 角标文字：小尺寸（段位阶梯那种）关掉，只留多边形
  final bool showLabels;

  /// 每个角的等级字母，顺序同 kAxes；null 表示只画科目名
  final List<String>? grades;

  const PowerRadar({
    super.key,
    required this.values,
    this.rival,
    this.size = 190,
    this.showLabels = true,
    this.grades,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RadarPainter(
          values: values,
          rival: rival,
          showLabels: showLabels,
          grades: grades,
          accent: AppColor.accent,
          ink: AppColor.ink,
          sub: AppColor.sub,
          line: AppColor.line,
          dark: AppColor.isDark,
        ),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  final List<double> values;
  final List<double>? rival;
  final bool showLabels;
  final List<String>? grades;
  final Color accent;
  final Color ink;
  final Color sub;
  final Color line;
  final bool dark;

  _RadarPainter({
    required this.values,
    required this.rival,
    required this.showLabels,
    this.grades,
    required this.accent,
    required this.ink,
    required this.sub,
    required this.line,
    required this.dark,
  });

  static const int _n = 10;
  static const double _rings = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final n = math.min(_n, math.min(values.length, kAxes.length));
    if (n < 3) return;

    final cx = size.width / 2;
    final cy = size.height / 2;
    // 带等级字母时角标是两行，留的边要多一点，别贴着画布边
    final pad = showLabels ? (grades == null ? 30.0 : 40.0) : 10.0;
    final r = math.min(cx, cy) - pad;
    if (r <= 4) return;

    // 角度从正上方开始，顺时针
    double angle(int i) => -math.pi / 2 + i * 2 * math.pi / n;
    Offset pt(int i, double radius) =>
        Offset(cx + radius * math.cos(angle(i)), cy + radius * math.sin(angle(i)));

    // 1) 网格：四层十边形，越往外越淡
    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;
    for (var ring = 1; ring <= _rings; ring++) {
      final rr = r * ring / _rings;
      grid.color = line.withOpacity(ring == _rings ? 0.85 : 0.42);
      final path = Path()..moveTo(pt(0, rr).dx, pt(0, rr).dy);
      for (var i = 1; i < n; i++) {
        final p = pt(i, rr);
        path.lineTo(p.dx, p.dy);
      }
      path.close();
      canvas.drawPath(path, grid);
    }

    // 2) 轴线
    final spoke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7
      ..color = line.withOpacity(0.55);
    for (var i = 0; i < n; i++) {
      final p = pt(i, r);
      canvas.drawLine(Offset(cx, cy), p, spoke);
    }

    // 3) 对方战力（先画，压在自己下面）——虚线 + 无填充
    if (rival != null && rival!.length >= n) {
      final rp = Path()..moveTo(pt(0, r * _clamp(rival![0])).dx, pt(0, r * _clamp(rival![0])).dy);
      for (var i = 1; i < n; i++) {
        final p = pt(i, r * _clamp(rival![i]));
        rp.lineTo(p.dx, p.dy);
      }
      rp.close();
      canvas.drawPath(
        rp,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = ink.withOpacity(0.55),
      );
    }

    // 4) 自己的战力：半透明填充 + 实线描边 + 顶点
    final vp = <Offset>[];
    for (var i = 0; i < n; i++) {
      vp.add(pt(i, r * _clamp(values[i])));
    }
    final fill = Path()..moveTo(vp[0].dx, vp[0].dy);
    for (var i = 1; i < n; i++) {
      fill.lineTo(vp[i].dx, vp[i].dy);
    }
    fill.close();
    canvas.drawPath(
      fill,
      Paint()
        ..style = PaintingStyle.fill
        ..color = accent.withOpacity(dark ? 0.26 : 0.20),
    );
    canvas.drawPath(
      fill,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = accent,
    );
    for (final p in vp) {
      canvas.drawCircle(
        p,
        2.6,
        Paint()
          ..style = PaintingStyle.fill
          ..color = accent,
      );
      canvas.drawCircle(
        p,
        2.6,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8
          ..color = dark ? Colors.white.withOpacity(0.7) : Colors.white,
      );
    }

    // 5) 角标：科目名 +（可选）字母等级
    if (showLabels) {
      for (var i = 0; i < n; i++) {
        final a = angle(i);
        final lr = r + 15;
        final lx = cx + lr * math.cos(a);
        final ly = cy + lr * math.sin(a);
        final tx = (lx - cx).abs() < 4
            ? TextAnchor.middle
            : (lx > cx ? TextAnchor.start : TextAnchor.end);
        final g = (grades != null && i < grades!.length) ? grades![i] : null;
        final span = TextSpan(children: [
          TextSpan(
            text: kAxes[i],
            style: TextStyle(fontSize: 9.5, color: sub, height: 1.1),
          ),
          if (g != null)
            TextSpan(
              text: '\n$g',
              style: TextStyle(
                fontSize: 11,
                height: 1.25,
                fontWeight: FontWeight.w600,
                color: accent,
              ),
            ),
        ]);
        final tp = TextPainter(
          text: span,
          textAlign: tx == TextAnchor.middle
              ? TextAlign.center
              : (tx == TextAnchor.start ? TextAlign.left : TextAlign.right),
          textDirection: TextDirection.ltr,
        )..layout();
        final left = tx == TextAnchor.middle
            ? lx - tp.width / 2
            : (tx == TextAnchor.start ? lx : lx - tp.width);
        final top = ly - tp.height / 2;
        tp.paint(canvas, Offset(left, top));
      }
    }
  }

  double _clamp(double v) => v.isNaN ? 0 : v.clamp(0.0, 1.0);

  @override
  bool shouldRepaint(covariant _RadarPainter old) =>
      old.values != values ||
      old.rival != rival ||
      old.showLabels != showLabels ||
      old.grades != grades ||
      old.accent != accent ||
      old.ink != ink;
}

enum TextAnchor { start, middle, end }
