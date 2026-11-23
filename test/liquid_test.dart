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
  });
}
