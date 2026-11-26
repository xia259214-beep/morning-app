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
import 'grade.dart';
import 'power.dart';
import 'profile.dart';
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

  // v1.21.4：对拼码平时收起来，要用再点开——
  // 它一个月用不了几次，却天天占着一整屏。
  bool _duelOpen = false;

  @override
  void initState() {
    super.initState();
    _profile = Profile.load();
    Leaderboard.ensureDeviceId();
    _online = LeaderSync.enabled;
    // 先用缓存/纯内置把榜撑起来（本地即时，不闪空白）。
    _real = LeaderSync.cached;
    _board = _makeBoard();
    // v1.21.2：打开榜单页就先把自己的分数报上去，再拉全榜——
    // 拉回来的列表里才有刚上过线的自己和别人。以前只有手动点
    // 「上报分数」才传，两台设备都答了题也互相看不见。
    if (_online) {
      LeaderSync.uploadAuto(force: true).then((_) {
        if (mounted) _pull(background: true);
      });
    }
  }

  /// v1.22.3：云端 total 列已是 numeric，账本小数直通榜单。
  LeaderSnapshot _makeBoard() {
    final s = ScoreBook.instance;
    return Leaderboard.snapshot(
      myId: Leaderboard.myId,
      myNick: Store.s('nick', ''),
      myTotal: s.total,
      myAnswered: s.answered,
      real: _real,
      myCity: Store.s('cityName', ''),
      myAxes: s.byAxis,
      myRight: s.right,
      myWrong: s.wrong,
    );
  }

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
                  color: AppColor.bgSub,
                ),
                // 这一行画在页面背景上（不是卡片里），得用背景字色，
                // 否则深色主题下标题几乎看不见。
                Text('晨序榜',
                    style: TextStyle(fontSize: 17, color: AppColor.bgInk)),
                const Spacer(),
              ],
            ),
            const SizedBox(height: 6),

            // 我的段位 + 战力图（上：段位与综合等级；下：十维等级）
            Container(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
              decoration: BoxDecoration(
                color: AppColor.glassCard,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColor.glassEdge),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('我的段位',
                      style: TextStyle(fontSize: 11.5, color: AppColor.sub)),
                  const SizedBox(height: 8),
                  // 段位名和综合等级挨着放：等级说的就是这一段位的整体水平，
                  // 分到卡片两头会让人以为「综合」是另一个东西。
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(tier.name,
                          style: const TextStyle(
                              fontSize: 30,
                              height: 1.1,
                              fontWeight: FontWeight.w300)),
                      const SizedBox(width: 12),
                      _overallGradeBadge(),
                    ],
                  ),
                  const SizedBox(height: 6),
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
                  const SizedBox(height: 12),
                  // v1.21.0：十维各配一个 A~F 等级，画在角上。
                  // 尺寸跟着卡片宽度走——手机上一只手能看全，折叠屏摊开也不空。
                  LayoutBuilder(builder: (ctx, c) {
                    final side =
                        (c.maxWidth * 0.46).clamp(186.0, 300.0).toDouble();
                    return Center(
                      child: PowerRadar(
                        values: PowerChart.instance.normalized,
                        grades: AxisGrade.axesOf(PowerChart.instance),
                        size: side,
                      ),
                    );
                  }),
                  const SizedBox(height: 6),
                  Text('十个角就是十个领域：答对的往外长、答错的往里收。',
                      style: TextStyle(fontSize: 10.5, height: 1.5, color: AppColor.sub)),
                  const SizedBox(height: 2),
                  Text('等级按 A–F 记：A 最强，C 是「还没看清」，F 是这块还空着。',
                      style: TextStyle(fontSize: 10.5, height: 1.5, color: AppColor.sub)),
                  const SizedBox(height: 10),
                  _axisGradeLine(),
                ],
              ),
            ),

            // v1.20.0：实时混合榜——自己的名次本地即时算，真人几小时拉一次
            const SizedBox(height: 20),
            _boardCard(),

            const SizedBox(height: 18),
            Text('段位阶梯',
                style: TextStyle(fontSize: 11.5, letterSpacing: 1, color: AppColor.bgSub)),
            const SizedBox(height: 10),
            for (final t in Rank.ladderRows(_answered).reversed) _tierRow(t),

            const SizedBox(height: 20),
            Text('跟朋友对拼',
                style: TextStyle(fontSize: 11.5, letterSpacing: 1, color: AppColor.bgSub)),
            const SizedBox(height: 6),
            Text(
              '答题记录只存在这台手机里，不上传。想比，就把下面这段码发给朋友，'
              '让他把码贴进来；或者他把他的码发给你。谁的数据都不离开自己的手机。',
              style: TextStyle(fontSize: 11, height: 1.6, color: AppColor.bgSub),
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
                  // v1.21.4：对拼码平时折叠，点标题展开——
                  // 用得少的东西不该常驻一整屏。
                  InkWell(
                    onTap: () => setState(() => _duelOpen = !_duelOpen),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text('我的对拼码',
                              style: TextStyle(fontSize: 11, color: AppColor.sub)),
                        ),
                        Icon(
                          _duelOpen
                              ? Icons.expand_less
                              : Icons.expand_more,
                          size: 18,
                          color: AppColor.sub,
                        ),
                      ],
                    ),
                  ),
                  if (_duelOpen) ...[
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
              Text(_err!,
                  style: TextStyle(fontSize: 11.5, color: AppColor.bgAccent)),
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

  /// 综合等级：十维取平均。紧挨着段位名，一眼看到「整体哪一档」。
  Widget _overallGradeBadge() {
    final g = AxisGrade.overallOf(PowerChart.instance);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        color: AppColor.accentSoft,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: AppColor.accent),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(g,
              style: TextStyle(
                  fontSize: 17,
                  height: 1.2,
                  fontWeight: FontWeight.w600,
                  color: AppColor.accent)),
          const SizedBox(width: 4),
          Text('综合',
              style: TextStyle(fontSize: 9, height: 1.2, color: AppColor.sub)),
        ],
      ),
    );
  }

  /// 十科各自的字母，两个一行排下来。雷达图角上的字太小，
  /// 这一块是给「想数一遍」的人用的。
  Widget _axisGradeLine() {
    final p = PowerChart.instance;
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      children: [
        for (final a in kAxes)
          Text.rich(
            TextSpan(children: [
              TextSpan(
                  text: a,
                  style: TextStyle(fontSize: 10.5, color: AppColor.sub)),
              TextSpan(
                  text: ' ${AxisGrade.of(p.of(a))}',
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: AppColor.accent)),
            ]),
          ),
      ],
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
                    fontSize: 11.5, letterSpacing: 1, color: AppColor.bgSub)),
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
                  // 自己也是一位真人，别把它漏在计数外面——
                  // 「0 位」会让答了题的人以为上报没生效。
                  Text(
                      b.realCount == 0
                          ? '目前榜上就你 1 位 · ${b.builtInCount} 位陪练角色'
                          : '${b.realCount + 1} 位（含你） · ${b.builtInCount} 位陪练角色',
                      style: TextStyle(fontSize: 10.5, color: AppColor.sub)),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '每行下面的科目，是这几分从哪来：答对按题型加分（判断 1 / 单选 1.35 / 多选 1.55），'
                '连对有加成，答错 −1、漏选 −0.01、漏选加选错 −1.12、跳过 −0.1。'
                '「往期」是按旧规则攒下的总分，单独留着，不硬拆成十份。'
                '账本和榜上都记到小数（两位）。',
                style: TextStyle(fontSize: 10, height: 1.6, color: AppColor.sub),
              ),
              const SizedBox(height: 6),
              Text(
                '陪练角色是 App 自带的（分数跟着你的水平走，前面永远有人可追），'
                '不冒充真人；真人分数由本人匿名上报，设备 ID 区分，不收手机号邮箱。',
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
                _online ? '参与真人榜（上报分数，几小时刷新）' : '不上报分数，只跟陪练比',
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
    // 末尾还剩人时也留一行「还有 N 人」，否则榜单看起来就到这里为止了，
    // 明明还有排名在自己后面的人。
    final rest = b.rows.length - 1 - last;
    if (rest > 0) {
      out.add(RankEntry(
          id: '__gap_end',
          nick: '⋯',
          total: 0,
          answered: 0,
          builtIn: true,
          city: '$rest'));
    }
    return out;
  }

  Widget _boardRow(RankEntry e) {
    if (e.nick == '⋯') {
      // city 里塞的是「还剩几个人」，末尾那一行用得上
      final rest = e.city;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(rest.isEmpty ? '   ⋯' : '   ⋯ 还有 $rest 人',
            style: TextStyle(fontSize: 11, color: AppColor.sub)),
      );
    }
    final me = e.id == Leaderboard.myId;
    final rank = _board.rows.indexWhere((x) => x.id == e.id) + 1;
    var parts = _scoreParts(e, dim: me);
    // 自己这一行什么都没有时（新装、或分数正好为 0），别留一片空白：
    // 说一句下一步怎么才有内容，比一个空行有用。
    if (parts == null && me) {
      parts = TextSpan(
        text: '答一题就有分科明细',
        style: TextStyle(fontSize: 10, color: AppColor.sub),
      );
    }
    return GestureDetector(
      // v1.21.4：点榜单上任何一行，弹出那个人的段位雷达图。
      // 榜上只有一个总分数字，看不出强在哪弱在哪；点开就有十边形。
      onTap: () => _showRadar(e, me: me),
      child: Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
      decoration: BoxDecoration(
        color: me ? AppColor.accentSoft : AppColor.card,
        borderRadius: BorderRadius.circular(12),
        border:
            Border.all(color: me ? AppColor.accent : AppColor.line, width: me ? 1 : 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 22,
                child: Text('$rank',
                    style: TextStyle(
                        fontSize: 12,
                        color: me ? AppColor.accent : AppColor.sub)),
              ),
              Expanded(
                child: Text(e.nick,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12.5,
                        color: me ? AppColor.accent : null,
                        fontWeight: me ? FontWeight.w500 : FontWeight.normal)),
              ),
              const SizedBox(width: 8),
              Text('总分 ${ScoreBook.fmt(e.total)}',
                  style: TextStyle(
                      fontSize: 12.5,
                      color: me ? AppColor.accent : AppColor.ink,
                      fontWeight: FontWeight.w500)),
            ],
          ),
          // 这几分是哪几科挣的。没有分科数据（老版本上报的行）就不画，
          // 不拿总分硬拆十份糊弄人。
          if (parts != null)
            Padding(
              padding: const EdgeInsets.only(left: 22, top: 3),
              child: Text.rich(parts,
                  maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
        ],
      ),
      ),
    );
  }

  /// 点榜单一行，弹出那个人的段位雷达图（v1.21.4）。
  /// 自己用真实的战力账本；别人用他上报的分科反推——
  /// 战力一次答对 +6、答错 −5，但「净 +18 分」可能是 3 对 0 错，
  /// 也可能是 13 对 11 错，反推不出唯一值。这里按 2 倍保守折算
  /// （宁可画小一点，也不给一个只答了几题的人挂三个 A），夹在 0~100 再画。
  void _showRadar(RankEntry e, {required bool me}) {
    final PowerChart p;
    if (me) {
      p = PowerChart.instance;
    } else {
      p = PowerChart({
        for (final a in kAxes)
          a: (50.0 + 2.0 * (e.axes[a] ?? 0)).clamp(0, 100).toDouble(),
      });
    }
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColor.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          e.nick,
          style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: me ? AppColor.accent : AppColor.ink),
        ),
        content: SizedBox(
          width: 300,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('总分 ${ScoreBook.fmt(e.total)} · 答了 ${e.answered} 道',
                  style: TextStyle(fontSize: 11.5, color: AppColor.sub)),
              const SizedBox(height: 10),
              Center(
                child: PowerRadar(
                  values: p.normalized,
                  grades: AxisGrade.axesOf(p),
                  size: 230,
                ),
              ),
              const SizedBox(height: 6),
              Center(
                child: Text(
                  '综合 ${AxisGrade.overallOf(p)}',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: AppColor.accent),
                ),
              ),
              const SizedBox(height: 4),
              Text('等级 A–F：A 最强，C 是「还没看清」，F 是这块基本没答过。',
                  style: TextStyle(fontSize: 10, height: 1.5, color: AppColor.sub)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('关闭', style: TextStyle(color: AppColor.accent)),
          ),
        ],
      ),
    );
  }

  /// 各科得分 → 一行小字：「科技 +18 · 体育 +12 · 扣 生活 −2 · 军事 −1」。
  /// v1.21.4：挣的分和扣的分都摆出来——只写 +的分，账就不完整，
  /// 答错的人看到自己名字底下全是进账，会以为系统没记他的错。
  /// 返回 null 表示这一行没分科数据。
  TextSpan? _scoreParts(RankEntry e, {bool dim = false}) {
    final all = e.axes.entries.where((x) => x.value != 0).toList()
      ..sort((a, b) => b.value.abs().compareTo(a.value.abs()));
    final gains = all.where((x) => x.value > 0).toList();
    final losses = all.where((x) => x.value < 0).toList();
    final shown = <MapEntry<String, double>>[
      ...gains.take(2),
      ...losses.take(2),
    ];
    final spans = <InlineSpan>[];
    void add(String name, double v) {
      if (spans.isNotEmpty) {
        spans.add(TextSpan(
            text: ' · ', style: TextStyle(fontSize: 10, color: AppColor.sub)));
      }
      spans.add(TextSpan(
          text: '$name ',
          style: TextStyle(fontSize: 10, color: AppColor.sub)));
      spans.add(TextSpan(
        text: v > 0 ? '+${ScoreBook.fmt(v)}' : '−${ScoreBook.fmt(v.abs())}',
        style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w500,
            color: v > 0
                ? (dim ? AppColor.accent : AppColor.ink)
                : AppColor.sub),
      ));
    }

    for (final x in shown) {
      add(x.key, x.value);
    }
    final restCount = all.length - shown.length;
    if (restCount > 0) {
      spans.add(TextSpan(
          text: ' 等 ${all.length} 科',
          style: TextStyle(fontSize: 9.5, color: AppColor.sub)));
    }
    // 旧版本攒下的总分，没分科，单独标出来，不混进任何一科
    if (e.legacy != 0) add('往期', e.legacy);
    // v1.21.4：答对/答错各多少道。只留净分的话，「对 100 错 95」和
    // 「对 5 错 0」看着一模一样；两边摆出来，这几分怎么来的才说得清。
    if (e.rightCnt > 0 || e.wrongCnt > 0) {
      if (spans.isNotEmpty) {
        spans.add(TextSpan(
            text: ' · ', style: TextStyle(fontSize: 10, color: AppColor.sub)));
      }
      spans.add(TextSpan(
          text: '对 ${e.rightCnt} · 错 ${e.wrongCnt}',
          style: TextStyle(fontSize: 10, color: AppColor.sub)));
    }
    if (spans.isEmpty) return null;
    return TextSpan(children: spans);
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
