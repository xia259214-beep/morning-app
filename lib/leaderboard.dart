// ============================================================================
// 晨序榜 · 实时名次 + 真人/内置混排（v1.20.0）
//
// 用户在 v1.14.0 的 rank.dart 里已经有一套段位和对拼码，那页明确写着
// 「没有服务器，不编造名次」。这次用户明确要求真人榜，并接受把分数交出去，
// 于是才有了这一层：
//
//   · 自己的名次是**本地实时**算的——每答一道题立刻重排，不需要等网络。
//   · 真人分数从云端拉（几小时一次，可手动刷新），用匿名设备 ID 区分，
//     不做手机号/邮箱账号，用户之前拒绝账号的决定继续保留。
//   · 内置对手的分数锚定在你自己的分数附近：永远有人刚好领先你几分，
//     也永远有人刚被你超过。这是「超过一个人」那份动力的来源，
//     不联网也在。
//   · v1.21.0 起，榜上每一行都写明分数是哪几科挣的（科技 +6 · 体育 +3），
//     只给一个总分看不出谁强在哪。用户也要求去掉行尾那个「内置」小标签，
//     所以改成榜下一行说明：App 自带的陪练角色分数跟着你的水平走，
//     不冒充真人。标签去掉，话不说谎。
//
// 真人 : 内置 = 1 : 1。没有真人时给 8 个内置对手，冷启动榜也不空。
// ============================================================================

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'core.dart';
import 'profile.dart';
import 'score.dart';

/// 榜单里的一行。[builtIn] 为 true 表示这是本机自带的陪练角色，不是真人。
class RankEntry {
  final String id;
  final String nick;
  final int total;
  final int answered;
  final bool builtIn;
  final String city;

  /// 各科得分（科技/体育/文化…），v1.21.0 起才有。
  /// 空表示这个人只报了总分——老版本上报的行、或者还没答过题。
  final Map<String, int> axes;

  const RankEntry({
    required this.id,
    required this.nick,
    required this.total,
    required this.answered,
    this.builtIn = false,
    this.city = '',
    this.axes = const {},
  });

  /// 分科加起来多少分
  int get axisSum => axes.values.fold(0, (a, b) => a + b);

  /// 这一版之前的总分，没分科。绑在总分上，不硬拆成十份。
  int get legacy => total - axisSum;

  Map<String, dynamic> toJson() => {
        'id': id,
        'nick': nick,
        'total': total,
        'answered': answered,
        'builtIn': builtIn,
        'city': city,
        if (axes.isNotEmpty) 'axes': axes,
      };

  factory RankEntry.fromJson(Map<String, dynamic> m) => RankEntry(
        id: (m['id'] ?? '').toString(),
        nick: (m['nick'] ?? '').toString(),
        total: (m['total'] is num) ? (m['total'] as num).round() : 0,
        answered: (m['answered'] is num) ? (m['answered'] as num).round() : 0,
        builtIn: m['builtIn'] == true,
        city: (m['city'] ?? '').toString(),
        axes: _parseAxes(m['axes']),
      );
}

/// 把云端/缓存里那一坨 JSON 收成 {科目: 分数}，脏数据直接丢掉。
Map<String, int> _parseAxes(Object? raw) {
  if (raw is! Map) return const {};
  final out = <String, int>{};
  raw.forEach((k, v) {
    if (v is num && v != 0) out['$k'] = v.toInt();
  });
  return out;
}

/// 名次结果：一屏要用的东西全在这里，页面不需要自己再算一遍。
class LeaderSnapshot {
  /// 这份快照里「自己」的设备 ID。纯函数允许传任意 id，不能写死用当前设备的。
  final String myId;

  /// 按分数降序排好的完整榜单（含自己）
  final List<RankEntry> rows;

  /// 自己的 1 起名次
  final int rank;

  /// 自己超过多少人
  final int surpassed;

  /// 榜单总人数
  final int playerCount;

  /// 正前面那个人（刚好领先你、差距最小），没有则是 null
  final RankEntry? nextAbove;

  /// 距离 [nextAbove] 还差几分
  final int gap;

  /// 真人 / 内置各多少人
  final int realCount;
  final int builtInCount;

  const LeaderSnapshot({
    required this.myId,
    required this.rows,
    required this.rank,
    required this.surpassed,
    required this.playerCount,
    required this.nextAbove,
    required this.gap,
    required this.realCount,
    required this.builtInCount,
  });

  /// 自己那一行在 rows 里的下标
  int get myIndex => rows.indexWhere((e) => e.id == myId);

  /// 一句话摘要，给「我的」页和答题页用
  String get line => '第 $rank 名 · 超过 $surpassed 人';

