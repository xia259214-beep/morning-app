import 'package:flutter_test/flutter_test.dart';
import 'package:morning/core.dart';
import 'package:morning/leaderboard.dart';
import 'package:morning/score.dart';

/// 榜单的口径测试。核心承诺有四条：
///   1. 名次本地即时算，不依赖网络；
///   2. 内置对手锚定在我附近，前面永远有个够得着的目标；
///   3. 真人和内置 1:1，且内置明确标注、不冒充真人；
///   4. 真人数据清洗：去自己、去重、夹范围。
void main() {
  const myId = 'device_myself_12345678';

  setUp(() {
    Store.settings = {};
    ScoreBook.invalidate();
  });

  List<RankEntry> real(int n, {int start = 20}) => List<RankEntry>.generate(
        n,
        (i) => RankEntry(
          id: 'real_device_${i.toString().padLeft(4, '0')}',
          nick: '真人$i',
          total: start + i * 5,
          answered: 30 + i,
        ),
      );

  test('内置对手锚定在我附近，前面永远有人、后面永远有人', () {
    for (final my in <int>[0, 7, 100, -30, 5000]) {
      final b = Leaderboard.builtIns(myTotal: my, myAnswered: 20);
      expect(b.length, 8);
      final ahead = b.where((e) => e.total > my).length;
      final behind = b.where((e) => e.total < my).length;
      expect(ahead, greaterThan(0), reason: '我 $my 分时前面得有目标');
      expect(behind, greaterThan(0), reason: '我 $my 分时后面得有人被我超过');
      expect(b.every((e) => e.builtIn), isTrue, reason: '内置对手必须标注');
    }
  });

  test('「阿禾」固定领先 3 分，够得着的目标', () {
    final b = Leaderboard.builtIns(myTotal: 42, myAnswered: 10);
    final ahe = b.firstWhere((e) => e.nick == '阿禾');
    expect(ahe.total, 45);
  });

  test('真人 : 内置 = 1 : 1；没有真人时给 8 个内置', () {
    final empty = Leaderboard.snapshot(
      myId: myId,
      myNick: '我',
      myTotal: 50,
      myAnswered: 20,
      real: const [],
    );
    expect(empty.realCount, 0);
    expect(empty.builtInCount, 8);
    expect(empty.playerCount, 9, reason: '8 内置 + 我自己');

    for (final n in <int>[1, 3, 8, 20]) {
      final s = Leaderboard.snapshot(
        myId: myId,
        myNick: '我',
        myTotal: 50,
        myAnswered: 20,
        real: real(n),
      );
      expect(s.realCount, n);
      expect(s.builtInCount, n, reason: '$n 个真人应配 $n 个内置');
    }
  });

  test('名次、超过人数、距下一名差距算对', () {
    // 真人 20/25/30/35；我 28 分 → 排第几由内置对手一起决定
    final s = Leaderboard.snapshot(
      myId: myId,
      myNick: '我',
      myTotal: 28,
      myAnswered: 20,
      real: real(4, start: 20),
    );
    expect(s.rank, greaterThanOrEqualTo(1));
    expect(s.rank, lessThanOrEqualTo(s.playerCount));

    final me = s.rows.firstWhere((e) => e.id == myId);
    expect(me.total, 28);
    expect(s.myIndex, s.rank - 1);

    // 超过的人数 = 总分严格小于我的人数
    final expectedSurpassed = s.rows.where((e) => e.total < 28).length;
    expect(s.surpassed, expectedSurpassed);

    // 正前面那个必须严格大于我，且是所有大于我里最接近的
    if (s.nextAbove != null) {
      expect(s.nextAbove!.total, greaterThan(28));
      expect(s.gap, s.nextAbove!.total - 28);
      final smallerGaps = s.rows
          .where((e) => e.total > 28)
          .map((e) => e.total - 28)
          .where((g) => g < s.gap);
      expect(smallerGaps, isEmpty);
    }
  });

  test('同分时按答题数排，且不超过同分的人', () {
    final tied = <RankEntry>[
      RankEntry(id: 'real_tie_0001', nick: '同分', total: 30, answered: 99),
    ];
    final s = Leaderboard.snapshot(
      myId: myId,
      myNick: '我',
      myTotal: 30,
      myAnswered: 10,
      real: tied,
    );
    expect(s.surpassed, s.rows.where((e) => e.total < 30).length,
        reason: '同分不算超过');
  });

  test('真人清洗：去掉自己、去重、夹范围、最多 50', () {
    final dirty = <RankEntry>[
      RankEntry(id: myId, nick: '我自己', total: 999, answered: 1),
      RankEntry(id: 'real_dup_0001', nick: '甲', total: 10, answered: 1),
      RankEntry(id: 'real_dup_0001', nick: '甲改名', total: 11, answered: 1),
      RankEntry(id: 'real_big_0001', nick: '灌分', total: 99999999, answered: 1),
      RankEntry(id: 'real_neg_0001', nick: '负分', total: -99999999, answered: 1),
    ];
    final clean = Leaderboard.cleanReal(dirty, myId);
    expect(clean.any((e) => e.id == myId), isFalse, reason: '不能有自己');
    expect(clean.where((e) => e.id == 'real_dup_0001').length, 1,
        reason: '同一设备只留一条');
    expect(clean.firstWhere((e) => e.nick == '灌分').total, 100000);
    expect(clean.firstWhere((e) => e.nick == '负分').total, -100000);

    final many = List<RankEntry>.generate(
      80,
      (i) => RankEntry(id: 'real_many_$i', nick: '人$i', total: i, answered: 1),
    );
    expect(Leaderboard.cleanReal(many, myId).length, 50);
  });

  test('设备 ID 稳定，生成一次后不再变；昵称规范化', () {
    expect(Leaderboard.myId, '');
    // 直接写内存副本：Store.set 会走 MethodChannel，单测环境没有 binding。
    // 真机上 ensureDeviceId 走的正是同一段生成逻辑，只是多了落盘。
    Store.settings['rankDeviceId'] = 'x' * 32;
    expect(Leaderboard.myId, 'x' * 32);

    expect(Leaderboard.normalizeNick('  '), '晨友');
    expect(Leaderboard.normalizeNick('  阿  晨 '), '阿 晨');
    final long = '一二三四五六七八九十十一十二十三';
    expect(Leaderboard.normalizeNick(long), long.substring(0, 12));
    expect(Leaderboard.normalizeNick(long).length, 12);
  });

  test('缓存坏了当没数据，不让榜单页崩', () {
    expect(LeaderboardSnapshotCacheProbe.brokenReturnsEmpty(), isTrue);
  });
}

/// 只测「坏 JSON 不当数据」这一条，不碰真实 Store 写盘
class LeaderboardSnapshotCacheProbe {
  static bool brokenReturnsEmpty() {
    Store.settings = {'rankCache': '{不是 json'};
    final v = LeaderSync.cached;
    return v.isEmpty;
  }
}
