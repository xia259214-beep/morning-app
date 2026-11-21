import 'package:flutter_test/flutter_test.dart';
import 'package:morning/news_engine.dart';
import 'package:morning/news_slot.dart';
import 'package:morning/profile.dart';

/// v1.8.0 的新闻引擎：时段边界、刷新节奏、三个源的解析、分类、去重、
/// 打分与排序。全部用固定时间跑——时间这类东西用 `DateTime.now()`
/// 测，等于没测。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  DateTime at(int h, [int m = 0, int d = 21]) => DateTime(2026, 11, d, h, m);

  group('时段切换', () {
    test('04:59 还在夜里', () {
      expect(NewsSchedule.slotOf(at(4, 59)), NewsSlot.silent);
    });

    test('05:00 开始定制', () {
      expect(NewsSchedule.slotOf(at(5, 0)), NewsSlot.custom);
    });

    test('08:29 仍是定制', () {
      expect(NewsSchedule.slotOf(at(8, 29)), NewsSlot.custom);
    });

    test('08:30 换台，变成日间', () {
      expect(NewsSchedule.slotOf(at(8, 30)), NewsSlot.general);
    });

    test('18:59 还能刷', () {
      expect(NewsSchedule.slotOf(at(18, 59)), NewsSlot.general);
      expect(NewsSchedule.inWindow(at(18, 59)), true);
    });

    test('19:00 停止', () {
      expect(NewsSchedule.slotOf(at(19, 0)), NewsSlot.silent);
      expect(NewsSchedule.inWindow(at(19, 0)), false);
    });

    test('00:00 停止', () {
      expect(NewsSchedule.slotOf(at(0, 0)), NewsSlot.silent);
    });
  });

  group('刷新节奏', () {
    test('夜里不刷', () {
      expect(
        NewsSchedule.shouldFetch(now: at(22, 0), lastTry: at(15, 0)),
        false,
      );
    });

    test('第一次（没有记录）在窗口内就刷', () {
      expect(NewsSchedule.shouldFetch(now: at(6, 0)), true);
    });

    test('距上次不到 5 小时不刷', () {
      // 7:00 还在定制时段，不会触发 8:30 换台补刷，纯粹看间隔
      expect(
        NewsSchedule.shouldFetch(now: at(7, 0), lastTry: at(5, 10), lastOk: at(5, 10)),
        false,
      );
    });

    test('满 5 小时就刷', () {
      expect(
        NewsSchedule.shouldFetch(now: at(16, 0), lastTry: at(11, 0), lastOk: at(11, 0)),
        true,
      );
    });

    test('过了 8:30 但今天还没在 8:30 后刷过，强制补一次', () {
      // 5:00 刷过，8:40 打开：只隔了 3 小时 40 分，但换台了，必须给新的
      expect(
        NewsSchedule.shouldFetch(now: at(8, 40), lastTry: at(5, 0), lastOk: at(5, 0)),
        true,
      );
    });

    test('8:30 之后已经刷过，就不再强刷', () {
      expect(
        NewsSchedule.shouldFetch(now: at(11, 0), lastTry: at(8, 35), lastOk: at(8, 35)),
        false,
      );
    });

    test('夜里 19 点之后即使隔了很久也不刷', () {
      expect(
        NewsSchedule.shouldFetch(now: at(20, 0), lastTry: at(2, 0), lastOk: at(2, 0)),
        false,
      );
    });

    test('状态文字会说清现在属于哪个时段', () {
      expect(NewsSchedule.statusText(at(6, 0)), contains('早间'));
      expect(NewsSchedule.statusText(at(12, 0)), contains('日间'));
      expect(NewsSchedule.statusText(at(21, 0)), contains('不再刷新'));
    });
  });

  group('解析新浪', () {
    // 结构与真实接口一致（feed.mix.sina.com.cn 实际返回的字段）
    const body = '''
{"result":{"status":{"code":0,"msg":"succ"},"data":[
 {"title":"Anthropic是如何抢在OpenAI之前，完成轰动市场IPO的？","intro":"上月旧金山一个晴朗的日子，Anthropic首席财务官向主要投资者介绍最新财务数据。","summary":"","media_name":"环球市场播报","ctime":"1795185220","url":"https://finance.sina.com.cn/a.shtml"},
 {"title":"A股三大指数集体收涨，成交额放大","intro":"沪指涨 0.8%","media_name":"新浪财经","ctime":"1795180000","url":"https://finance.sina.com.cn/b.shtml"},
 {"title":"短","intro":"","media_name":"x","ctime":"1795180000","url":""}
]}}''';

    test('解析出两条，过短的标题被丢掉', () {
      final list = NewsEngine.parseSina(body, hint: '科技');
      expect(list.length, 2);
      expect(list.every((h) => h.title.length >= 6), true);
    });

    test('ctime 是秒，转成本地时间', () {
      final list = NewsEngine.parseSina(body, hint: '科技');
      expect(list.first.time.millisecondsSinceEpoch, 1795185220 * 1000);
    });

    test('媒体名带出来，没有就用「新浪」兜底', () {
      final list = NewsEngine.parseSina(body, hint: '科技');
      expect(list.first.source, '环球市场播报');
    });

    test('坏 JSON 返回空表，不抛异常', () {
      expect(NewsEngine.parseSina('not json at all', hint: '科技'), isEmpty);
      expect(NewsEngine.parseSina('{"result":{}}', hint: '科技'), isEmpty);
    });
  });

  group('解析 RSS', () {
    const xml = '''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"><channel>
<item>
  <title>QQ 鸿蒙版 App 获 9.2.90 邀测升级：新增互动标识</title>
  <description>&lt;p data-vmark="f4ec"&gt;IT之家 11 月 21 日消息，QQ 鸿蒙版 App 昨日开启 &lt;strong&gt;9.2.90&lt;/strong&gt; 邀测升级。&lt;/p&gt;</description>
  <link>https://www.ithome.com/1/030/279.htm</link>
  <pubDate>Fri, 20 Nov 2026 16:00:13 GMT</pubDate>
</item>
<item>
  <title>DeepSeek 发布新版推理模型</title>
  <description>摘要里带 &amp; 符号</description>
  <link>https://www.ithome.com/1/030/280.htm</link>
  <pubDate>Fri, 20 Nov 2026 15:00:00 GMT</pubDate>
</item>
</channel></rss>''';

    test('两条都能解析出来', () {
      final list = NewsEngine.parseRss(xml, hint: '科技', source: 'IT之家');
      expect(list.length, 2);
      expect(list.every((h) => h.source == 'IT之家'), true);
    });

    test('摘要里的 HTML 标签和转义都被清掉', () {
      final h = NewsEngine.parseRss(xml, hint: '科技', source: 'IT之家').first;
      expect(h.summary.contains('<'), false);
      expect(h.summary.contains('&lt;'), false);
      expect(h.summary.contains('data-vmark'), false);
      expect(h.summary, contains('IT之家 11 月 21 日消息'));
    });

    test('实体 &amp; 还原成 &', () {
      final list = NewsEngine.parseRss(xml, hint: '科技', source: 'IT之家');
      expect(list[1].summary, contains('&'));
      expect(list[1].summary, isNot(contains('&amp;')));
    });

    test('GMT 时间按 UTC 解析，转本地时区', () {
      final h = NewsEngine.parseRss(xml, hint: '科技', source: 'IT之家').first;
      expect(h.time.toUtc().hour, 16);
      expect(h.time.toUtc().day, 20);
    });

    test('链接拿到', () {
      final h = NewsEngine.parseRss(xml, hint: '科技', source: 'IT之家').first;
      expect(h.url, 'https://www.ithome.com/1/030/279.htm');
    });
  });

  group('分类', () {
    test('点名过的 AI 公司归到 AI', () {
      for (final t in [
        'OpenAI 发布新一代模型',
        'Anthropic 抢在 OpenAI 之前完成 IPO 路演',
        'DeepSeek 开源新的推理框架',
        '字节豆包日活创新高',
        '腾讯混元开源多模态模型',
        'ChatGPT 新增记忆功能',
      ]) {
        expect(NewsEngine.classify(t, '科技'), 'AI', reason: t);
      }
    });

    test('AI 优先于股票：「AI 公司股价大涨」要能出现在 AI 筛选项里', () {
      expect(NewsEngine.classify('AI 芯片公司股价大涨', '财经'), 'AI');
    });

    test('股票词归到股票', () {
      for (final t in [
        'A股三大指数集体收涨',
        '某公司财报超预期，营收同比增三成',
        '央行宣布降准 0.25 个百分点',
      ]) {
        expect(NewsEngine.classify(t, '财经'), '股票', reason: t);
      }
    });

    test('认不出来就跟着源走', () {
      expect(NewsEngine.classify('某地举办农产品展销会', '社会'), '社会');
      expect(NewsEngine.classify('新款手机开箱', '科技'), '科技');
    });
  });

  group('去重', () {
    test('同一条被两个源转发只留一条', () {
      final t = DateTime(2026, 11, 21, 8);
      final list = [
        Headline(title: '央行宣布降准 0.25 个百分点', time: t),
        Headline(title: '央行宣布降准 0.25 个百分点！', time: t),
        Headline(title: '另一件事完全不同的事情发生', time: t),
      ];
      final out = NewsEngine.dedupe(list);
      expect(out.length, 2);
    });

    test('结果按时间倒序，新的在前', () {
      final list = [
        Headline(title: '早上的事情发生了第一次', time: DateTime(2026, 11, 21, 6)),
        Headline(title: '中午的事情发生了第二次', time: DateTime(2026, 11, 21, 12)),
        Headline(title: '晚上的事情发生了第三次', time: DateTime(2026, 11, 21, 19)),
      ];
      final out = NewsEngine.dedupe(list);
      expect(out.first.title, contains('晚上'));
      expect(out.last.title, contains('早上'));
    });
  });

  group('新闻价值打分', () {
    final now = DateTime(2026, 11, 21, 9);

    test('新的比旧的得分高', () {
      final fresh = Headline(title: '某地发布新的管理办法', time: now.subtract(const Duration(minutes: 10)));
      final old = Headline(title: '某地发布新的管理办法', time: now.subtract(const Duration(hours: 20)));
      expect(NewsEngine.valueOf(fresh, now) > NewsEngine.valueOf(old, now), true);
    });

    test('硬新闻压过软新闻', () {
      final hard = Headline(title: '央行宣布降准，房贷利率下调', time: now.subtract(const Duration(hours: 2)));
      final soft = Headline(title: '某明星官宣恋情，晒出同框照', time: now.subtract(const Duration(hours: 2)));
      expect(NewsEngine.valueOf(hard, now) > NewsEngine.valueOf(soft, now), true);
    });

    test('标题党扣分', () {
      final plain = Headline(title: '某公司发布第三季度财报', time: now);
      final bang = Headline(title: '某公司发布第三季度财报！！！？？？', time: now);
      expect(NewsEngine.valueOf(bang, now) < NewsEngine.valueOf(plain, now), true);
    });
  });

  group('按画像排序', () {
    test('答过「大模型」节点，相关新闻在定制时段浮上来', () {
      final p = Profile(topicHits: {'科技/人工智能/大模型': 6});
      final now = DateTime(2026, 11, 21, 6);
      final list = [
        Headline(title: '某地举办农产品展销会', time: now.subtract(const Duration(minutes: 5))),
        Headline(title: '国产大模型在推理任务上追平国际水平', time: now.subtract(const Duration(minutes: 40))),
      ];
      final ranked = NewsEngine.rank(list, p, now: now, slot: NewsSlot.custom);
      expect(ranked.first.title, contains('大模型'));
    });

    test('同一条新闻，定制时段的贴近度权重比日间高', () {
      final p = Profile(topicHits: {'科技/人工智能/大模型': 6});
      final now = DateTime(2026, 11, 21, 6);
      final idx = NewsEngine.personaIndex(p);
      final h = Headline(title: '国产大模型发布新版本', time: now);
      final custom = NewsEngine.rankScore(h, idx, NewsSlot.custom, now);
      final general = NewsEngine.rankScore(h, idx, NewsSlot.general, now);
      expect(custom > general, true);
    });

    test('空画像也能排，不抛异常', () {
      final now = DateTime(2026, 11, 21, 6);
      final list = [
        Headline(title: '一条普通新闻在这里发生', time: now),
        Headline(title: '另一条普通新闻也发生了', time: now.subtract(const Duration(hours: 1))),
      ];
      final ranked = NewsEngine.rank(list, Profile(), now: now);
      expect(ranked.length, 2);
      // 没有画像时，新的在前
      expect(ranked.first.title, contains('一条普通新闻'));
    });
  });

  group('打散', () {
    final now = DateTime(2026, 11, 21, 9);

    test('认得出实体名', () {
      expect(NewsEngine.topicKey(Headline(title: 'Anthropic 完成 IPO 定价', time: now)), 'Anthropic');
      expect(NewsEngine.topicKey(Headline(title: '央行宣布降准 0.25 个百分点', time: now)), '央行宣布降准0.');
    });

    test('同一家公司连发六条，开屏只占两个位置', () {
      final list = [
        for (var i = 0; i < 6; i++)
          Headline(title: 'Anthropic 第$i条不同角度的消息', time: now.subtract(Duration(minutes: i))),
        Headline(title: 'SpaceX 发射新一代星舰', time: now.subtract(const Duration(minutes: 30))),
        Headline(title: '南方多地进入强降雨期', time: now.subtract(const Duration(minutes: 40))),
      ];
      final out = NewsEngine.interleave(list);
      expect(out.length, list.length, reason: '打散只是挪位置，不能丢条目');
      final head = out.take(4).map(NewsEngine.topicKey).toList();
      expect(head.where((k) => k == 'Anthropic').length, 2);
      expect(head.contains('SpaceX'), true);
    });

    test('不同主题不受影响，顺序保持', () {
      final list = [
        Headline(title: 'Anthropic 完成 IPO 定价', time: now),
        Headline(title: 'SpaceX 发射星舰', time: now),
        Headline(title: '央行宣布降准', time: now),
      ];
      final out = NewsEngine.interleave(list);
      expect(out.map((h) => h.title).toList(), list.map((h) => h.title).toList());
    });
  });

  group('时间显示', () {
    test('今天的只给时分', () {
      final now = DateTime(2026, 11, 21, 20);
      final h = Headline(title: 'x', time: DateTime(2026, 11, 21, 8, 5));
      expect(h.timeLabel(now), '08:05');
    });

    test('昨天写「昨天」', () {
      final now = DateTime(2026, 11, 21, 6);
      final h = Headline(title: 'x', time: DateTime(2026, 11, 20, 23, 0));
      expect(h.timeLabel(now), '昨天');
    });

    test('更早写月日', () {
      final now = DateTime(2026, 11, 21, 6);
      final h = Headline(title: 'x', time: DateTime(2026, 11, 18, 9));
      expect(h.timeLabel(now), '11/18');
    });
  });

  group('json 往返', () {
    test('存进去再读出来字段不丢', () {
      final h = Headline(
        title: '央行宣布降准',
        summary: '释放长期资金',
        url: 'https://example.com/a',
        source: '新浪财经',
        channel: '股票',
        time: DateTime(2026, 11, 21, 9, 30),
      );
      final back = Headline.fromJson(Map<String, dynamic>.from(h.toJson()));
      expect(back.title, h.title);
      expect(back.summary, h.summary);
      expect(back.url, h.url);
      expect(back.source, h.source);
      expect(back.channel, h.channel);
      expect(back.time.millisecondsSinceEpoch, h.time.millisecondsSinceEpoch);
    });
  });
}