  String get chaseLine {
    if (nextAbove == null) return '你排在榜首';
    return '再得 $gap 分超过「${nextAbove!.nick}」';
  }
}

/// 内置对手：名字固定，分差锚定在自己附近。
/// 前四个在上方，后四个在下方，保证「抬手就够得着」的目标一直存在。
const List<String> kBuiltInNicks = <String>[
  '阿泽', '小满', '林间', '青禾', '阿禾', '北屿', '山雀', '晚舟',
];

/// 各自相对你总分的偏移。第 5 个「阿禾」= +3，就是概念图里那句
/// 「再得 3 分就超过阿禾」——这个数刻意小，让人觉得下一题就能翻过去。
const List<int> kBuiltInOffsets = <int>[30, 20, 12, 7, 3, -4, -9, -15];

int _offsetAt(int i) {
  if (i < kBuiltInOffsets.length) return kBuiltInOffsets[i];
  final k = i - kBuiltInOffsets.length;
  return k.isEven ? 40 + k * 3 : -20 - k * 3;
}

String _nickAt(int i) =>
    i < kBuiltInNicks.length ? kBuiltInNicks[i] : '晨友${i + 1}';

class Leaderboard {
  /// 伪装成内置对手时的 id 前缀，避免和真人设备 ID 撞车
  static const String builtInPrefix = 'builtin_';

  /// 匿名设备 ID 存在本地设置里，跟着 JSON 备份一起搬家。
  /// 换机后导入备份 = 还是同一个「真人」，不会凭空多出一个名次。
  static String get myId => Store.s('rankDeviceId', '');

