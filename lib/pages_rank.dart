// ============================================================================
// 段位与晨序榜
//
// 页面分两段：上面是「我在哪」，下面是「跟谁比」。
//
// 这一页刻意没有做「全国第 12,847 名」这种东西。那需要一个服务器，也需要
// 把每个人的答题记录传上去；现在没有服务器，编一个名次出来只会让人以为
// 真的有一万人在用。所以这里只有真实的两件事：自己的段位，和可以跟朋友
// 交换的对拼码。
// ============================================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core.dart';
import 'power.dart';
import 'profile.dart';
import 'qbank.dart';
import 'radar.dart';
import 'rank.dart';
import 'score.dart';
import 'leaderboard.dart';

class RankPage extends StatefulWidget {
  const RankPage({super.key});

  @override
  State<RankPage> createState() => _RankPageState();
}

class _RankPageState extends State<RankPage> {
  late Profile _profile;
  final TextEditingController _input = TextEditingController();

  /// 粘进来的对拼结果，null 表示还没对拼
  Map<String, dynamic>? _rival;
  String? _err;

  // v1.20.0：真人 + 内置混排榜
  List<RankEntry> _real = const [];
  late LeaderSnapshot _board;
  bool _pulling = false;
  bool _online = true;

  @override
  void initState() {
    super.initState();
    _profile = Profile.load();
    Leaderboard.ensureDeviceId();
    _online = LeaderSync.enabled;
    // 先用缓存/纯内置把榜撑起来（本地即时，不闪空白），再按节流拉真人。
    _real = LeaderSync.cached;
    _board = _makeBoard();
    if (_online && LeaderSync.dueForPull) _pull(background: true);
  }

  LeaderSnapshot _makeBoard() => Leaderboard.snapshot(
        myId: Leaderboard.myId,
        myNick: Store.s('nick', ''),
        myTotal: ScoreBook.instance.total,
        myAnswered: ScoreBook.instance.answered,
        real: _real,
        myCity: Store.s('cityName', ''),
      );

