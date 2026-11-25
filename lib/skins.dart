// ============================================================================
// 按键材质皮肤包（v1.21.3）
//
// 来源：UI 设计会话交付的「晨序MORNING-皮肤包」（skins.json schema 1.0），
// 7 档可选：液态玻璃 / 磨砂 / 系统填充 / 内凹 / 幽灵描边 / 列表行 / 高对比。
//
// 设计约束（照皮肤包的接入说明逐条落实）：
//   * 七档共用同一副骨架——同一个形状、只换 8 个材质参数，不加层、不加发光；
//   * 底部永远有一条 1px 暗线收口（防「泛白」复发的关键）；
//   * 按下 = 原地缩放 .972 + 内凹阴影 + 明度略降，不用 translateY；
//   * 未知 id 静默回退 glass，不崩、不出空白按钮；
//   * 只在液态风格开启时生效（皮肤色值按深色底设计，浅色纸底上会看不清）。
//
// 持久化 key：morning.skin（与皮肤包约定一致）。空串 = 跟随当前液态风格。
// ============================================================================


import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'core.dart';

/// 一档按键材质。8 个参数与 skins.json 的 8 个 `--cta-*` token 一一对应。
class ButtonSkin {
  final String id;
  final String name;
  final String family;
  final String note;
  final String contrast;

  /// 表面填充。1 个颜色 = 纯色；多个 = 垂直渐变（[stops] 可空则均分）。
  final List<Color> face;

  /// 渐变停靠点（与 [face] 等长），可空。
  final List<double>? stops;

  /// 文字与箭头颜色（--cta-fg）
  final Color fg;

  /// 背景模糊强度（--cta-blur；0 = 不模糊）
  final double blurSigma;

  /// 1px 中性细描边（--cta-edge；透明 = 不画）
  final Color edge;

  /// 1px 顶部方向性高光（--cta-top）
  final Color top;

  /// 1px 底部暗线收口（--cta-bottom，防泛白的关键，任何档都不许没有）
  final Color bottom;

  /// 按下时内凹阴影（--cta-press）
  final Color press;

  /// 外部接触阴影（--cta-cast；透明 = 无外影）
  final Color castColor;
  final double castBlur;
  final Offset castOffset;

  const ButtonSkin({
    required this.id,
    required this.name,
    required this.family,
    required this.note,
    required this.contrast,
    required this.face,
    this.stops,
    required this.fg,
    required this.blurSigma,
    required this.edge,
    required this.top,
    required this.bottom,
    required this.press,
    required this.castColor,
    required this.castBlur,
    required this.castOffset,
  });
}

Color _rgba(int r, int g, int b, double a) =>
    Color.fromARGB((a * 255).round(), r, g, b);

const Color _kNone = Color(0x00000000);

/// 七档材质。值照抄 skins.json，逐档核对过。
final List<ButtonSkin> kButtonSkins = <ButtonSkin>[
  ButtonSkin(
    id: 'glass',
    name: '液态玻璃',
    family: '玻璃',
    note: '中性半透明透镜；顶亮底暗',
    contrast: '≈9:1',
    face: [
      _rgba(255, 255, 255, 0.145),
      _rgba(255, 255, 255, 0.095),
      _rgba(255, 255, 255, 0.038),
    ],
    stops: [0, 0.44, 1],
    fg: Color(0xFFF4F0E7),
    blurSigma: 6,
    edge: _rgba(255, 255, 255, 0.20),
    top: _rgba(255, 255, 255, 0.30),
    bottom: _rgba(0, 0, 0, 0.46),
    press: _rgba(0, 0, 0, 0.30),
    castColor: _rgba(0, 0, 0, 0.55),
    castBlur: 10,
    castOffset: Offset(0, 3),
  ),
  ButtonSkin(
    id: 'frosted',
    name: '磨砂',
    family: '玻璃',
    note: '均匀雾面非透镜；近中性饱和',
    contrast: '≈9:1',
    face: [_rgba(222, 224, 226, 0.19)],
    fg: Color(0xFFF4F0E7),
    blurSigma: 10,
    edge: _rgba(255, 255, 255, 0.14),
    top: _rgba(255, 255, 255, 0.26),
    bottom: _rgba(0, 0, 0, 0.44),
    press: _rgba(0, 0, 0, 0.30),
    castColor: _rgba(0, 0, 0, 0.50),
    castBlur: 10,
    castOffset: Offset(0, 3),
  ),
  ButtonSkin(
    id: 'system',
    name: '系统填充',
    family: '实心',
    note: '中性石墨灰单层；无模糊无层叠',
    contrast: '≈9:1',
    face: [Color(0xFF4E4B44), Color(0xFF45423B), Color(0xFF3B3832)],
    stops: [0, 0.58, 1],
    fg: Color(0xFFF6F2E9),
    blurSigma: 0,
    edge: _rgba(255, 255, 255, 0.10),
    top: _rgba(255, 255, 255, 0.15),
    bottom: _rgba(0, 0, 0, 0.52),
    press: _rgba(0, 0, 0, 0.32),
    castColor: _rgba(0, 0, 0, 0.60),
    castBlur: 8,
    castOffset: Offset(0, 2),
  ),
  ButtonSkin(
    id: 'well',
    name: '内凹',
    family: '实心',
    note: '顶/底光反转，读成一道凹槽',
    contrast: '≈12:1',
    face: [
      _rgba(0, 0, 0, 0.22),
      _rgba(0, 0, 0, 0.08),
      _rgba(255, 255, 255, 0.035),
    ],
    stops: [0, 0.46, 1],
    fg: Color(0xFFEFEAE0),
    blurSigma: 4,
    edge: _rgba(0, 0, 0, 0.34),
    top: _rgba(0, 0, 0, 0.55),
    bottom: _rgba(255, 255, 255, 0.16),
    press: _rgba(0, 0, 0, 0.36),
    castColor: _kNone,
    castBlur: 0,
    castOffset: Offset.zero,
  ),
  ButtonSkin(
    id: 'ghost',
    name: '幽灵描边',
    family: '极简',
    note: '近零填充 + 细描边；投影归零',
    contrast: '≈13:1',
    face: [_rgba(255, 255, 255, 0.05), _rgba(255, 255, 255, 0.014)],
    fg: Color(0xFFF2EDE3),
    blurSigma: 3,
    edge: _rgba(242, 237, 227, 0.40),
    top: _rgba(255, 255, 255, 0.18),
    bottom: _rgba(0, 0, 0, 0.38),
    press: _rgba(0, 0, 0, 0.28),
    castColor: _kNone,
    castBlur: 0,
    castOffset: Offset.zero,
  ),
  ButtonSkin(
    id: 'row',
    name: '列表行',
    family: '极简',
    note: '只剩一条底部分隔线，减法的终点',
    contrast: '≈13:1',
    face: [_kNone],
    fg: Color(0xFFF2EDE3),
    blurSigma: 0,
    edge: _kNone,
    top: _kNone,
    bottom: _rgba(255, 255, 255, 0.26),
    press: _rgba(0, 0, 0, 0.12),
    castColor: _kNone,
    castBlur: 0,
    castOffset: Offset.zero,
  ),
  ButtonSkin(
    id: 'contrast',
    name: '高对比',
    family: '系统',
    note: '不透明深底 + 纯白字 + 清晰描边',
    contrast: '≈16:1',
    face: [Color(0xFF232220)],
    fg: Color(0xFFFFFFFF),
    blurSigma: 0,
    edge: _rgba(255, 255, 255, 0.78),
    top: _rgba(255, 255, 255, 0.28),
    bottom: _rgba(0, 0, 0, 0.70),
    press: _rgba(0, 0, 0, 0.42),
    castColor: _kNone,
    castBlur: 0,
    castOffset: Offset.zero,
  ),
];

