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
// v1.22.4 起全榜（含我）至少 20 人：19 份陪练档案各有各的城市、肝度和画风；
// 真人多时陪练按 1:1 跟涨。冷启动榜也不空。
// ============================================================================

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'core.dart';
import 'profile.dart';
import 'score.dart';

/// 榜单里的一行。[builtIn] 为 true 表示这是本机自带的陪练角色，不是真人。
/// v1.22.3 起总分和分科都是小数（答题账本记 1.35 这种分值）。
class RankEntry {
  final String id;
  final String nick;
  final double total;
  final int answered;
  final bool builtIn;
  final String city;

  /// 各科得分（科技/体育/文化…），v1.21.0 起才有。
  /// 空表示这个人只报了总分——老版本上报的行、或者还没答过题。
  final Map<String, double> axes;

  /// 答对 / 答错各多少道（v1.21.4）。
  /// 只记净分的话，一个「答对 100、答错 95」的人看起来和「答对 5、答错 0」
  /// 一模一样；把两边都摆出来，「这 5 分是怎么来的」才说得清。
  final int rightCnt;
  final int wrongCnt;

  const RankEntry({
    required this.id,
    required this.nick,
    required this.total,
    required this.answered,
    this.builtIn = false,
    this.city = '',
    this.axes = const {},
    this.rightCnt = 0,
    this.wrongCnt = 0,
  });

  /// 分科加起来多少分
  double get axisSum => axes.values.fold(0.0, (a, b) => a + b);

  /// 这一版之前的总分，没分科。绑在总分上，不硬拆成十份。
  double get legacy => total - axisSum;

  Map<String, dynamic> toJson() => {
        'id': id,
        'nick': nick,
        'total': total,
        'answered': answered,
        'builtIn': builtIn,
        'city': city,
        'rightCnt': rightCnt,
        'wrongCnt': wrongCnt,
        if (axes.isNotEmpty) 'axes': axes,
      };

  factory RankEntry.fromJson(Map<String, dynamic> m) => RankEntry(
        id: (m['id'] ?? '').toString(),
        nick: (m['nick'] ?? '').toString(),
        total: (m['total'] is num) ? (m['total'] as num).toDouble() : 0,
        answered: (m['answered'] is num) ? (m['answered'] as num).round() : 0,
        builtIn: m['builtIn'] == true,
        city: (m['city'] ?? '').toString(),
        axes: _parseAxes(m['axes']),
        rightCnt: (m['rightCnt'] is num) ? (m['rightCnt'] as num).round() : 0,
        wrongCnt: (m['wrongCnt'] is num) ? (m['wrongCnt'] as num).round() : 0,
      );
}

