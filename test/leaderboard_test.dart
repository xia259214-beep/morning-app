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

  test('陪练锚定在我附近：低分时前面有人、后面有人', () {
    for (final my in <int>[0, 7, 30, -30]) {
      final b = Leaderboard.builtIns(myTotal: my, myAnswered: 20);
      expect(b.length, 8);
      final ahead = b.where((e) => e.total > my).length;
      final behind = b.where((e) => e.total < my).length;
      expect(ahead, greaterThan(0), reason: '我 $my 分时前面得有目标');
      expect(behind, greaterThan(0), reason: '我 $my 分时后面得有人被我超过');
      expect(b.every((e) => e.builtIn), isTrue, reason: '内置对手必须标注');
    }
  });

  test('陪练有水平上限，答到 60 分就能坐上第一', () {
    // 没有上限的话他们永远 +30，第一名永远追不到
    for (final my in <int>[60, 61, 100, 5000]) {
      final b = Leaderboard.builtIns(myTotal: my, myAnswered: 200);
      expect(b.any((e) => e.total > my), isFalse,
          reason: '我 $my 分时不该还有人压在前面');
    }
    for (final i in <int>[0, 3, 7]) {
      final b = Leaderboard.builtIns(myTotal: 5000, myAnswered: 200);
      expect(b[i].total, lessThanOrEqualTo(60), reason: '陪练不该无限涨');
    }
    // 低分时上限不该插手：0 分时第一名还是 30
    final low = Leaderboard.builtIns(myTotal: 0, myAnswered: 0);
    expect(low.first.total, 30);
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

  // ---- v1.21.0：榜上每一行都要说清分数是哪几科挣的 ----

  test('分科明细加起来正好等于总分，正负都算', () {
    for (final t in <int>[-40, -7, -1, 0, 1, 3, 4, 9, 47, 300]) {
      final axes = Leaderboard.splitTotal('阿泽', t);
      final sum = axes.values.fold(0, (a, b) => a + b);
      expect(sum, t, reason: '总分 $t 摊出来的分科必须对得上账');
      expect(axes.values.every((v) => v != 0), isTrue, reason: '别摆 0 分的科目');
    }
  });

  test('同一行每次刷新分科不变；不同人的科目组合不一样', () {
    final a1 = Leaderboard.splitTotal('小满', 100);
    final a2 = Leaderboard.splitTotal('小满', 100);
    expect(a1, a2, reason: '刷新一次换一批科目，看着就像现编的');

    final combos = <String>{};
    for (final n in kBuiltInNicks) {
      combos.add((Leaderboard.splitTotal(n, 100).keys.toList()..sort()).join(','));
    }
    expect(combos.length, greaterThan(1), reason: '八个人不该都是同样三科');
  });

  test('陪练角色的行都带分科，且总分对得上', () {
    final rows = Leaderboard.builtIns(myTotal: 42, myAnswered: 20);
    for (final e in rows) {
      expect(e.axes, isNotEmpty);
      expect(e.axisSum, e.total);
      expect(e.legacy, 0, reason: '陪练没有往期账');
    }
  });

  test('自己那一行带自己的分科', () {
    final s = Leaderboard.snapshot(
      myId: myId,
      myNick: '我',
      myTotal: 9,
      myAnswered: 12,
      myAxes: const {'科技': 6, '体育': 3},
      real: const [],
    );
    final me = s.rows.firstWhere((e) => e.id == myId);
    expect(me.axes['科技'], 6);
    expect(me.axisSum, me.total);
    expect(me.legacy, 0);
  });

  test('只报了总分的真人：分科为空，多出来的算往期', () {
    final s = Leaderboard.snapshot(
      myId: myId,
      myNick: '我',
      myTotal: 0,
      myAnswered: 0,
      real: <RankEntry>[
        RankEntry(id: 'real_old_0001', nick: '老版本', total: 12, answered: 12),
      ],
    );
    final old = s.rows.firstWhere((e) => e.nick == '老版本');
    expect(old.axes, isEmpty);
    expect(old.legacy, 12, reason: '没分科的分要认成往期，不能凭空拆开');
  });

  test('自己那一行带对/错计数：净分一样，来历不一样', () {
    final s = Leaderboard.snapshot(
      myId: myId,
      myNick: '我',
      myTotal: 5,
      myAnswered: 200,
      myRight: 105,
      myWrong: 166,
      real: const <RankEntry>[],
    );
    final me = s.rows.firstWhere((e) => e.id == myId);
    expect(me.rightCnt, 105);
    expect(me.wrongCnt, 166,
        reason: '答错的道数必须显示出来，只看净分会把「错很多」的人藏起来');
  });

  test('云端行的对/错计数能原样带进来', () {
    final e = RankEntry.fromJson(<String, dynamic>{
      'id': 'd1',
      'nick': '阿满',
      'total': 9,
      'answered': 15,
      'rightCnt': 12,
      'wrongCnt': 3,
    });
    expect(e.rightCnt, 12);
    expect(e.wrongCnt, 3);
    // 老缓存没有这两个字段，不能因此崩掉
    final old = RankEntry.fromJson(<String, dynamic>{'id': 'd2', 'total': 3});
    expect(old.rightCnt, 0);
    expect(old.wrongCnt, 0);
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
