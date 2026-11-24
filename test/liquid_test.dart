import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morning/core.dart';
import 'package:morning/liquid.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('morning/native'),
      (call) async => null,
    );
  });

  group('太阳方位', () {
    test('六个关键时刻的方位与高度', () {
      final dawn = SunPos.of(DateTime(2026, 11, 24, 6));
      final noon = SunPos.of(DateTime(2026, 11, 24, 12));
      final dusk = SunPos.of(DateTime(2026, 11, 24, 18));
      final midnight = SunPos.of(DateTime(2026, 11, 24, 0));

      expect(dawn.x > 0.8, true, reason: '日出该在右边（东）');
      expect(noon.y < 0.2, true, reason: '正午该在上方（南）');
      expect(noon.altitude, 1.0, reason: '正午最高');
      expect(dusk.x < 0.2, true, reason: '日落该在左边（西）');
      expect(midnight.altitude, 0.0, reason: '午夜没有太阳');
    });

    test('全天转一圈，坐标都在屏幕内', () {
      for (var h = 0; h < 24; h++) {
        final p = SunPos.of(DateTime(2026, 11, 24, h));
        expect(p.x >= 0 && p.x <= 1, true, reason: '$h 点 x 越界');
        expect(p.y >= 0 && p.y <= 1, true, reason: '$h 点 y 越界');
        expect(p.altitude >= 0 && p.altitude <= 1, true);
      }
    });
  });

  group('液态风格', () {
    test('四套风格齐全，关掉后不启用', () {
      expect(kLiquidThemes.length, 4);
      Liquid.apply('');
      expect(Liquid.on, false);
      expect(Liquid.theme, isNull);
      for (final t in kLiquidThemes) {
        Liquid.apply(t.id);
        expect(Liquid.on, true);
        expect(Liquid.theme?.id, t.id);
      }
      Liquid.apply('');
    });

    test('未知 id 安全回退到第一套，不会崩', () {
      Liquid.apply('not-exist');
      expect(Liquid.theme?.id, kLiquidThemes.first.id);
      Liquid.apply('');
    });

    test('卡片表面永远比背景亮：亮度差至少 25%', () {
      for (final t in kLiquidThemes) {
        final surface = Liquid.surfaceOf(t);
        final background = t.bg;
        // 相对亮度：0.2126R + 0.7152G + 0.0722B
        double lum(Color c) =>
            (0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue) / 255;
        final diff = lum(surface) - lum(background);
        expect(diff > 0.25, true,
            reason: '${t.name} 卡片和背景太接近，差只有 ${diff.toStringAsFixed(2)}');
      }
    });

    test('GlassCard 与 glassCard 在液态下都取固定亮色，跟随风格', () {
      for (final t in kLiquidThemes) {
        Liquid.apply(t.id);
        expect(AppColor.glassCard, Liquid.surfaceOf(t),
            reason: '${t.name}: glassCard 没跟上液态亮色');
        expect(AppColor.glassEdge, Liquid.edgeOf(t),
            reason: '${t.name}: glassEdge 没跟上棱镜描边');
      }
      Liquid.apply('');
    });

    test('v1.19.0：每套风格的字色与卡片底色对比度达标', () {
      // WCAG 相对亮度，用来量化「看不看得清」，不靠肉眼猜
      double relLum(Color c) {
        double ch(int v) {
          final x = v / 255;
          return x <= 0.03928 ? x / 12.92 : math.pow((x + 0.055) / 1.055, 2.4).toDouble();
        }
        return 0.2126 * ch(c.red) + 0.7152 * ch(c.green) + 0.0722 * ch(c.blue);
      }

      double contrast(Color a, Color b) {
        final la = relLum(a);
        final lb = relLum(b);
        return (la > lb ? la + 0.05 : lb + 0.05) /
            (la > lb ? lb + 0.05 : la + 0.05);
      }

      for (final t in kLiquidThemes) {
        final darkCard = Liquid.surfaceUsesLightInk(t);
        expect(Liquid.luminance(t.ink) > 0.5, darkCard,
            reason: '${t.name}: 暗卡要配浅字，亮卡要配深字');
        final main = contrast(t.ink, t.cardFrom);
        final minor = contrast(t.sub, t.cardFrom);
        expect(main >= 4.5, true,
            reason: '${t.name}: 主字对比度只有 ${main.toStringAsFixed(2)}，低于 4.5');
        expect(minor >= 3.0, true,
            reason: '${t.name}: 次要字对比度只有 ${minor.toStringAsFixed(2)}，低于 3.0');
      }
    });

    test('v1.19.0：AppColor 的字色跟着液态主题走，不是纸感主题', () {
      AppColor.apply('paper');
      for (final t in kLiquidThemes) {
        Liquid.apply(t.id);
        expect(AppColor.ink, t.ink, reason: '${t.name}: ink 没跟随');
        expect(AppColor.sub, t.sub, reason: '${t.name}: sub 没跟随');
        expect(AppColor.accent, t.accent, reason: '${t.name}: accent 没跟随');
        expect(AppColor.softInk, t.sub, reason: '${t.name}: 写死褐色的说明字没跟随');
        expect(AppColor.onInk, AppColor.textIsLight ? const Color(0xFF10201B) : Colors.white);
      }
      // 画在深色背景上的标题/说明恒用浅字，不能跟卡片字一起变深
      for (final t in kLiquidThemes) {
        Liquid.apply(t.id);
        expect(Liquid.luminance(AppColor.bgInk) > 0.5, true,
            reason: '${t.name}: 背景标题太暗');
        expect(Liquid.luminance(AppColor.bgSub) > 0.5, true,
            reason: '${t.name}: 背景说明太暗');
        expect(Liquid.luminance(AppColor.bgAccent) > 0.5, true,
            reason: '${t.name}: 背景分组标题太暗');
      }
      // 关掉液态后必须回到纸感主题，老风格一个像素不变
      Liquid.apply('');
      expect(AppColor.ink, kThemes.first.ink);
      expect(AppColor.sub, kThemes.first.sub);
      expect(AppColor.softInk, const Color(0xFF6B5A45));
    });
  });
}