/// 把云端/缓存里那一坨 JSON 收成 {科目: 分数}，脏数据直接丢掉。
Map<String, double> _parseAxes(Object? raw) {
  if (raw is! Map) return const {};
  final out = <String, double>{};
  raw.forEach((k, v) {
    if (v is num && v != 0) out['$k'] = (v as num).toDouble();
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
  final double gap;

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
    return '再得 ${ScoreBook.fmt(gap)} 分超过「${nextAbove!.nick}」';
  }
}

/// 内置对手：名字固定，分差锚定在自己附近。
/// 上面 7 个是要翻过去的山，下面 12 个是垫底的底气，加上自己至少 20 人。
///
/// v1.22.4：从 8 人扩到 19 人，天花板整体抬高（第一名的封顶 400），
/// 并且每人一份档案——城市、答题量倍数、对题率都不同，
/// 榜上看起来是一群画风各异的活人，不是同一个模板复制 19 遍。
class _Rival {
  final String nick;

  /// 相对我总分的偏移（正 = 在我上面）
  final int offset;

  /// 水平上限：跟着我涨到这个分数就不动了
  final int ceiling;

  /// 所在城市（榜单行上的小标签）
  final String city;

  /// 答题量倍数：狠人答得多，躺平的答得少
  final double grind;

  /// 对题占比（0~1）：决定他行的「对 N · 错 M」长什么样
  final double acc;

  const _Rival(this.nick, this.offset, this.ceiling, this.city, this.grind, this.acc);
}

/// 十九份陪练档案。顺序即偏移从高到低。
/// 「阿禾」固定 +3，是那个抬手就够得着的追超目标，别挪。
const List<_Rival> kRivals = <_Rival>[
  // ---- 山上的人：天花板 400 / 260 / 180 / 130 / 95 / 65 / 50 ----
  _Rival('卷王本王', 150, 400, '杭州', 2.4, 0.62),
  _Rival('天不亮就起', 90, 260, '哈尔滨', 1.9, 0.60),
  _Rival('六边形战士', 55, 180, '成都', 1.5, 0.66),
  _Rival('榜一大哥', 35, 130, '广州', 1.2, 0.58),
  _Rival('悄悄卷的人', 20, 95, '长沙', 1.1, 0.55),
  _Rival('差一点就赢', 8, 65, '西安', 1.0, 0.53),
  _Rival('阿禾', 3, 50, '苏州', 0.9, 0.55),
  // ---- 山下的人：各有各的躺法 ----
  _Rival('佛系打卡人', -2, 40, '昆明', 0.7, 0.48),
  _Rival('摸鱼锦鲤', -6, 32, '三亚', 0.5, 0.46),
  _Rival('退堂鼓选手', -12, 25, '兰州', 0.45, 0.43),
  _Rival('熬夜冠军', -18, 20, '重庆', 0.95, 0.38),
  _Rival('山雀', -25, 16, '厦门', 0.4, 0.45),
  _Rival('干饭第一名', -35, 12, '佛山', 0.55, 0.36),
  _Rival('早八战神', -48, 9, '郑州', 0.6, 0.34),
  _Rival('躺平观察员', -65, 6, '贵阳', 0.3, 0.40),
  _Rival('五分钟热度', -85, 4, '石家庄', 0.25, 0.34),
  _Rival('手滑点错侠', -105, 3, '南宁', 0.35, 0.28),
  _Rival('半夜背单词', -130, 2, '乌鲁木齐', 0.3, 0.26),
  _Rival('路过的你', -160, 1, '呼和浩特', 0.2, 0.22),
];

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

/// 生成内置对手。分数 = 我的分数 + 偏移，但不越过各自档案里的水平上限。
/// 不存在 SQLite/云端里，每次即时算，所以永远跟得上我的分数。
/// 每人一份档案：答题量按 [kRivals] 的 grind 倍数走，对/错按 acc 拆，
/// 保证 right − wrong 正好等于总分（对得上账，榜上才像真的）。
/// [count] 传 -1（默认）表示全部 19 位都上。
static List<RankEntry> builtIns({
    required double myTotal,
    required int myAnswered,
    int count = -1,
  }) {
    final n = (count < 0 ? kRivals.length : count).clamp(0, kRivals.length);
    return List<RankEntry>.generate(n, (i) {
      final r = kRivals[i];
      final raw = myTotal + r.offset;
      // 上限只在「涨过头」时起作用；我分数低的时候他还是贴着我的
      final total =
          math.min(raw, r.ceiling.toDouble()).clamp(-100000.0, 100000.0);
      final totalInt = total.round();
      // 答题量 = 我 × 他的肝度 + 一点底数（带点抖动，别让我 0 题时全员一个数）
      final answered = (myAnswered * r.grind + 12 + (i * 5) % 9)
          .round()
          .clamp(0, 1000000);
      // 有对错的题数：宁可多估也别小于 |总分|，否则对/错减不出这个总分；
      // graded + 总分必须是偶数，right 才能正好是整数——差 1 就补 1
      var graded = math.max((answered * 0.85).round(), totalInt.abs());
      if ((graded + totalInt) % 2 != 0) graded++;
      final right = ((graded + totalInt) ~/ 2).clamp(0, graded);
      return RankEntry(
        id: '$builtInPrefix${r.nick}$i',
        nick: r.nick,
        total: total,
        answered: answered,
        builtIn: true,
        city: r.city,
        axes: splitTotal(r.nick, total),
        // 答对 − 答错 = 总分：right + wrong = graded，联立解出 right
        rightCnt: right,
        wrongCnt: graded - right,
      );
    });
  }

  /// 把一个总分摊到几科上，加起来正好等于这个总分。
  ///
  /// 榜上每一行都要能对上账：几科相加 = 总分，差一分都会让人怀疑
  /// 整张榜是编的。所以这里用固定权重（5:3:2）分摊、余数补最后一科，
  /// v1.22.3 起支持小数总分（分摊到两位小数）。
  /// 科目按昵称做种子挑——同一行每次刷新挑的还是那几科，
  /// 不会一刷新就换一批。
  static Map<String, double> splitTotal(String nick, double total) {
    if (total == 0) return const {};
    final abs = total.abs();
    final rnd = math.Random(_seedOf(nick));
    final pool = <String>[...kAxes]..shuffle(rnd);
    final n = abs < 4 ? 2 : 3;
    final picks = pool.take(n).toList();
    final fr = n == 2 ? const <double>[0.6, 0.4] : const <double>[0.5, 0.3, 0.2];
    final sign = total < 0 ? -1 : 1;
    final out = <String, double>{};
    var used = 0.0;
    for (var i = 0; i < n; i++) {
      final part = i == n - 1
          ? abs - used
          : ScoreBook.r2(abs * fr[i]).clamp(0.01, double.infinity);
      out[picks[i]] = ScoreBook.r2(part * sign);
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
        total: e.total.clamp(-100000.0, 100000.0),
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
    required double myTotal,
    required int myAnswered,
    required List<RankEntry> real,
    String myCity = '',
    Map<String, double> myAxes = const {},
    int myRight = 0,
    int myWrong = 0,
  }) {
    final reals = cleanReal(real, myId);
    // v1.22.4：真人再少，陪练也补到全榜（含我）至少 20 人——
    // 补 19−真人 个，但真人多时陪练按 1:1 跟涨（档案只有 19 份，到顶为止）。
    final builtInCount =
        math.max(reals.length, 19 - reals.length).clamp(0, kRivals.length);
    final built = builtIns(
      myTotal: myTotal,
      myAnswered: myAnswered,
      count: builtInCount,
    );

    final me = RankEntry(
      id: myId,
      nick: normalizeNick(myNick),
      total: myTotal.clamp(-100000.0, 100000.0),
      answered: myAnswered.clamp(0, 1000000),
      city: myCity,
      axes: myAxes,
      rightCnt: myRight,
      wrongCnt: myWrong,
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
    var gap = 0.0;
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

  /// 页面直接用当前状态算一份本地快照（不等网络）。
  /// v1.22.3：账本小数分直通榜单，云端 total 列已改 numeric，不再取整。
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

  /// 自动上报的节流：答题答得密的时候不必每题一发，
  /// 90 秒内的合并到下一次；打开榜单页用 force 绕过。
  static DateTime? _lastAutoUpload;

  /// 「只要是人答了题就要显示」——答题后自动上报，不用手动点。
  /// 失败静默，下次答题再试；返回值只给想等的调用方。
  static Future<bool> uploadAuto({bool force = false}) async {
    if (!enabled) return false;
    if (!force &&
        _lastAutoUpload != null &&
        DateTime.now().difference(_lastAutoUpload!) <
            const Duration(seconds: 90)) {
      return true;
    }
    _lastAutoUpload = DateTime.now();
    return upload();
  }

  /// 上报自己的分数。用 upsert：同一设备 ID 只更新一行，不会越用越多。
  /// 失败静默（这是激励功能，不该打断答题），由调用方决定是否提示。
  static Future<bool> upload({
    Duration timeout = const Duration(seconds: 8),
  }) async {    if (!enabled) return false;
    final id = Leaderboard.ensureDeviceId();
    final s = ScoreBook.instance;
    final body = jsonEncode([
      {
        'device_id': id,
        'nick': Leaderboard.normalizeNick(Store.s('nick', '')),
        // v1.22.3：云端 total 列已改 numeric，小数直存直取
        'total': s.total.clamp(-100000.0, 100000.0),
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
              total: (q['total'] is num) ? (q['total'] as num).toDouble() : 0,
              answered: (q['answered'] is num)
                  ? (q['answered'] as num).round()
                  : 0,
              city: (q['city'] ?? '').toString(),
              axes: _parseAxes(q['axes']),
              rightCnt: (q['right_cnt'] is num)
                  ? (q['right_cnt'] as num).round()
                  : 0,
              wrongCnt: (q['wrong_cnt'] is num)
                  ? (q['wrong_cnt'] as num).round()
                  : 0,
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
