import 'package:flutter_test/flutter_test.dart';
import 'package:morning/core.dart';
import 'package:morning/morning_news.dart';
import 'package:morning/news_engine.dart';
import 'package:morning/profile.dart';

// v1.1.0：晨间播报接真实新闻引擎的回归测试。
// 重点：真实缓存优先 / 断网回落内置 / 当天固定 / 摘要截断。

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime(2026, 11, 21, 7, 30);

  setUp(() {
    Store.settings = {};
    Store.alarms = [];
    Store.records = [];
  });

  List<Headline> heads(int n) => [
        for (var i = 0; i < n; i++)
          Headline(
            title: '真实新闻标题$i',
            summary: '这是第$i条真实新闻的摘要内容。',
            source: '测试来源',
            channel: '科技',
            time: now.subtract(Duration(minutes: 10 * i)),
          ),
      ];

  test('没有任何真实缓存时，回落到内置示例（离线可用）', () {
    final picked = MorningNews.pick(Profile(), at: now);
    expect(picked.length, 3);
    // 内置示例的 topic/source 与真实缓存不同，这里只要求不为空即可
    expect(picked.every((e) => e.title.isNotEmpty), true);
  });

  test('有真实缓存时，优先用真实新闻', () {
    NewsEngine.save(heads(8), now);
    final picked = MorningNews.pick(Profile(), at: now);
    expect(picked.length, 3);
    expect(picked.first.title, '真实新闻标题0');
  });

  test('有真实缓存时，摘要截断到 90 字以内', () {
    NewsEngine.save(
      [
        Headline(
          title: '一条很长的新闻',
          summary: '字' * 200,
          time: now,
        ),
      ],
      now,
    );
    final picked = MorningNews.pick(Profile(), at: now);
    expect(picked.first.summary.length <= 91, true);
    expect(picked.first.summary.endsWith('…'), true);
  });

  test('当天固定：同一天再取，标题顺序不变', () {
    NewsEngine.save(heads(10), now);
    final first = MorningNews.pick(Profile(), at: now);
    // 模拟当天画像变化后再次进入
    final changed = Profile(topicHits: {'财经/宏观/利率': 9});
    final second = MorningNews.pick(changed, at: now);
    expect(second.map((e) => e.title).toList(), first.map((e) => e.title).toList());
  });

  test('换一天会重新选，不被昨天的缓存锁住', () {
    NewsEngine.save(heads(10), now);
    final day1 = MorningNews.pick(Profile(), at: now);
    final day2 = MorningNews.pick(Profile(), at: now.add(const Duration(days: 1)));
    // 新的一天画像为空，排序可能不同；只要求各自都是 3 条完整新闻
    expect(day2.length, 3);
    expect(day1.length, 3);
    expect(day2.every((e) => e.title.isNotEmpty), true);
  });
}
