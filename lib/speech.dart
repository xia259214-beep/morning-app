// ============================================================================
// 播报文本净化（v1.9.0）
//
// 用户反馈「连续播报的声音太杂」。除了音色混用，另一个真实原因是：
// 网上抓来的标题/摘要里带着 HTML 残留、网址、井号、书名号、连续标点、
// 中英混排的括号，系统 TTS 会把这些符号一个一个念出来，听着就糊成一团。
//
// 这个函数把要念的文本收拾成「能顺顺当当读出来」的一段话，纯函数、无依赖，
// 方便单测。原则是「宁可少念一点，不要念出乱码」。
// ============================================================================

/// 去掉 emoji 与变体选择符。
///
/// Dart 的 RegExp 对 Unicode 属性（\p{Emoji}）支持有限，用 runes 遍历更可靠。
/// 只过滤明确属于 emoji 的区段，避免误伤中文、数字、英文与常见标点。
String _stripEmoji(String s) {
  final buf = StringBuffer();
  for (final r in s.runes) {
    if (r == 0x200D || r == 0xFE0F) continue; // ZWJ 连接符 / 变体选择符
    if (r >= 0x1F000 && r <= 0x1FAFF) continue; // 主要 emoji 平面
    buf.writeCharCode(r);
  }
  return buf.toString();
}

/// 把一条新闻收拾成适合朗读的一段话。
///
/// [max] 是字数上限：连续播报十几条时，一条念太长人会走神，也更容易糊。
String cleanSpeech(String raw, {int max = 120}) {
  var s = raw;

  // 0) emoji 先去掉。TTS 遇到 emoji 在部分机型上会念成「表情符号」或直接乱码。
  s = _stripEmoji(s);

  // 1) HTML 标签和常见实体。IT之家的 description 是带标签的。
  s = s.replaceAll(RegExp(r'<[^>]*>'), ' ');
  const entities = {
    '&nbsp;': ' ',
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&#39;': "'",
    '&apos;': "'",
    '&hellip;': '…',
    '&mdash;': '—',
    '&ldquo;': '“',
    '&rdquo;': '”',
    '&lsquo;': '‘',
    '&rsquo;': '’',
    '&#160;': ' ',
  };
  entities.forEach((k, v) => s = s.replaceAll(k, v));
  // 剩下的 &#1234; / &xxx; 一律丢掉
  s = s.replaceAll(RegExp(r'&[#a-zA-Z0-9]{1,8};'), ' ');

  // 2) 网址：TTS 念 "h t t p s 冒号斜杠斜杠" 是最典型的杂音源
  s = s.replaceAll(RegExp(r'https?://[^\s，。；、）)]+'), ' ');
  s = s.replaceAll(RegExp(r'www\.[^\s，。；、）)]+'), ' ');
  // 2b) 裸域名：有些摘要直接写 "ithome.com / nlx.gov.cn"，没有 http/www 前缀，
  //     上面的规则漏掉，TTS 会把点一个字一个字念出来。要求域名里至少有一个字母、
  //     且后缀是常见 TLD，避免误伤 "3.14"、"2026.11.21" 这类纯数字。
  s = s.replaceAll(
    RegExp(
      r'[a-zA-Z0-9\-]+(?:\.[a-zA-Z0-9\-]+)*\.(?:com|cn|net|org|gov|io|edu|info|biz|app|tech)\b',
      caseSensitive: false,
    ),
    ' ',
  );

  // 3) 这些符号本身不该被念出来。中英文书名号、方括号保留内容但去掉框，
  //    井号/竖线/波浪/星号/反引号/箭头等直接删。
  const drop = r'[#|~*`^<>{}\\]';
  s = s.replaceAll(RegExp(drop), ' ');
  s = s.replaceAll(RegExp(r'[\[\]【】（）()]'), ' ');
  s = s.replaceAll(RegExp(r'[《》〈〉「」『』]'), ' ');
  s = s.replaceAll(RegExp(r'[“”"‘’]'), ' ');

  // 4) 折叠空白与连续标点。逗号句号挤在一起时 TTS 会一顿一顿的。
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  s = s.replaceAll(RegExp(r'[，,]{2,}'), '，');
  s = s.replaceAll(RegExp(r'[。.]{2,}'), '。');
  s = s.replaceAll(RegExp(r'[！!]{2,}'), '！');
  s = s.replaceAll(RegExp(r'[？?]{2,}'), '？');
  s = s.replaceAll(RegExp(r'[；;：:]\s*[；;：:]'), '，');
  s = s.replaceAll(RegExp(r'。\s*，'), '。');
  s = s.replaceAll(RegExp(r'，\s*。'), '。');
  // 省略号统一成一个，别让 TTS 念六个点
  s = s.replaceAll(RegExp(r'…+'), '…');
  s = s.replaceAll(RegExp(r'\.{3,}'), '…');

  // 5) 按字数截，按标点优先级找断点，别把一个词劈成两半。
  //    原来只认句号，若句号在前半段之前就只能硬截，容易断出半句话。
  //    现在依次找 句号→叹号→问号→分号→逗号，取落在后半段的最靠后一个；
  //    一个都没有才退回硬截。
  if (s.length > max) {
    var cut = s.substring(0, max);
    final half = max ~/ 2;
    var stop = -1;
    for (final mark in ['。', '！', '？', '；', '，']) {
      final i = cut.lastIndexOf(mark);
      if (i >= half && i + 1 > stop) {
        stop = i + 1;
        break;
      }
    }
    s = (stop > 0 ? cut.substring(0, stop) : cut).trim();
  }

  // 6) 结尾补一个句号：TTS 遇到句末标点会有自然的收尾停顿，
  //    条与条之间才不会连成一片。
  if (s.isEmpty) return '';
  const enders = ['。', '！', '？', '…', '，', '、'];
  if (!enders.contains(s.substring(s.length - 1))) s = '$s。';
  return s;
}

/// 判断这一串是不是「只要有一条没有录音，就整串统一用系统语音」。
///
/// 以前一串里前几条是包里的真人录音 mp3、后几条是系统 TTS，
/// 两种音色交替，正是「太杂」的主要来源。现在整串只挑一种音源。
bool useUniformVoice(List<String> samples) =>
    samples.isEmpty || samples.any((e) => e.isEmpty);
