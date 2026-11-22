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

  @override
  void initState() {
    super.initState();
    _profile = Profile.load();
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
  return '${Rank.tierOf(n).name} · 已答 $n 道';
}
