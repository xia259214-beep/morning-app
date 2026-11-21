import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'core.dart';
import 'news_slot.dart';
import 'profile.dart';
import 'topics.dart';

/// 一条从网上拿到的新闻。
///
/// 和内置的 [NewsItem] 是两回事：内置那批是写死的示例、没有链接、用来离线兜底；
/// 这个带真实时间、真实出处和原文链接，点开能去原站看。
class Headline {
  final String title;
  final String summary;
  final String url;

  /// 媒体名，如「新浪财经」「IT之家」「环球市场播报」
  final String source;

  /// AI / 股票 / 科技 / 财经 / 社会
  final String channel;

  /// 发布时间（本地时区）
  final DateTime time;

  const Headline({
    required this.title,
    this.summary = '',
    this.url = '',
    this.source = '',
    this.channel = '社会',
    required this.time,
  });

  Map<String, dynamic> toJson() => {
        't': title,
        's': summary,
        'u': url,
        'm': source,
        'c': channel,
        'ts': time.millisecondsSinceEpoch,
      };

  factory Headline.fromJson(Map<String, dynamic> m) => Headline(
        title: (m['t'] ?? '') as String,
        summary: (m['s'] ?? '') as String,
        url: (m['u'] ?? '') as String,
        source: (m['m'] ?? '') as String,
        channel: (m['c'] ?? '社会') as String,
        time: DateTime.fromMillisecondsSinceEpoch(((m['ts'] ?? 0) as num).toInt()),
      );

  /// 小时钟显示：今天只给时分，昨天写「昨天」，更早写日期
  String timeLabel(DateTime now) {
    final sameDay = time.year == now.year && time.month == now.month && time.day == now.day;
    if (sameDay) {
      return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    }
    final y = DateTime(now.year, now.month, now.day).subtract(const Duration(days: 1));
    if (time.year == y.year && time.month == y.month && time.day == y.day) return '昨天';
    return '${time.month}/${time.day}';
  }
}

class EngineResult {
  final List<Headline> items;

  /// 成功拿到内容的源数量
  final int okSources;

  /// 给用户看的一句话原因，空串表示没问题
  final String error;

  const EngineResult(this.items, {this.okSources = 0, this.error = ''});

  bool get isEmpty => items.isEmpty;
}

/// 新闻引擎：抓几个公开的新闻源，去重、分类、打分、缓存。
///
/// 为什么是这三个源：
///   * 新浪的滚动接口是 JSON，字段干净（标题、摘要、时间、媒体名都有），
///     财经和科技两个频道一起拿，股票和 AI 公司的事就都覆盖了；
///   * IT之家 的 RSS 是标准 RSS 2.0，一次 60 条，硬件和产品的事更新最快；
///   * 三者都是公开接口，不含付费墙，只取标题、摘要和原文链接。
///
/// 不做全文转载：这里拿到的是「标题 + 一句话摘要 + 链接」，点开回原站。
/// 这样既不会把别人的正文搬过来，也不至于让用户只能看二手转述。
class NewsEngine {
  /// 「全部」栏的分类。没收「社会」：能稳定拿到内容的社会频道只有新浪体育，
  /// 里面是围棋赛和冲浪板，价值不高，硬凑一个筛选项反而显得这一栏不认真。
  /// 科技和财经本身就已经覆盖了「其他新闻」——IT之家 那一批全是产品和技术。
  static const List<String> channels = ['全部', 'AI', '股票', '科技', '财经'];

