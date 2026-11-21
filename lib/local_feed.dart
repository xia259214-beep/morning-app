import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'core.dart';
import 'region.dart';

/// 一条本地资讯。标题和链接都是官方站上抓来的原文，不做改写。
class FeedItem {
  final String title;
  final String url;

  /// 栏目：要闻 / 部门 / 镇村 / 公告
  final String col;

  /// 原文发布日期，形如 2026-11-20；抓不到就空着
  final String date;

  const FeedItem(this.title, this.url, this.col, this.date);

  /// 是不是「人事 / 招聘」这一类。政府站很少单开一个人事栏目，
  /// 任前公示、任职通知、招聘公告大多混在公告里，所以按标题词判断。
  ///
  /// 这里刻意不收「公示」两个字：县里最常见的公示是项目验收和资金分配，
  /// 拿「公示」当人事的关键词，一屏里能错标一半（v1.6.0 真机上就是这个结果）。
  bool get isPersonnel {
    const keys = [
      '任免', '任职', '免职', '任前公示', '拟任', '拟聘', '聘任', '干部',
      '人事', '招聘', '招录', '录用', '选调', '选聘', '考察对象', '任职前',
    ];
    return keys.any(title.contains);
  }

  Map<String, String> toJson() => {'t': title, 'u': url, 'c': col, 'd': date};

  factory FeedItem.fromJson(Map<String, dynamic> m) => FeedItem(
        (m['t'] ?? '') as String,
        (m['u'] ?? '') as String,
        (m['c'] ?? '') as String,
        (m['d'] ?? '') as String,
      );
}

class FeedResult {
  final List<FeedItem> items;

  /// 空串 = 成功；否则是给用户看的一句话原因
  final String error;

  /// 这些是从本机缓存里拿的（没联网 / 联网失败）
  final bool cached;

  const FeedResult(this.items, {this.error = '', this.cached = false});

  bool get ok => error.isEmpty;
}

/// 抓本地资讯。
///
/// 这里有一个刻意的取舍：**只有用户点「联网刷新」才联网**，其它任何时候 App 都不发请求。
/// 一个闹钟应用偷偷往外发数据，是很难解释的事；而要拿到真实的县里新闻，
/// 联网又是唯一的办法。折中就是「你说刷新我才去拿，拿完存在本机，下次离线也能看」。
class LocalFeed {
  /// 栏目和它的列表页。顺序即页面上的顺序：先县里的大事，再部门、镇村，最后公告。
  static const Map<String, String> columns = {
    '要闻': 'https://www.nlx.gov.cn/xwzx/jrnl/index.html',
    '部门': 'https://www.nlx.gov.cn/xwzx/bmdt/index.html',
    '镇村': 'https://www.nlx.gov.cn/xwzx/zckx/index.html',
    '公告': 'https://www.nlx.gov.cn/xwzx/tzgg/index.html',
  };

  /// 当前地区有没有接上自动抓取。目前只接了南陵县。
  static bool supports(Region r) => r.isNanling;

