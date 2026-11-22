// ============================================================================
// 晨间播报 · 真实新闻桥接（v1.1.0）
//
// 背景：v1.9.0 之前，晨间流程「播报」那一步用的是 bank.dart 的 todayNews()，
// 也就是包里写死的内置示例。新闻页在 v1.8.0 已经接了真实新闻引擎，
// 但早上那一段一直是老数据——产品四步里「播报打开视野」形同虚设。
//
// 这个文件把新闻页「今日」栏的取数算法抽出来给晨间流程复用，
// 保证：① 播报的是当天真实新闻；② 和新闻页「今日」栏是同一批；
//       ③ 断网 / 没缓存时回落到内置示例，绝不让晨间流程开天窗。
//
// 设计约束（与现有工程一致）：
//   - 零第三方依赖；
//   - 纯读本地缓存，不发网络请求（刷新仍由新闻页的 NewsSchedule 负责）；
//   - 「当天固定」沿用 bank.dart 的思路，避免上午答了几题画像偏移后
//     下午播报的新闻换了一批。
// ============================================================================

import 'dart:convert';

import 'bank.dart' show todayNews;
import 'core.dart' show NewsItem, Store, two;
import 'news_engine.dart' show Headline, NewsEngine;
import 'profile.dart' show Profile;

/// 晨间流程要播报的新闻。
class MorningNews {
  /// 当天选中的真实新闻标题缓存键（与 bank.dart 的 news.* 键区分开）。
  static String _key(DateTime d) => 'morning.realnews.${d.year}-${two(d.month)}-${two(d.day)}';

  /// 最近一次真实新闻的持久化键。
  ///
  /// 用户的原话：「今天没有更新，可以播之前的，直接播新闻就可以，不需要一定要更新的。」
  /// 真实新闻哪怕过期，也比内置示例强——示例一看就是编的，早上听着出戏。
  static const _lastKey = 'morning.lastreal';

  /// 取晨间流程要播报的 3 条。
  ///
  /// 规则：
  ///   1. 一天之内固定：当天选过就记住标题，避免画像漂移导致换新闻；
  ///   2. 有真实缓存且当天缓存命中 → 用真实新闻；
  ///   3. 有真实缓存但当天没选过 → 按新闻页同一算法选前 3 条并记住；
  ///      就算全部超出 36 小时新鲜度也照选（rank 内部会把旧条目排到后面，不是丢弃）；
  ///   4. 完全没有真实缓存（断网 / 从没刷新过）→ 先翻最近一次真实新闻，
  ///      连它都没有才回落内置示例。
  static List<NewsItem> pick(Profile profile, {int count = 3, DateTime? at}) {
    final now = at ?? DateTime.now();
    final heads = NewsEngine.cached();

    // 没有真实数据：先翻「最近一次真实新闻」，宁旧勿假。
    if (heads.isEmpty) {
      final last = _fromLast(count);
      if (last.isNotEmpty) return last;
      return todayNews(profile, at: now);
    }

    // 当天固定：若记住的标题还能在缓存里全部找到，就按记住的顺序返回。
    final saved = Store.s(_key(now), '');
    if (saved.isNotEmpty) {
      final picked = _byTitles(heads, saved.split('\u0001'));
      if (picked.length == count) return picked;
    }

    // 与新闻页「今日」栏同源同算法：画像排序 → 36 小时新鲜度 → 话题打散。
    final ranked = NewsEngine.rank(heads, profile, now: now);
    final fresh = ranked.where((h) => now.difference(h.time).inHours <= 36).toList();
    final src = fresh.length >= 6 ? fresh : ranked;
    final chosen = NewsEngine.interleave(src).take(count).toList();

    // 记住标题，当天不再变；同时持久化最近真实新闻 + 刷新播报文本。
    Store.set(_key(now), chosen.map((h) => h.title).join('\u0001'));
    _rememberLast(chosen);
    _writeSpeech(chosen);
    return [for (final h in chosen) _toItem(h)];
  }

  /// 把挑好的真实新闻落盘：缓存被清 / 断网时晨间播报还能念这批。
  static void _rememberLast(List<Headline> chosen) {
    try {
      Store.set(
        _lastKey,
        jsonEncode([
          for (final h in chosen.take(6))
            {'t': h.title, 'b': h.summary, 's': h.source, 'c': h.channel}
        ]),
      );
    } catch (_) {}
  }

  /// 从「最近一次真实新闻」还原；不足 [count] 条或损坏时返回空。
  static List<NewsItem> _fromLast(int count) {
    final raw = Store.s(_lastKey, '');
    if (raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is! List || list.isEmpty) return const [];
      final out = <NewsItem>[];
      for (final e in list) {
        if (e is! Map) continue;
        final m = Map<String, dynamic>.from(e);
        final title = (m['t'] ?? '').toString();
        final body = (m['b'] ?? '').toString();
        if (title.isEmpty) continue;
        // 摘要同样截到 90 字，和 _toItem 一致
        final text = body.length > 90 ? '${body.substring(0, 90)}…' : body;
        out.add(NewsItem(title, text, (m['s'] ?? '').toString(), (m['c'] ?? '').toString(), ''));
        if (out.length >= count) break;
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// 把播报文本写进 prefs。原生响铃页强制播报念的就是它，
  /// 锁屏冷启动时 Flutter 引擎还没起来，文本必须提前躺在那里。
  static void _writeSpeech(List<Headline> chosen) {
    Store.set(
      'newsSpeech',
      chosen.take(6).map((h) => '${h.title}。${h.summary}').join('\n'),
    );
  }

  /// 新闻页刷新成功后调用：让播报文本跟上最新缓存。
  /// 以前只有走过晨间流程才会写 newsSpeech——如果用户一直没走流程，
  /// 明早锁屏冷启动时原生念的还是上一次流程留下的旧文本。
  static void refreshSpeech(Profile profile) => pick(profile);

  /// 按记住的标题从当前缓存里还原，保持顺序；缺一条就返回空让调用方重选。
  static List<NewsItem> _byTitles(List<Headline> heads, List<String> titles) {
    final out = <NewsItem>[];
    for (final t in titles) {
      Headline? hit;
      for (final h in heads) {
        if (h.title == t) {
          hit = h;
          break;
        }
      }
      if (hit == null) return const [];
      out.add(_toItem(hit));
    }
    return out;
  }

  /// Headline → NewsItem。摘要截断到 90 字，和新闻页 _spokenOf 一致，
  /// 一条一条念清楚，不让早上那段播报拖太长。
  static NewsItem _toItem(Headline h) {
    final body = h.summary.length > 90 ? '${h.summary.substring(0, 90)}…' : h.summary;
    return NewsItem(h.title, body, h.source, h.channel, '');
  }
}