  static String ensureDeviceId() {
    final old = Store.s('rankDeviceId', '');
    if (old.length >= 8) return old;
    final r = math.Random.secure();
    final hex = List<int>.generate(16, (_) => r.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    Store.set('rankDeviceId', hex);
    return hex;
  }

  /// 云数据库约束 nick 1~24 字，本地称呼上限 12 字，这里再收一道口。
  static String normalizeNick(String raw) {
    final s = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
    return s.isEmpty ? '晨友' : (s.length > 12 ? s.substring(0, 12) : s);
  }

  /// 生成内置对手。分数 = 我的分数 + 偏移，夹在数据库允许的范围内。
  /// 不存在 SQLite/云端里，每次即时算，所以永远跟得上我的分数。
  static List<RankEntry> builtIns({
    required int myTotal,
    required int myAnswered,
    int count = 8,
  }) {
    final n = count < 0 ? 0 : count;
    return List<RankEntry>.generate(n, (i) {
      final raw = myTotal + _offsetAt(i);
      final total = raw.clamp(-100000, 100000);
      return RankEntry(
        id: '$builtInPrefix${_nickAt(i)}$i',
        nick: _nickAt(i),
        total: total,
        // 内置对手的答题数跟着分数走，看起来才像真人
        answered: (myAnswered + _offsetAt(i) * 3).clamp(0, 1000000),
        builtIn: true,
        axes: splitTotal(_nickAt(i), total),
      );
    });
  }

  /// 把一个总分摊到几科上，加起来正好等于这个总分。
  ///
  /// 榜上每一行都要能对上账：几科相加 = 总分，差一分都会让人怀疑
  /// 整张榜是编的。所以这里用固定权重（5:3:2）+ 余数补最后一科，
  /// 不走浮点分摊。科目按昵称做种子挑——同一行每次刷新挑的还是那几科，
  /// 不会一刷新就换一批。
  static Map<String, int> splitTotal(String nick, int total) {
    if (total == 0) return const {};
    final abs = total.abs();
    final rnd = math.Random(_seedOf(nick));
    final pool = <String>[...kAxes]..shuffle(rnd);
    final n = abs < 4 ? math.min(2, abs) : 3;
    final picks = pool.take(n).toList();
    final fr = n == 2 ? const <double>[0.6, 0.4] : const <double>[0.5, 0.3, 0.2];
    final sign = total < 0 ? -1 : 1;
    final out = <String, int>{};
    var used = 0;
    for (var i = 0; i < n; i++) {
      final part = i == n - 1 ? abs - used : math.max(1, (abs * fr[i]).round());
      out[picks[i]] = part * sign;
      used += part;
    }
    return out;
  }

  static int _seedOf(String s) {
    var h = 7;
    for (final u in s.codeUnits) {
      h = (h * 31 + u) & 0x7FFFFFFF;
    }
    return h;
  }

  /// 真人榜清洗：去掉自己、去重、夹到合理范围、最多 50 人。
  static List<RankEntry> cleanReal(List<RankEntry> raw, String selfId) {
    final seen = <String>{};
    final out = <RankEntry>[];
    for (final e in raw) {
      if (e.id.isEmpty || e.id == selfId || seen.contains(e.id)) continue;
      seen.add(e.id);
      out.add(RankEntry(
        id: e.id,
        nick: normalizeNick(e.nick),
        total: e.total.clamp(-100000, 100000),
        answered: e.answered.clamp(0, 1000000),
        city: e.city,
        axes: e.axes,
      ));
    }
    out.sort((a, b) => a.total.compareTo(b.total));
    return out.length > 50 ? out.sublist(out.length - 50) : out;
  }

  /// 混排 + 算名次。这是纯函数：同样的输入一定得到同样的名次，
  /// 所以答题判分后可以立刻调用，不必等任何网络请求。
  static LeaderSnapshot snapshot({
    required String myId,
    required String myNick,
    required int myTotal,
    required int myAnswered,
    required List<RankEntry> real,
    String myCity = '',
    Map<String, int> myAxes = const {},
  }) {
    final reals = cleanReal(real, myId);
    // 真人有几个就配几个内置对手；一个真人都没有时给 8 个，冷启动榜不空。
    final builtInCount = reals.isEmpty ? 8 : reals.length;
    final built = builtIns(
      myTotal: myTotal,
      myAnswered: myAnswered,
      count: builtInCount,
    );

    final me = RankEntry(
      id: myId,
      nick: normalizeNick(myNick),
      total: myTotal.clamp(-100000, 100000),
      answered: myAnswered.clamp(0, 1000000),
      city: myCity,
      axes: myAxes,
    );

    final rows = <RankEntry>[...reals, ...built, me];
    rows.sort((a, b) {
      final c = b.total.compareTo(a.total);
      if (c != 0) return c;
      final a2 = b.answered.compareTo(a.answered);
      if (a2 != 0) return a2;
      return a.nick.compareTo(b.nick);
    });

    final idx = rows.indexWhere((e) => e.id == myId);
    final rank = idx + 1;
    // 名次相同（同分同答题数）时按并列算，避免「超过了自己前面那个同分的人」
    // 这种说不通的提示。
    var surpassed = 0;
    for (final e in rows) {
      if (e.id == myId) continue;
      if (e.total < me.total) surpassed++;
    }
    RankEntry? above;
    var gap = 0;
    for (var i = idx - 1; i >= 0; i--) {
      if (rows[i].total > me.total) {
        above = rows[i];
        gap = rows[i].total - me.total;
        break;
      }
    }

    return LeaderSnapshot(
      myId: myId,
      rows: rows,
      rank: rank,
      surpassed: surpassed,
      playerCount: rows.length,
      nextAbove: above,
      gap: gap,
      realCount: reals.length,
      builtInCount: built.length,
    );
  }

  /// 页面直接用当前状态算一份本地快照（不等网络）
  static LeaderSnapshot localNow({List<RankEntry> real = const []}) {
    final s = ScoreBook.instance;
    final city = Store.s('cityName', '');
    return snapshot(
      myId: myId.isEmpty ? ensureDeviceId() : myId,
      myNick: Store.s('nick', ''),
      myTotal: s.total,
      myAnswered: s.answered,
      real: real,
      myCity: city,
      myAxes: s.byAxis,
    );
  }
}

/// 真人榜的云端读写。
///
/// 为什么不是官方 SDK：它只发布 JS / 小程序版，这个 App 是零第三方依赖的
/// Flutter，没有 Dart 版可接。数据面是标准 PostgREST，用项目现成的
/// `dart:io HttpClient` 直连即可。下面两个值是云服务返回的**公开配置**
/// （publishableKey 本身不带权限，服务端按来源校验），可以随 App 发布；
/// endpoint 是这个函数所属应用的固定域名，不存在「重新发布会失效」的问题。
class LeaderSync {
  static const String endpoint = 'https://morning-rank.app.workbuddy.host';
  static const String publishableKey =
      'wbpk_orbTScPbe7o7jxfIQylpc4_WQoSRxJSqT0EOkl4ucufYNSDJIc7nq8I';
  static const String _path = '/.cloud/database/rest/morning_scores';

  /// 真人榜总开关。用户当年选过「数据不上传、不联网也能用」，
  /// 这次要真人榜等于同意上报分数，但随时可以在设置里关掉。
  static bool get enabled => Store.s('rankOnline', '1') != '0';
  static set enabled(bool v) => Store.set('rankOnline', v ? '1' : '0');

