import 'package:flutter_test/flutter_test.dart';
import 'package:morning/bank.dart';
import 'package:morning/core.dart';

/// 新闻选取的两条硬要求：
///   1. 同一天必须稳定。播报里念的三条，和「新闻」板块里看到的三条，
///      不能因为中途答了几道题就换一批——那是同一个「今天的新闻」。
///   2. 换一天要换一批，否则这个板块永远是同一页，没有「今天」的意义。
void main() {
  // todayNews 会把当天结果写进 settings，走的是 Bridge.setPref（MethodChannel），
  // 没有 binding 会直接抛 "Binding has not yet been initialized"。
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    Store.settings = {};
    Store.records = [];
  });

  final p = Profile();

  test('同一天多次调用返回同一批，且顺序一致', () {
    final day = DateTime(2026, 11, 20, 7, 30);
    final a = todayNews(p, at: day);
    final b = todayNews(p, at: DateTime(2026, 11, 20, 21, 5));

    expect(a.length, 3);
    expect(b.map((e) => e.title).toList(), a.map((e) => e.title).toList());
  });

  test('答题改变画像之后，当天的新闻仍然不变', () {
    final day = DateTime(2026, 11, 20, 7, 30);
    final before = todayNews(p, at: day);

    // 模拟答完一轮题：把「军事」权重和置信度都拉满
    p.score['军事'] = 10.0;
    p.hits['军事'] = 20;

    final after = todayNews(p, at: day);
    expect(after.map((e) => e.title).toList(), before.map((e) => e.title).toList());
  });

  test('换一天会换一批（至少不是每天完全一样）', () {
    // 连看 10 天，只要出现过不同的组合就算过。
    // 不写成「每两天必须不同」：题库里同领域的组合有可能真的撞上。
    final seen = <String>{};
    for (var i = 0; i < 10; i++) {
      final list = todayNews(p, at: DateTime(2026, 11, 1).add(Duration(days: i)));
      seen.add(list.map((e) => e.title).join('|'));
    }
    expect(seen.length, greaterThan(1));
  });

  test('缓存只留最近 7 天，不无限增长', () {
    for (var i = 0; i < 20; i++) {
      todayNews(p, at: DateTime(2026, 11, 1).add(Duration(days: i)));
    }
    final keys = Store.settings.keys.where((k) => k.startsWith('news.')).toList();
    expect(keys.length, lessThanOrEqualTo(7));
  });

  test('缓存里的标题对不上题库时重新挑，不返回残缺结果', () {
    final day = DateTime(2026, 11, 20, 8);
    todayNews(p, at: day);

    // 手动改坏缓存：模拟题库换版、标题改了字
    final key = Store.settings.keys.firstWhere((k) => k.startsWith('news.'));
    Store.settings[key] = '已经不存在的标题\u0001另一条\u0001第三条';

    final list = todayNews(p, at: day);
    expect(list.length, 3);
    expect(list.any((e) => e.title.contains('已经不存在的标题')), false);
  });
}
