import 'package:flutter_test/flutter_test.dart';
import 'package:morning/core.dart';
import 'package:morning/glass.dart';
import 'package:morning/speech.dart';

// v1.9.0 界面质感层与播报净化的单测。
// 重点覆盖：三套方案切换 / 原纸完全回退 / 派生色不丢可读性 /
// 音源统一判定 / TTS 文本去噪（这几处最容易静默退化）。

void main() {
  setUp(() {
    AppColor.apply('paper');
    Glass.apply('paper');
  });

  group('质感方案', () {
    test('内置三套，id 唯一，第一套是原纸', () {
      expect(kGlassStyles.length, 3);
      expect(kGlassStyles.map((e) => e.id).toSet().length, 3);
      expect(kGlassStyles.first.isPaper, true);
      expect(kGlassStyles.first.wash.isEmpty, true);
      expect(kGlassStyles.first.orbs.isEmpty, true);
    });

    test('默认水晶方案开启玻璃，光斑与模糊都在', () {
      Glass.apply('crystal');
      expect(Glass.on, true);
      expect(Glass.style.id, 'crystal');
      expect(Glass.style.orbs.length >= 3, true);
      expect(Glass.style.blur > 0, true);
      expect(Glass.style.shimmer, true);
      expect(Glass.animated, true);
    });

    test('选原纸后玻璃完全关闭，派生色退回旧值', () {
      Glass.apply('crystal');
      expect(AppColor.glassCard, isNot(AppColor.card));
      Glass.apply('paper');
      expect(Glass.on, false);
      expect(Glass.animated, false);
      expect(AppColor.glassCard, AppColor.card);
      expect(AppColor.glassEdge, AppColor.line);
      expect(AppColor.glassPanel, AppColor.panel);
    });

    test('未知 id 安全回退到原纸，notifier 每次都变', () {
      Glass.apply('crystal');
      final before = Glass.notifier.value;
      Glass.apply('not-exist');
      expect(Glass.style.isPaper, true);
      expect(Glass.notifier.value, isNot(before));
    });

    test('关掉波光只停动画，不换方案', () {
      Glass.apply('aurora', motionOn: true);
      expect(Glass.animated, true);
      Glass.apply('aurora', motionOn: false);
      expect(Glass.style.id, 'aurora');
      expect(Glass.animated, false);
      expect(Glass.motion, false);
    });

    test('六套配色下轮廓色都不是全透明，卡片不会没边', () {
      Glass.apply('crystal');
      for (final t in kThemes) {
        AppColor.apply(t.id);
        expect(glassEdgeColor().alpha > 0, true,
            reason: '${t.name} 的描边不能透明');
        expect(AppColor.glassCard.alpha > 0, true,
            reason: '${t.name} 的卡片底不能全透');
      }
    });

    test('glassDecoration 在原纸模式退回实心，玻璃模式带描边', () {
      Glass.apply('paper');
      final flat = glassDecoration();
      expect(flat.gradient, isNull);
      expect(flat.border, isNotNull);

      Glass.apply('crystal');
      final glass = glassDecoration(selected: true);
      expect(glass.gradient, isNotNull);
      expect(glass.boxShadow, isNotNull);
    });
  });

  group('播报文本净化', () {
    test('去掉 HTML 标签与实体', () {
      expect(
        cleanSpeech('<p>央行&nbsp;宣布降准&amp;定向</p>'),
        '央行 宣布降准&定向。',
      );
    });

    test('网址不进朗读文本，避免念成一串字母', () {
      final out = cleanSpeech('详情见 https://www.nlx.gov.cn/xwzx/a.html 通知');
      expect(out.contains('http'), false);
      expect(out.contains('www'), false);
      expect(out.contains('通知'), true);
    });

    test('井号、书名号、括号等符号被清掉', () {
      final out = cleanSpeech('#突发【南陵】《公告》(2026) 发布');
      expect(out.contains('#'), false);
      expect(out.contains('【'), false);
      expect(out.contains('《'), false);
      expect(out.contains('('), false);
      expect(out.contains('突发'), true);
    });

    test('连续标点折叠、结尾补句号', () {
      final out = cleanSpeech('降准了，，，市场反应平平。。。');
      expect(out.contains('，，'), false);
      expect(out.contains('。。。'), false);
      expect(out.endsWith('。'), true);
    });

    test('超长文本在句号处断，不劈开半句', () {
      final out = cleanSpeech('第一句话讲完了。第二句话讲完了。${'很长的内容' * 60}',
          max: 40);
      expect(out.length <= 41, true);
      expect(out.endsWith('。'), true);
    });

    test('空串与纯符号不炸，返回空串', () {
      expect(cleanSpeech(''), '');
      expect(cleanSpeech('###|||~~~'), '');
    });

    // ---- v1.1.0 新增：审阅发现的 3 处遗漏 ----
    test('裸域名（无 http/www 前缀）不进朗读文本', () {
      final out = cleanSpeech('详见 ithome.com 与 nlx.gov.cn 的通知');
      expect(out.contains('ithome'), false);
      expect(out.contains('gov.cn'), false);
      expect(out.contains('通知'), true);
    });

    test('纯数字小数点不被当成域名误删', () {
      expect(cleanSpeech('增长 3.14% 到 2026.11.21'), contains('3.14'));
      expect(cleanSpeech('增长 3.14% 到 2026.11.21'), contains('2026.11.21'));
    });

    test('emoji 被清掉，不念成乱码', () {
      final out = cleanSpeech('利好消息🚀大涨📈创新高');
      expect(out.contains('🚀'), false);
      expect(out.contains('📈'), false);
      expect(out.contains('大涨'), true);
      expect(out.contains('创新高'), true);
    });

    test('超长且前半段没句号时，在逗号处断而不是硬截', () {
      final text = '这是一段很长但没有句号的内容，后面还有很多很多字，'
          '${'继续说下去' * 30}';
      final out = cleanSpeech(text, max: 40);
      expect(out.length <= 41, true);
      // 断在逗号的自然位置：以中文标点收尾（结尾是逗号时不补句号，属既有设计）
      expect(out.endsWith('。') || out.endsWith('，'), true);
      // 不把「继续说下去」这个词劈开
      expect(out.contains('继续说下'), false);
    });
  });

  group('整串统一音源', () {
    test('空串列表不算混合', () {
      expect(useUniformVoice([]), true);
    });

    test('全部都有录音 → 保持录音，不强制转 TTS', () {
      expect(useUniformVoice(['n01', 'n02', 'n03']), false);
    });

    test('只要有一条没录音 → 整串统一走系统语音', () {
      expect(useUniformVoice(['n01', '', 'n03']), true);
      expect(useUniformVoice(['', '', '']), true);
    });
  });
}