  // ---------------------------------------------------------------- 抓取
  static HttpClient _client() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 8)
    ..userAgent = 'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/122.0 Mobile Safari/537.36';

  /// 一次把所有源跑一遍。任何一个源挂掉都不影响其它源——
  /// 这三个站互相没关系，同时挂的概率很低，但单个站抽风很常见。
  static Future<EngineResult> fetch() async {
    final client = _client();
    final out = <Headline>[];
    var ok = 0;
    final failed = <String>[];

    Future<List<Headline>> safe(Future<List<Headline>> f) async {
      try {
        return await f;
      } catch (_) {
        return const <Headline>[];
      }
    }

    try {
      final jobs = <String, Future<List<Headline>>>{
        '新浪科技': safe(_sina(client, 2515, '科技')),
        '新浪财经': safe(_sina(client, 2516, '财经')),
        'IT之家': safe(_ithome(client)),
      };
      for (final e in jobs.entries) {
        final list = await e.value;
        if (list.isEmpty) {
          failed.add(e.key);
        } else {
          ok++;
          out.addAll(list);
        }
      }
    } finally {
      client.close(force: true);
    }

    final now = DateTime.now();
    markTry(now);

    final list = dedupe(out);
    if (list.isEmpty) {
      return const EngineResult(const [],
          okSources: 0, error: '三个源都没连上，可能没网，也可能是站点在维护');
    }
    save(list, now);
    if (failed.isNotEmpty) {
      return EngineResult(list,
          okSources: ok, error: '${failed.join('、')} 这次没抓到，先显示拿到的 ${list.length} 条');
    }
    return EngineResult(list, okSources: ok);
  }

  static Future<List<Headline>> _sina(HttpClient client, int lid, String hint) async {
    final url = 'https://feed.mix.sina.com.cn/api/roll/get'
        '?pageid=153&lid=$lid&num=50&page=1';
    final body = await _get(client, url);
    return parseSina(body, hint: hint);
  }

  static Future<List<Headline>> _ithome(HttpClient client) async {
    final body = await _get(client, 'https://www.ithome.com/rss/');
    return parseRss(body, hint: '科技', source: 'IT之家');
  }

  static Future<String> _get(HttpClient client, String url) async {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.acceptHeader, '*/*');
    final resp = await req.close().timeout(const Duration(seconds: 12));
    if (resp.statusCode != 200) {
      throw HttpException('HTTP ${resp.statusCode}');
    }
    final bytes = await resp.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    // 三个源都是 UTF-8；遇到别的编码宁可丢掉这一批，也不要显示一排乱码
    return utf8.decode(bytes, allowMalformed: true);
  }

  // ---------------------------------------------------------------- 解析
  /// 新浪滚动接口。返回 JSON，格式见 feed.mix.sina.com.cn。
  static List<Headline> parseSina(String body, {String hint = '社会'}) {
    final out = <Headline>[];
    dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return out;
    }
    final data = (decoded is Map && decoded['result'] is Map)
        ? (decoded['result']['data'])
        : null;
    if (data is! List) return out;

    for (final e in data) {
      if (e is! Map) continue;
      final title = (e['title'] ?? '').toString().trim();
      if (title.length < 6) continue;
      final intro = (e['intro'] ?? '').toString().trim();
      final summary = intro.isEmpty ? (e['summary'] ?? '').toString().trim() : intro;
      final media = (e['media_name'] ?? '').toString().trim();
      final sec = int.tryParse('${e['ctime'] ?? ''}') ?? 0;
      out.add(Headline(
        title: _tidy(title),
        summary: _clip(summary),
        url: (e['url'] ?? '').toString(),
        source: media.isEmpty ? '新浪' : media,
        channel: classify(title, hint),
        time: sec > 0
            ? DateTime.fromMillisecondsSinceEpoch(sec * 1000)
            : DateTime.now(),
      ));
    }
    return out;
  }

  /// 标准 RSS 2.0。IT之家 用的是这种。
  static List<Headline> parseRss(String xml, {String hint = '科技', String source = ''}) {
    final out = <Headline>[];
    final re = RegExp(r'<item>([\s\S]*?)</item>');
    for (final m in re.allMatches(xml)) {
      final seg = m.group(1) ?? '';
      final title = _tidy(_tag(seg, 'title'));
      if (title.length < 6) continue;
      final raw = _tag(seg, 'description');
      final link = _tag(seg, 'link');
      final pub = _rfc822(_tag(seg, 'pubDate')) ?? DateTime.now();
      out.add(Headline(
        title: title,
        summary: _clip(_clean(raw)),
        url: link,
        source: source,
        channel: classify(title, hint),
        time: pub,
      ));
    }
    return out;
  }

  static String _tag(String seg, String name) {
    final m = RegExp('<$name[^>]*>([\\s\\S]*?)</$name>').firstMatch(seg);
    return m?.group(1)?.trim() ?? '';
  }

  /// RSS 里的 HTML 转义是真两层：`&lt;p&gt;` 是标签，要先还原再去掉。
  static String _clean(String raw) {
    var s = _unescape(raw);
    s = s.replaceAll(RegExp(r'<[^>]*>'), ' ');
    s = _unescape(s);
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }

  static String _unescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&nbsp;', ' ')
      .replaceAll(RegExp(r'&#\d+;'), '');

  static String _tidy(String s) => _unescape(s).replaceAll(RegExp(r'\s+'), ' ').trim();

  /// 摘要截到一句话。半句截断读起来很别扭，所以尽量停在标点上。
  static String _clip(String s, {int max = 118}) {
    if (s.length <= max) return s;
    var cut = s.substring(0, max);
    final m = RegExp(r'[。！？；，]').allMatches(cut).toList();
    if (m.isNotEmpty) {
      final at = m.last.start;
      if (at > 45) cut = cut.substring(0, at + 1);
    }
    return cut;
  }

  /// "Fri, 20 Nov 2026 16:00:13 GMT" → 本地时间。手写是因为不想为一个
  /// 日期格式引入 intl——这个包里没有第三方依赖，也不打算为这点事开这个口子。
  static DateTime? _rfc822(String s) {
    const months = {
      'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
      'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
    };
    final m = RegExp(r'(\d{1,2})\s+([A-Za-z]{3})[a-z]*\s+(\d{4})\s+'
            r'(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(GMT|UTC|UT|[+-]\d{4})?')
        .firstMatch(s);
    if (m == null) return null;
    final mon = months[m.group(2)!.toLowerCase()];
    if (mon == null) return null;
    final utc = DateTime.utc(
      int.parse(m.group(3)!),
      mon,
      int.parse(m.group(1)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
      int.tryParse(m.group(6) ?? '') ?? 0,
    );
    final zone = m.group(7) ?? 'GMT';
    if (zone.startsWith('+') || zone.startsWith('-')) {
      final sign = zone.startsWith('-') ? -1 : 1;
      final hh = int.tryParse(zone.substring(1, 3)) ?? 0;
      final mm = int.tryParse(zone.substring(3, 5)) ?? 0;
      return utc.subtract(Duration(minutes: sign * (hh * 60 + mm))).toLocal();
    }
    return utc.toLocal();
  }

  // ---------------------------------------------------------------- 分类
  /// 「AI」这个词单独拿出来匹配会误伤一堆英文缩写，所以人工点名过的
  /// 公司和产品全部列出——这些正是用户明确说想看的那几家。
  static const List<String> aiWords = [
    'OpenAI', 'ChatGPT', 'GPT', 'Anthropic', 'Claude', 'Gemini', 'DeepMind',
    'DeepSeek', '深度求索', '豆包', '通义', '千问', 'Qwen', '文心', '一言',
    '混元', '元宝', '腾讯AI', 'Kimi', '月之暗面', '智谱', 'GLM', 'MiniMax',
    '阶跃', '百川', '智元', '宇树', '大模型', '多模态', 'AIGC', 'AGI',
    '智能体', '具身智能', '人工智能', '机器学习', '深度学习', '神经网络',
    '算力', 'GPU', '英伟达', 'NVIDIA', 'Sora', 'Midjourney',
    'AI 芯片', 'AI芯片', 'AI 眼镜', 'AI手机', 'AI 手机', 'AI助手', 'AI 助手',
    '机器人', '自动驾驶', '智能驾驶',
  ];

  static const List<String> stockWords = [
    '股价', '股票', 'A股', '港股', '美股', '涨停', '跌停', '大盘', '券商',
    '基金', 'IPO', '财报', '营收', '净利', '市值', '回购', '减持', '增持',
    '交易所', '沪深', '创业板', '科创板', '北交所', '纳斯达克', '标普',
    '道指', '恒指', '债市', '国债', '比特币', '以太坊', '黄金', '原油',
    '期货', '债券', '汇率', '降准', '降息', '加息', '板块', '龙头',
    '涨超', '跌超', '收涨', '收跌', '盘前', '盘中', '收盘', '开盘', '估值',
  ];

  /// 判定一条新闻属于哪个频道。顺序有讲究：先看 AI，再看股票，
  /// 最后才回落到源频道——「AI 公司股价大涨」这种标题，用户想看的是 AI，
  /// 归到股票里就会被「AI」那个筛选漏掉。
  static String classify(String title, String hint) {
    for (final w in aiWords) {
      if (title.contains(w)) return 'AI';
    }
    for (final w in stockWords) {
      if (title.contains(w)) return '股票';
    }
    return hint;
  }

  // ---------------------------------------------------------------- 去重
  /// 去重用的归一化：把标点、空白、引号全删掉，只比较实词。
  ///
  /// 这里的引号刻意只用全角——之前图省事把 ASCII 单引号也塞进字符类，
  /// 结果单引号在单引号定界的 Dart 字符串里直接把字面量截断，
  /// 拼出来的正则字符类在 `[]` 那一段提前闭合，空格和感叹号全都删不掉，
  /// 于是「降准」和「降准！」被判成两条。这种错不会报错，只会悄悄多出重复项。
  static String _norm(String s) =>
      s.replaceAll(RegExp(r'[\s，。！？、：；"“”‘’（）()\[\]【】|·—-]'), '').toLowerCase();

  static List<Headline> dedupe(List<Headline> list) {
    final seen = <String>{};
    final out = <Headline>[];
    for (final h in list) {
      final k = _norm(h.title);
      if (k.length < 5) continue;
      // 同一件事被两家转，只留先到的；标题前 24 字相同也算重复
      final head = k.length > 24 ? k.substring(0, 24) : k;
      if (!seen.add(k) || !seen.add('#$head')) continue;
      out.add(h);
    }
    out.sort((a, b) => b.time.compareTo(a.time));
    return out;
  }

  // ---------------------------------------------------------------- 打分
  /// 硬新闻：能改变化钱、健康、工作、规则的事
  static const List<String> hardWords = [
    '发布', '上线', '推出', '融资', '收购', '并购', '获批', '签约', '投产',
    '开工', '突破', '首次', '首创', '裁员', '破产', '召回', '事故', '爆炸',
    '地震', '台风', '暴雨', '预警', '政策', '通知', '规定', '条例', '办法',
    '免职', '任免', '降准', '降息', '加息', '关税', '制裁', '禁令', '立案',
    '处罚', '通报', '起诉', '判决', '涨价', '降价', '补贴', '医保', '社保',
  ];

  /// 软新闻：看一眼就过去，不改变任何决定
  static const List<String> softWords = [
    '恋情', '结婚', '离婚', '分手', '穿搭', '星座', '运势', '综艺', '花絮',
    '幕后', '搞笑', '翻车', '塌房', '网红', '直播带货', '颜值', '庆生',
    '婚礼', '生日', '合影', '同框', '晒照', '官宣',
  ];

  /// 新闻本身值不值得看。跟「用户想不想看」分开算，两者最后按权重相加——
  /// 混在一起算的后果是：用户越爱看什么，就越是只给他看什么，最后只剩回音。
  static double valueOf(Headline h, DateTime now) {
    final age = now.difference(h.time).inMinutes;
    var v = NewsSchedule.freshness(age);

    var hard = 0;
    for (final w in hardWords) {
      if (h.title.contains(w)) hard++;
    }
    v += math.min(hard, 4) * 1.1;

    for (final w in softWords) {
      if (h.title.contains(w)) v -= 2.5;
    }

    // 用户明确说过对 AI 公司感兴趣，这一类整体上浮一点
    if (h.channel == 'AI') v += 1.2;
    // 标题党：感叹号、问号堆三个以上的，通常是情绪不是信息
    final bang = RegExp(r'[！!？?]').allMatches(h.title).length;
    if (bang >= 3) v -= 1.5;

    return v;
  }

  /// 跟他的关注点有多贴。
  ///
  /// 直接用主题树的节点标题去匹配新闻标题——这是他答过 3000 多道题换来的东西，
  /// 而且是活的：他今天答了「数控加工」，明天关于数控的新闻就会浮上来，
  /// 不需要谁去维护一张「新闻标签对照表」。层级越深权重越大，因为深层的
  /// 节点才是「他真正懂的那一行」，一级分支太泛。
  static List<({String label, double weight})> personaIndex(Profile p) {
    final tree = TopicTree.instance;
    const generic = {'其他', '综合', '一般', '日常', '通用', '基础'};
    final out = <({String label, double weight})>[];
    p.topicHits.forEach((id, hits) {
      if (hits <= 0) return;
      final node = tree[id];
      if (node == null) return;
      if (node.label.length < 2 || generic.contains(node.label)) return;
      final depthW = math.min(node.depth, 4) / 4.0;
      final evidence = 1 - math.exp(-hits / 2.0);
      out.add((label: node.label, weight: evidence * depthW * 3.4));
    });
    // 跳过最多的那些分支，出现时往下压
    p.topicSkips.forEach((id, sk) {
      if (sk < 2) return;
      final node = tree[id];
      if (node == null) return;
      if (node.label.length < 2 || generic.contains(node.label)) return;
      out.add((label: node.label, weight: -math.min(sk, 3) * 0.9));
    });
    return out;
  }

  static double personaOf(Headline h, List<({String label, double weight})> idx) {
    var s = 0.0;
    for (final e in idx) {
      if (h.title.contains(e.label)) {
        // 标题里出现的比摘要里出现的更算数
        s += e.weight;
      } else if (h.summary.contains(e.label)) {
        s += e.weight * 0.45;
      }
    }
    return s;
  }

  /// 综合排序分：新闻自己的价值 + 跟他的贴近度 × 时段系数
  static double rankScore(
    Headline h,
    List<({String label, double weight})> idx,
    NewsSlot slot,
    DateTime now,
  ) {
    return valueOf(h, now) + personaOf(h, idx) * NewsSchedule.personaFactor(slot);
  }

  /// 定制排序。
  ///
  /// 不用「先分档再排」那种写法：分成「很贴 / 一般 / 不贴」三档之后，
  /// 一条三十小时前、恰好很贴的新闻会压过十分钟前的要闻，而早上那半小时
  /// 只有一次机会。这里靠 [valueOf] 里那个 5 小时半衰的新鲜度控制新旧，
  /// 旧内容自然沉下去，除非它真的跟他高度相关——那种时候压上来是对的。
  static List<Headline> rank(
    List<Headline> list,
    Profile p, {
    required DateTime now,
    NewsSlot? slot,
  }) {
    final s = slot ?? NewsSchedule.slotOf(now);
    final idx = personaIndex(p);
    final factor = NewsSchedule.personaFactor(s);
    final scored = <({Headline h, double score})>[];
    for (final h in list) {
      scored.add((h: h, score: valueOf(h, now) + personaOf(h, idx) * factor));
    }
    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      return b.h.time.compareTo(a.h.time);
    });
    return [for (final e in scored) e.h];
  }

  // ---------------------------------------------------------------- 打散
  /// 聚簇用的实体词。顺序有意义：具体的公司在前，宏观品种在后。
  ///
  /// 真机第一次跑出来就是这个毛病：Anthropic 上市那天，新浪财经连发了六条
  /// 不同角度的稿子——IPO、捐赠、抛售、合作证明——按分数排下来，开屏十五条
  /// 前六条全是同一家公司。分数算得都对，但读起来像刷屏。
  static const List<String> entityWords = [
    'Anthropic', 'OpenAI', 'ChatGPT', 'Claude', 'DeepSeek', 'Sora', 'Gemini',
    '豆包', '通义', '千问', '文心', '混元', '元宝', 'Kimi', '智谱', 'MiniMax',
    '英伟达', 'NVIDIA', '谷歌', '微软', 'Meta', '苹果',
    '特斯拉', 'SpaceX', '华为', '小米', '字节', '腾讯', '阿里', '百度',
    '京东', '美团', '拼多多', '比亚迪',
    '美联储', '鲍威尔', '比特币', '以太坊', '黄金', '原油', '国债',
    'A股', '港股', '美股', '纳指', '标普', '道指',
  ];

  /// 这条新闻属于哪个「话题簇」。认不出实体就退回标题前八个字，
  /// 这样「某地暴雨」这类没有明确主体的也能聚到一起。
  static String topicKey(Headline h) {
    for (final w in entityWords) {
      if (h.title.contains(w)) return w;
    }
    final t = _norm(h.title);
    return t.length >= 8 ? t.substring(0, 8) : t;
  }

  /// 打散：同一个主题最多连着占 [cap] 个位置，剩下的挪到后面。
  ///
  /// 不删。那些仍然是有内容的新闻，只是不该在开屏那十几条里刷六遍；
  /// 挪到后面，用户想往下翻还是能看到。
  static List<Headline> interleave(List<Headline> ranked, {int cap = 2}) {
    final out = <Headline>[];
    final rest = <Headline>[];
    final count = <String, int>{};
    for (final h in ranked) {
      final k = topicKey(h);
      final c = count[k] ?? 0;
      if (c >= cap) {
        rest.add(h);
        continue;
      }
      count[k] = c + 1;
      out.add(h);
    }
    return [...out, ...rest];
  }

  // ---------------------------------------------------------------- 缓存
  static const _keyItems = 'news.v2.items';
  static const _keyOk = 'news.v2.okAt';
  static const _keyTry = 'news.v2.tryAt';

  static void save(List<Headline> items, DateTime at) {
    try {
      final raw = jsonEncode([for (final h in items.take(220)) h.toJson()]);
      Store.set(_keyItems, raw);
      Store.set(_keyOk, at.millisecondsSinceEpoch.toString());
      Store.set(_keyTry, at.millisecondsSinceEpoch.toString());
    } catch (_) {}
  }

  /// 只记「尝试过」。失败也记，免得没网时每次打开都重试一遍。
  static void markTry(DateTime at) {
    Store.set(_keyTry, at.millisecondsSinceEpoch.toString());
  }

  static List<Headline> cached() {
    final raw = Store.s(_keyItems, '');
    if (raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      final out = <Headline>[];
      for (final e in list) {
        try {
          if (e is Map) out.add(Headline.fromJson(Map<String, dynamic>.from(e)));
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  static DateTime? lastOk() => _ts(_keyOk);
  static DateTime? lastTry() => _ts(_keyTry);

  static DateTime? _ts(String key) {
    final ms = int.tryParse(Store.s(key, '')) ?? 0;
    return ms <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  static void clearCache() {
    Store.set(_keyItems, '');
    Store.set(_keyOk, '');
    Store.set(_keyTry, '');
  }
}