/// 按键材质的全局状态。
class CtaSkin {
  CtaSkin._();

  /// null = 跟随当前液态风格（原有外观）；
  /// 非 null = 选中的皮肤 id（未知 id 已在 [apply] 里回退成 glass）。
  static String? _id;

  static final ValueNotifier<String> notifier = ValueNotifier<String>('');

  /// 持久化 key，与皮肤包约定一致
  static const String storeKey = 'morning.skin';
  static const String defaultId = 'glass';

  static String? get id => _id;
  static bool get on => _id != null;

  static ButtonSkin? get skin {
    if (_id == null) return null;
    return kButtonSkins.firstWhere(
      (s) => s.id == _id,
      orElse: () => kButtonSkins.first,
    );
  }

  /// id 传 '' 或 'none' 表示「跟随当前液态风格」；
  /// 未知 id 静默回退 glass（皮肤包验收清单第 09 条）。
  static void apply(String id) {
    final v = (id.isEmpty || id == 'none') ? null : id;
    if (v != null &&
        kButtonSkins.every((s) => s.id != v)) {
      _id = defaultId;
      notifier.value = defaultId;
      Store.set(storeKey, defaultId);
      return;
    }
    if (_id == v) return;
    _id = v;
    notifier.value = id;
  }

  /// 启动时恢复。只读存储，不写回——未知值在 [apply] 里处理。
  static void restore() => apply(Store.s(storeKey, ''));
}

/// WCAG 相对亮度（0~1）。通道必须先做 sRGB 线性化，否则对比度算不准。
double _lum(Color c) {
  double ch(int v) {
    final x = v / 255;
    return x <= 0.03928 ? x / 12.92 : math.pow((x + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * ch(c.red) + 0.7152 * ch(c.green) + 0.0722 * ch(c.blue);
}

/// WCAG 对比度。face 是半透明时先复合到底色上再算。
double skinContrastRatio(ButtonSkin s, Color backdrop) {
  Color composite(Color overlay) {
    final a = overlay.alpha / 255;
    return Color.fromARGB(
      255,
      (overlay.red * a + backdrop.red * (1 - a)).round(),
      (overlay.green * a + backdrop.green * (1 - a)).round(),
      (overlay.blue * a + backdrop.blue * (1 - a)).round(),
    );
  }

  // 取填充最亮的一档与底色复合（对深色 fg 会取最暗的，这里 fg 全是浅色，
  // 取最亮档是最保守的估计——最亮填充反而压低对比）。
  Color best = s.face.first;
  var bestLum = _lum(composite(s.face.first));
  for (final c in s.face.skip(1)) {
    final l = _lum(composite(c));
    if (l > bestLum) {
      bestLum = l;
      best = c;
    }
  }
  final bgC = s.face.length == 1 && s.face.first.alpha == 0
      ? backdrop
      : composite(best);
  final l1 = _lum(s.fg) + 0.05;
  final l2 = _lum(bgC) + 0.05;
  return l1 > l2 ? l1 / l2 : l2 / l1;
}