  /// 几小时拉一次；答题后自己那份是本地即时重排，不依赖这个间隔。
  static const Duration refreshInterval = Duration(hours: 3);

  static int get _lastPullMs {
    final v = int.tryParse(Store.s('rankPulledAt', ''));
    return v ?? 0;
  }

  static bool get dueForPull {
    final last = _lastPullMs;
    if (last <= 0) return true;
    return DateTime.now().millisecondsSinceEpoch - last >=
        refreshInterval.inMilliseconds;
  }

  static void _markPulled() =>
      Store.set('rankPulledAt', '${DateTime.now().millisecondsSinceEpoch}');

  /// 上次成功拉到的真人榜。网络失败时页面用它兜底，不闪空白。
  static List<RankEntry> get cached {
    final raw = Store.s('rankCache', '');
    if (raw.isEmpty) return const [];
    try {
      final d = jsonDecode(raw);
      if (d is! List) return const [];
      return d
          .whereType<Map>()
          .map((m) => RankEntry.fromJson(Map<String, dynamic>.from(m)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> _saveCache(List<RankEntry> rows) async {
    Store.set(
      'rankCache',
      jsonEncode(rows.map((e) => e.toJson()).toList(growable: false)),
    );
    await Store.saveSettings();
  }

  static HttpClient _client(Duration timeout) =>
      HttpClient()..connectionTimeout = timeout;

  static void _auth(HttpClientRequest req) {
    req.headers.set('x-wb-webapp-access-key', publishableKey);
  }

  /// 上报自己的分数。用 upsert：同一设备 ID 只更新一行，不会越用越多。
  /// 失败静默（这是激励功能，不该打断答题），由调用方决定是否提示。
  static Future<bool> upload({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (!enabled) return false;
    final id = Leaderboard.ensureDeviceId();
    final s = ScoreBook.instance;
    final body = jsonEncode([
      {
        'device_id': id,
        'nick': Leaderboard.normalizeNick(Store.s('nick', '')),
        'total': s.total.clamp(-100000, 100000),
        'right_cnt': s.right.clamp(0, 1000000),
        'wrong_cnt': s.wrong.clamp(0, 1000000),
        'answered': s.answered.clamp(0, 1000000),
        'city': Store.s('cityName', ''),
        // 各科得分（v1.21.0）。榜上那一行要显示「科技 +6 · 体育 +3」，
        // 就得把分科也一起报上来；空对象表示只报总分。
        'axes': s.byAxis,
        'app_version': kAppVersion,
      },
    ]);
    HttpClient? client;
    try {
      client = _client(timeout);
      final req = await client
          .postUrl(Uri.parse('$endpoint$_path'))
          .timeout(timeout);
      _auth(req);
      req.headers.set('Content-Type', 'application/json');
      // merge-duplicates = 按主键 device_id 更新，冲突不报错
      req.headers.set('Prefer', 'resolution=merge-duplicates,return=minimal');
      // req.write() 走 Latin-1，中文昵称（默认「晨友」）会抛
      // "Contains invalid characters"。必须显式按 UTF-8 编码字节写。
      req.add(utf8.encode(body));
      final res = await req.close().timeout(timeout);
      await res.drain<void>();
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    } finally {
      client?.close();
    }
  }

  /// 拉真人榜。返回 null 表示失败（调用方继续用缓存），空列表表示真的没人。
  static Future<List<RankEntry>?> pull({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (!enabled) return null;
    HttpClient? client;
    try {
      client = _client(timeout);
      final uri = Uri.parse(
        '$endpoint$_path?select=device_id,nick,total,right_cnt,wrong_cnt,answered,city,axes,updated_at&order=total.desc&limit=50',
      );
      final req = await client.getUrl(uri).timeout(timeout);
      _auth(req);
      final res = await req.close().timeout(timeout);
      final text = await utf8.decoder.bind(res).join();
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final d = jsonDecode(text);
      if (d is! List) return null;
      final rows = d
          .whereType<Map>()
          .map((m) {
            final q = Map<String, dynamic>.from(m);
            return RankEntry(
              id: (q['device_id'] ?? '').toString(),
              nick: (q['nick'] ?? '').toString(),
              total: (q['total'] is num) ? (q['total'] as num).round() : 0,
              answered: (q['answered'] is num)
                  ? (q['answered'] as num).round()
                  : 0,
              city: (q['city'] ?? '').toString(),
              axes: _parseAxes(q['axes']),
            );
          })
          .where((e) => e.id.isNotEmpty)
          .toList();
      await _saveCache(rows);
      _markPulled();
      return rows;
    } catch (_) {
      return null;
    } finally {
      client?.close();
    }
  }
}