  Future<void> _pull({bool background = false}) async {
    if (_pulling || !_online) return;
    setState(() => _pulling = true);
    final rows = await LeaderSync.pull();
    if (!mounted) return;
    setState(() {
      _pulling = false;
      if (rows != null) _real = rows;
      _board = _makeBoard();
    });
    if (!background) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(rows == null
            ? '连不上榜单服务，显示的是上次的结果'
            : '榜单已刷新 · ${rows.length} 位真人'),
      ));
    }
  }

  Future<void> _uploadNow() async {
    if (!_online) return;
    final ok = await LeaderSync.upload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? '分数已上报，别人能在榜上看到你' : '上报失败，稍后再试'),
    ));
  }

  void _toggleOnline(bool v) {
    setState(() {
      _online = v;
      LeaderSync.enabled = v;
      _real = v ? LeaderSync.cached : const [];
      _board = _makeBoard();
    });
    Store.saveSettings();
    if (v) _pull(background: true);
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  int get _answered => _profile.answered.length;

  Future<void> _copyCode() async {
    final code = Rank.codeOf(
      answered: _answered,
      streak: Store.streak,
      correct: Rank.correctOf(),
      power: PowerChart.instance,
    );
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('对拼码已复制，发给朋友就行')),
    );
  }

  void _compare() {
    final m = Rank.parseCode(_input.text);
    if (m == null) {
      setState(() {
        _rival = null;
        _err = '这段码不完整。整段发过来，中间不要漏字符。';
      });
      return;
    }
    setState(() {
      _rival = m;
      _err = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tier = Rank.tierOf(_answered);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(22, 6, 22, 28),
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back_ios_new, size: 18),
                  color: AppColor.sub,
                ),
                const Text('晨序榜', style: TextStyle(fontSize: 17)),
                const Spacer(),
              ],
            ),
            const SizedBox(height: 6),

            // 我的段位 + 战力图（左边段位，右边十边形）
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: AppColor.glassCard,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColor.glassEdge),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('我的段位',
                            style: TextStyle(fontSize: 11.5, color: AppColor.sub)),
                        const SizedBox(height: 8),
                        Text(tier.name,
                            style: const TextStyle(
                                fontSize: 30, height: 1.1, fontWeight: FontWeight.w300)),
                        const SizedBox(height: 4),
                        Text('已答 $_answered 道 · 没有上限',
                            style: TextStyle(fontSize: 11.5, color: AppColor.sub)),
                        const SizedBox(height: 6),
                        Text(tier.note,
                            style: TextStyle(fontSize: 11, color: AppColor.sub)),
                        const SizedBox(height: 12),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: Rank.progress(_answered),
                            minHeight: 5,
                            backgroundColor: AppColor.line,
                            valueColor: AlwaysStoppedAnimation<Color>(AppColor.accent),
                          ),
                        ),
                        const SizedBox(height: 7),
                        Text(
                          '再答 ${Rank.toNext(_answered)} 道到「${Rank.nextOf(_answered).name}」',
                          style: TextStyle(fontSize: 10.5, color: AppColor.sub),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  PowerRadar(values: PowerChart.instance.normalized, size: 132),
                ],
              ),
            ),

            const SizedBox(height: 8),
            Text('这张多边形就是你的战力：答对的领域往外长，答错、跳过就往里收。',
                style: TextStyle(fontSize: 10.5, height: 1.5, color: AppColor.sub)),

            // v1.20.0：实时混合榜——自己的名次本地即时算，真人几小时拉一次
            const SizedBox(height: 20),
            _boardCard(),

            const SizedBox(height: 18),
            Text('段位阶梯',
                style: TextStyle(fontSize: 11.5, letterSpacing: 1, color: AppColor.sub)),
            const SizedBox(height: 10),
            for (final t in Rank.ladderRows(_answered).reversed) _tierRow(t),

            const SizedBox(height: 20),
            Text('跟朋友对拼',
                style: TextStyle(fontSize: 11.5, letterSpacing: 1, color: AppColor.sub)),
            const SizedBox(height: 6),
            Text(
              '答题记录只存在这台手机里，不上传。想比，就把下面这段码发给朋友，'
              '让他把码贴进来；或者他把他的码发给你。谁的数据都不离开自己的手机。',
              style: TextStyle(fontSize: 11, height: 1.6, color: AppColor.sub),
            ),
            const SizedBox(height: 12),

            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColor.glassPanel,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColor.panelLine),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('我的对拼码',
                      style: TextStyle(fontSize: 11, color: AppColor.sub)),
                  const SizedBox(height: 8),
                  SelectableText(
                    Rank.codeOf(
                      answered: _answered,
                      streak: Store.streak,
                      correct: Rank.correctOf(),
                      power: PowerChart.instance,
                    ),
                    style: const TextStyle(
                        fontSize: 15, letterSpacing: 0.6, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      TextButton(
                        onPressed: _copyCode,
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(0, 30),
                        ),
                        child: Text('复制',
                            style:
                                TextStyle(fontSize: 12, color: AppColor.accent)),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),
            TextField(
              controller: _input,
              style: const TextStyle(fontSize: 13, letterSpacing: 0.4),
              decoration: InputDecoration(
                hintText: '把朋友的对拼码贴在这里，CX2 开头的会带上战力图',
                hintStyle: TextStyle(fontSize: 11.5, color: AppColor.sub),
                filled: true,
                fillColor: AppColor.card,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: AppColor.line),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: AppColor.line),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              ),
            ),
            if (_err != null) ...[
              const SizedBox(height: 8),
              Text(_err!, style: TextStyle(fontSize: 11.5, color: AppColor.accent)),
            ],
            const SizedBox(height: 10),
            SizedBox(
              height: 46,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColor.ink,
                  foregroundColor: AppColor.onInk,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: _compare,
                child: const Text('对拼'),
              ),
            ),
            if (_rival != null) ...[
              const SizedBox(height: 16),
              _rivalCard(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _boardCard() {
    final b = _board;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('晨序榜 · 实时',
                style: TextStyle(
                    fontSize: 11.5, letterSpacing: 1, color: AppColor.sub)),
            const Spacer(),
            if (_online)
              TextButton(
                onPressed: _pulling ? null : () => _pull(),
                style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 24)),
                child: Text(_pulling ? '刷新中…' : '刷新真人榜',
                    style: TextStyle(fontSize: 11, color: AppColor.accent)),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColor.glassCard,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppColor.glassEdge),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('第 ${b.rank} 名',
                      style: const TextStyle(
                          fontSize: 30, height: 1.1, fontWeight: FontWeight.w300)),
                  const SizedBox(width: 12),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Text('超过 ${b.surpassed} 人 · 共 ${b.playerCount} 人',
                        style:
                            TextStyle(fontSize: 11.5, color: AppColor.sub)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(b.chaseLine,
                  style: TextStyle(fontSize: 12, color: AppColor.accent)),
              const SizedBox(height: 16),
              // 前几名 + 自己附近，避免整榜太长
              for (final e in _boardRows(b)) _boardRow(e),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.people_alt_outlined,
                      size: 13, color: AppColor.sub),
                  const SizedBox(width: 5),
                  Text('${b.realCount} 位真人 · ${b.builtInCount} 位内置对手',
                      style: TextStyle(fontSize: 10.5, color: AppColor.sub)),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '内置对手是 App 里的虚拟角色（分数跟着你走，前面永远有人可追），'
                '不冒充真人。真人分数由本人匿名上报，设备 ID 区分，不收手机号邮箱。',
                style: TextStyle(fontSize: 10, height: 1.6, color: AppColor.sub),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Switch(
              value: _online,
              onChanged: _toggleOnline,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                _online ? '参与真人榜（上报分数，几小时刷新）' : '不上报分数，只用内置对手',
                style: TextStyle(fontSize: 11, color: AppColor.sub),
              ),
            ),
            if (_online)
              TextButton(
                onPressed: _uploadNow,
                style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 28)),
                child: Text('上报分数',
                    style: TextStyle(fontSize: 11, color: AppColor.accent)),
              ),
          ],
        ),
      ],
    );
  }

  /// 榜单只显示：前三名 + 自己前后各两名，避免一屏塞满。
  List<RankEntry> _boardRows(LeaderSnapshot b) {
    final idx = b.myIndex;
    if (idx < 0) return b.rows.take(3).toList();
    final keep = <int>{0, 1, 2};
    for (var i = idx - 2; i <= idx + 2; i++) {
      if (i >= 0 && i < b.rows.length) keep.add(i);
    }
    final sorted = keep.toList()..sort();
    final out = <RankEntry>[];
    var last = -1;
    for (final i in sorted) {
      if (last >= 0 && i - last > 1) {
        out.add(RankEntry(
            id: '__gap_$i', nick: '⋯', total: 0, answered: 0, builtIn: true));
      }
      out.add(b.rows[i]);
      last = i;
    }
    return out;
  }

  Widget _boardRow(RankEntry e) {
    if (e.nick == '⋯') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text('   ⋯', style: TextStyle(fontSize: 11, color: AppColor.sub)),
      );
    }
    final me = e.id == Leaderboard.myId;
    final rank = _board.rows.indexWhere((x) => x.id == e.id) + 1;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: me ? AppColor.accentSoft : AppColor.card,
        borderRadius: BorderRadius.circular(12),
        border:
            Border.all(color: me ? AppColor.accent : AppColor.line, width: me ? 1 : 0.5),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            child: Text('$rank',
                style: TextStyle(
                    fontSize: 12,
                    color: me ? AppColor.accent : AppColor.sub)),
          ),
          Expanded(
            child: Row(
              children: [
                Text(e.nick,
                    style: TextStyle(
                        fontSize: 12.5,
                        color: me ? AppColor.accent : null,
                        fontWeight: me ? FontWeight.w500 : FontWeight.normal)),
                const SizedBox(width: 6),
                if (e.builtIn)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: AppColor.glassPanel,
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(color: AppColor.panelLine, width: 0.5),
                    ),
                    child: Text('内置',
                        style: TextStyle(fontSize: 9, color: AppColor.sub)),
                  ),
              ],
            ),
          ),
          Text('${e.total} 分',
              style: TextStyle(
                  fontSize: 12.5,
                  color: me ? AppColor.accent : null,
                  fontWeight: me ? FontWeight.w500 : FontWeight.normal)),
        ],
      ),
    );
  }

  Widget _tierRow(RankTier t) {
    final reached = _answered >= t.at;
    final current = Rank.tierOf(_answered).name == t.name;
    // 对拼的人爬到这一阶时，把他的战力图挂在这一行上，点开就能看
    final rivalHere = _rival != null &&
        Rank.tierOf(_rival!['answered'] as int).name == t.name &&
        _rival!['power'] != null;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: current ? AppColor.accentSoft : AppColor.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: current ? AppColor.accent : AppColor.line),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 66,
            child: Text(t.name,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: current ? FontWeight.w600 : FontWeight.w400,
                  color: reached ? AppColor.ink : AppColor.sub,
                )),
          ),
          Expanded(
            child: Text(t.note,
                style: TextStyle(fontSize: 10.5, color: AppColor.sub)),
          ),
          if (rivalHere)
            GestureDetector(
              onTap: () => _showRivalRadar(t),
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.auto_awesome, size: 12, color: AppColor.accent),
                    Text('看战力',
                        style: TextStyle(fontSize: 10, color: AppColor.accent)),
                  ],
                ),
              ),
            ),
          const SizedBox(width: 4),
          Text(
            reached ? '已到' : '${t.at} 题',
            style: TextStyle(
              fontSize: 10.5,
              color: current ? AppColor.accent : AppColor.sub,
            ),
          ),
        ],
      ),
    );
  }

  void _showRivalRadar(RankTier tier) {
    final pw = _rival?['power'] as PowerChart?;
    if (pw == null) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 30),
        decoration: BoxDecoration(
          color: AppColor.card,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
          border: Border.all(color: AppColor.glassEdge),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${tier.name} · 对方战力',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w400)),
            const SizedBox(height: 6),
            Text('实线是你，虚线是对方',
                style: TextStyle(fontSize: 11, color: AppColor.sub)),
            const SizedBox(height: 12),
            PowerRadar(
              values: PowerChart.instance.normalized,
              rival: pw.normalized,
              size: 230,
            ),
          ],
        ),
      ),
    );
  }

  Widget _rivalCard() {
    final r = _rival!;
    final mine = _answered;
    final theirs = r['answered'] ?? 0;
    final diff = mine - theirs;
    final myTier = Rank.tierOf(mine);
    final hisTier = Rank.tierOf(theirs);
    final rivalPower = r['power'] as PowerChart?;

    final String verdict;
    if (diff > 0) {
      verdict = '你多答了 $diff 道，领先。';
    } else if (diff < 0) {
      verdict = '对方多答了 ${-diff} 道。差得不远，够得着。';
    } else {
      verdict = '题数一样，那就看谁走得深。';
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColor.glassCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColor.glassEdge),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: _side('我', myTier.name, mine, Store.streak)),
              Container(width: 1, height: 44, color: AppColor.line),
              Expanded(child: _side('对方', hisTier.name, theirs, r['streak'] ?? 0)),
            ],
          ),
          const SizedBox(height: 12),
          Text(verdict, style: const TextStyle(fontSize: 12.5, height: 1.6)),
          if (rivalPower != null) ...[
            const SizedBox(height: 14),
            const Divider(height: 1),
            const SizedBox(height: 12),
            Text('战力对照 · 实线是你，虚线是对方',
                style: TextStyle(fontSize: 11, color: AppColor.sub)),
            const SizedBox(height: 8),
            Center(
              child: PowerRadar(
                values: PowerChart.instance.normalized,
                rival: rivalPower.normalized,
                size: 210,
              ),
            ),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text('对方用的是旧对拼码，没有战力图。让他升级后重新发一次。',
                  style: TextStyle(fontSize: 10.5, color: AppColor.sub)),
            ),
        ],
      ),
    );
  }

  Widget _side(String who, String tier, int answered, int streak) {
    return Column(
      children: [
        Text(who, style: TextStyle(fontSize: 11, color: AppColor.sub)),
        const SizedBox(height: 4),
        Text(tier, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w400)),
        const SizedBox(height: 2),
        Text('$answered 道 · 连续 $streak 天',
            style: TextStyle(fontSize: 10.5, color: AppColor.sub)),
      ],
    );
  }
}

/// 给「我的」页面用的一行摘要
String rankSummaryLine() {
  final p = Profile.load();
  final n = p.answered.length;
  // v1.20.0：榜单是本地即时算的，所以「我的」页这行也能当场显示名次。
  final b = Leaderboard.localNow(real: LeaderSync.cached);
  return '第 ${b.rank} 名 · 超过 ${b.surpassed} 人 · ${Rank.tierOf(n).name}';
}
