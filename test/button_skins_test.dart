// 按键材质皮肤包测试（v1.21.3）
//
// 守住皮肤包接入说明里的三条硬性承诺：
//   09 未知 id 静默回退 glass，不崩；
//   01 七档文字对比度全部达标（皮肤包承诺 ≥9:1，这里守 4.5:1 底线再抬一档）；
//   骨架不变量——每档都必须有底部暗线收口（防泛白的关键）。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morning/skins.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('morning/native'),
      (call) async => null,
    );
  });

  group('皮肤包回退与持久化', () {
    test('未知 id 静默回退 glass，不崩', () {
      CtaSkin.apply('not-exist');
      expect(CtaSkin.id, 'glass');
      expect(CtaSkin.skin?.id, 'glass');
    });

    test('空串/none = 跟随当前液态风格（skin 为 null）', () {
      CtaSkin.apply('');
      expect(CtaSkin.on, false);
      expect(CtaSkin.skin, isNull);
      CtaSkin.apply('none');
      expect(CtaSkin.on, false);
    });

    test('七档 id 全部可选中且互不相同', () {
      final ids = kButtonSkins.map((s) => s.id).toSet();
      expect(ids.length, 7);
      const valid = {'glass', 'frosted', 'system', 'well', 'ghost', 'row', 'contrast'};
      expect(ids, valid);
      for (final s in kButtonSkins) {
        CtaSkin.apply(s.id);
        expect(CtaSkin.id, s.id);
        expect(CtaSkin.skin?.name, s.name);
      }
    });
  });

  group('骨架不变量', () {
    test('每档都有底部暗线收口（row 的其他线全透明，但底线必须在）', () {
      for (final s in kButtonSkins) {
        expect(s.bottom.alpha, greaterThan(0),
            reason: '${s.id} 缺底部暗线，会复发「泛白」');
      }
    });

    test('well 档顶/底光必须反转（上暗下亮才算凹槽）', () {
      final well = kButtonSkins.firstWhere((s) => s.id == 'well');
      expect(well.top.computeLuminance(), lessThan(well.bottom.computeLuminance()));
    });

    test('row 档是减法终点：填充、描边、顶线全透明', () {
      final row = kButtonSkins.firstWhere((s) => s.id == 'row');
      expect(row.face.first.alpha, 0);
      expect(row.edge.alpha, 0);
      expect(row.top.alpha, 0);
    });
  });

  group('对比度（皮肤包承诺 ≥9:1，这里守 WCAG AA+ 底线）', () {
    // 液态风格最深的背景色，作为半透明填充的复合底
    const backdrop = Color(0xFF14110E);

    test('七档 fg 对复合后的填充对比度全部 > 4.5:1', () {
      for (final s in kButtonSkins) {
        final ratio = skinContrastRatio(s, backdrop);
        expect(ratio, greaterThan(4.5),
            reason: '${s.id}（${s.name}）对比度 $ratio，低于 WCAG AA');
      }
    });

    test('高对比档 ≥ 12:1', () {
      final contrast = skinContrastRatio(
        kButtonSkins.firstWhere((s) => s.id == 'contrast'),
        backdrop,
      );
      expect(contrast, greaterThan(12));
    });
  });
}