  /// 抓全站。任何一个栏目失败都不影响其它栏目——县里网站偶尔抽风很常见。
  static Future<FeedResult> fetch({Region? region}) async {
    final r = region ?? Region.current;
    if (!supports(r)) {
      return const FeedResult([], error: '只有南陵县接了自动抓取，其它地区请用下方的官方渠道');
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..userAgent = 'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';

    final out = <FeedItem>[];
    var fail = 0;
    try {
      for (final e in columns.entries) {
        try {
          final list = await _oneColumn(client, e.key, e.value);
          if (list.isEmpty) fail++;
          out.addAll(list);
        } catch (_) {
          fail++;
        }
      }
    } finally {
      client.close(force: true);
    }

    if (out.isEmpty) {
      return const FeedResult([], error: '连不上县政府网站，可能没网，也可能站点在维护');
    }
    final res = FeedResult(out);
    // 只缓存成功的结果，别把半份空表写进去把上次的好数据覆盖掉
    _save(out);
    if (fail > 0) {
      return FeedResult(out, error: '有 $fail 个栏目这次没抓到，先显示拿到的这些');
    }
    return res;
  }

  static Future<List<FeedItem>> _oneColumn(HttpClient client, String col, String url) async {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.acceptHeader, 'text/html');
    final resp = await req.close().timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) return const [];
    final bytes = await resp.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    // 政府站这两年基本都是 UTF-8；万一遇到老 GBK 页，宁可丢掉也不要出乱码
    final html = utf8.decode(bytes, allowMalformed: true);
    return parseColumn(html, col, _colPath(url));
  }

  /// 从列表页 HTML 里抽条目标题。抽出来单独放着，是为了能在单元测试里
  /// 拿一段真实结构跑一遍——正则这东西，不拿真页面验证等于没写。
  static List<FeedItem> parseColumn(String html, String col, String colPath) {
    final out = <FeedItem>[];
    final seen = <String>{};
    // 列表项形态：<a href="…" title="标题" class="left">…</a><span class="right date">2026-11-20</span>
    final re = RegExp(r'<a\b[^>]*href="(https?://[^"]+)"[^>]*>[\s\S]{0,400}?</a>\s*'
        r'(?:<span[^>]*class="[^"]*date[^"]*"[^>]*>([\d-]{8,10})</span>)?');
    for (final m in re.allMatches(html)) {
      final u = m.group(1) ?? '';
      if (colPath.isNotEmpty && !u.contains('/$colPath')) continue;
      // title 属性比 <span> 里的干净，优先用它
      final seg = m.group(0) ?? '';
      final tm = RegExp(r'title="([^"]{6,})"').firstMatch(seg);
      var title = tm?.group(1) ?? '';
      if (title.isEmpty) title = _stripTags(seg);
      title = _unescape(title).trim();
      if (title.length < 6) continue;
      if (!seen.add(u)) continue;
      out.add(FeedItem(title, u, col, m.group(2) ?? ''));
      if (out.length >= 12) break;
    }
    return out;
  }

  /// /xwzx/jrnl/index.html → "jrnl"
  static String _colPath(String url) {
    final parts = Uri.parse(url).pathSegments;
    return parts.length >= 2 ? parts[parts.length - 2] : '';
  }

  static String _stripTags(String s) =>
      s.replaceAll(RegExp(r'<[^>]*>'), ' ').replaceAll(RegExp(r'\s+'), ' ');

  static String _unescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&nbsp;', ' ')
      .replaceAll(RegExp(r'&#(\d+);'), '');

  // ---------------------------------------------------------------- 缓存
  static const _keyItems = 'local.feed';
  static const _keyAt = 'local.feedAt';

  static void _save(List<FeedItem> items) {
    try {
      final raw = jsonEncode([for (final i in items.take(60)) i.toJson()]);
      Store.set(_keyItems, raw);
      Store.set(_keyAt, DateTime.now().millisecondsSinceEpoch.toString());
    } catch (_) {}
  }

  /// 上次抓到的内容。没网的时候，本地那一栏不该是空白。
  static FeedResult cached() {
    final raw = Store.s(_keyItems, '');
    if (raw.isEmpty) return const FeedResult([], error: '还没有拉过本地资讯');
    try {
      final list = jsonDecode(raw);
      final items = <FeedItem>[];
      if (list is List) {
        for (final e in list) {
          try {
            if (e is Map) items.add(FeedItem.fromJson(Map<String, dynamic>.from(e)));
          } catch (_) {}
        }
      }
      return FeedResult(items, cached: true);
    } catch (_) {
      return const FeedResult([], error: '本地缓存坏了，重新拉一次就好');
    }
  }

  /// 「十二分钟前」这种人话时间
  static String agoLabel() {
    final raw = Store.s(_keyAt, '');
    final ms = int.tryParse(raw) ?? 0;
    if (ms <= 0) return '';
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (d.inMinutes < 1) return '刚刚更新';
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟前更新';
    if (d.inHours < 24) return '${d.inHours} 小时前更新';
    return '${d.inDays} 天前更新';
  }
}
