// ============================================================================
// 独立答题页
//
// 以前答题只存在于晨间流程里：没到早上、没点「开始晨间」，就进不去。
// 用户点过一次「重新开始」，画像清空了，然后翻遍整个 App 找不到答题入口。
//
// 这一页就是那个入口：随时可进、随时可停，答多答少都算数。
// ============================================================================

import 'package:flutter/material.dart';

import 'core.dart';
import 'focus.dart';
import 'power.dart';
import 'profile.dart';
import 'radar.dart';
import 'qbank.dart';
import 'quiz_pane.dart';
import 'leaderboard.dart';
import 'rank.dart';
import 'score.dart';

class QuizPage extends StatefulWidget {
  /// 进来时用的题数档位；不传就按设置里的默认值
  final int? count;

  const QuizPage({super.key, this.count});

  @override
  State<QuizPage> createState() => _QuizPageState();
}

class _QuizPageState extends State<QuizPage> {
  late int _count;
  QuizTally _tally = QuizTally.zero;

  /// 每开一轮就换一次 key，让面板整个重建
  int _roundKey = 0;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _count = widget.count ?? Store.i('quizCount', 10);
  }

  void _startRound([int? count]) {
    setState(() {
      if (count != null) {
        _count = count;
        Store.set('quizCount', '$count');
      }
      _roundKey++;
      _done = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = Profile.load();
    final answered = p.answered.length;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            _topBar(),
            Expanded(
              child: _done ? _summary(answered) : _runner(),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 顶栏
  Widget _topBar() {
    final p = Profile.load();
    final answered = p.answered.length;
    final tier = Rank.tierOf(answered);

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 6),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.arrow_back_ios_new, size: 18),
                color: AppColor.sub,
              ),
              const SizedBox(width: 2),
              const Text('答题', style: TextStyle(fontSize: 17)),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColor.accentSoft,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text('${tier.name} · 已答 $answered 道',
                    style: TextStyle(fontSize: 10.5, color: AppColor.accent)),
              ),
              const Spacer(),
              // 总分就摆在答题页右上角：答题时最想知道「我这一路挣了多少」，
              // 藏进「我的」里得点两层才看得到，等于没有。
              Text('总分 ',
                  style: TextStyle(fontSize: 10.5, color: AppColor.sub)),
              Text(ScoreBook.fmt(ScoreBook.instance.total),
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w500)),
              const SizedBox(width: 8),
              // v1.20.0：实时名次。内置对手锚在我附近，所以每答一题都会动。
              Builder(builder: (_) {
                final b = Leaderboard.localNow(real: LeaderSync.cached);
                return Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColor.accentSoft,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text('第 ${b.rank} 名',
                      style: TextStyle(
                          fontSize: 10.5, color: AppColor.accent)),
                );
              }),
            ],
          ),
          const SizedBox(height: 6),
          _gateStrip(),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: Rank.progress(answered),
              minHeight: 4,
              backgroundColor: AppColor.line,
              valueColor: AlwaysStoppedAnimation<Color>(AppColor.accent),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 今日之门
  /// 四个领域按天轮值，今天只开一个，其余三个置灰写明哪天开放。
  /// 「全部」档是唯一例外：一次走完整座山时四门全开。
  Widget _gateStrip() {
    final today = DailyFocus.today;
    final allOpen = _count < 0;
    return Row(
      children: [
        for (final a in kFocusAreas)
          Expanded(
            child: Container(
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(vertical: 7),
              decoration: BoxDecoration(
                color: a.id == today.id && !allOpen
                    ? AppColor.accentSoft
                    : AppColor.card,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: a.id == today.id && !allOpen
                      ? AppColor.accent
                      : AppColor.line,
                ),
              ),
              child: Column(
                children: [
                  Text(a.name,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: a.id == today.id ? FontWeight.w600 : FontWeight.w400,
                        color: (a.id == today.id && !allOpen) || allOpen
                            ? AppColor.ink
                            : AppColor.sub,
                      )),
                  const SizedBox(height: 2),
                  Text(
                    allOpen
                        ? '开'
                        : (a.id == today.id ? '今日' : _shortHint(a)),
                    style: TextStyle(
                      fontSize: 9,
                      color: a.id == today.id && !allOpen
                          ? AppColor.accent
                          : AppColor.sub,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  String _shortHint(FocusArea a) {
    final d = DailyFocus.daysUntil(a);
    if (d == 1) return '明天';
    if (d == 2) return '后天';
    return '$d 天后';
  }

  // ---------------------------------------------------------------- 答题
  Widget _runner() {
    return QuizPane(
      key: ValueKey('round$_roundKey'),
      count: _count,
      onlyRoots: _count < 0 ? null : DailyFocus.todayRoots,
      finishLabel: '本轮完成',
      onFinish: (t) {
        setState(() {
          _tally = _tally + t;
          _done = true;
        });
      },
      onEarlyStop: (t) {
        setState(() {
          // 提前结束同样要并入本轮成绩，否则小结页「这一轮」显示 0
          _tally = _tally + t;
          _done = true;
        });
      },
      earlyStopLabel: '先停一下，看看成绩',
      // v1.20.0：每题判完立刻重算名次——这是「实时」最直接的体感
      // v1.21.2：顺手把自己的分数报上去（90 秒节流），不用手动点。
      // 不等它——上报失败也不打断答题，下次再试。
      onAnswered: () {
        setState(() {});
        LeaderSync.uploadAuto();
      },
    );
  }

  // ---------------------------------------------------------------- 本轮小结
  Widget _summary(int answered) {
    final total = QBank.instance.total;
    final t = _tally;
    final correct = t.correct;
    final know = t.answered;
    final rate = know == 0 ? 0 : (correct / know * 100).round();
    final tier = Rank.tierOf(answered);
    final next = Rank.nextOf(answered);
    final radar = PowerRadar(values: PowerChart.instance.normalized, size: 150);

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 28),
      children: [
        Text('这一轮', style: TextStyle(fontSize: 12, color: AppColor.sub)),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('$know',
                style: const TextStyle(
                    fontSize: 56, height: 1.0, fontWeight: FontWeight.w200)),
            Padding(
              padding: const EdgeInsets.only(left: 6, bottom: 8),
              child: Text('道',
                  style: TextStyle(fontSize: 13, color: AppColor.sub)),
            ),
            const Spacer(),
            Text('答对 $correct · $rate%',
                style: TextStyle(fontSize: 12.5, color: AppColor.sub)),
          ],
        ),
        if (t.skipped > 0) ...[
          const SizedBox(height: 6),
          Text('跳过 ${t.skipped} 道，这几块先不问',
              style: TextStyle(fontSize: 11.5, color: AppColor.sub)),
        ],
        const SizedBox(height: 14),
        // 本轮得分：答对 +题型分、错漏按档扣、跳过 −0.1（口径见 score.dart）
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          decoration: BoxDecoration(
            color: AppColor.accentSoft,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('本轮得分',
                      style: TextStyle(fontSize: 10.5, color: AppColor.sub)),
                  const SizedBox(height: 2),
                  Text(t.points > 0
                      ? '+${ScoreBook.fmt(t.points)}'
                      : ScoreBook.fmt(t.points),
                      style: const TextStyle(
                          fontSize: 26, height: 1.1, fontWeight: FontWeight.w300)),
                ],
              ),
              const Spacer(),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('总分 ${ScoreBook.fmt(ScoreBook.instance.total)}',
                      style: const TextStyle(fontSize: 13)),
                  const SizedBox(height: 3),
                  Text('判断 +1 · 单选 +1.35 · 多选 +1.55 · 连击有加成 · 跳过 −0.1',
                      style: TextStyle(fontSize: 9.5, color: AppColor.sub)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColor.glassCard,
            borderRadius: BorderRadius.circular(18),
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
                        style: TextStyle(fontSize: 10.5, color: AppColor.sub)),
                    const SizedBox(height: 5),
                    Text(tier.name,
                        style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w400)),
                    const SizedBox(height: 4),
                    Text(tier.note,
                        style: TextStyle(fontSize: 10.5, color: AppColor.sub)),
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: Rank.progress(answered),
                        minHeight: 5,
                        backgroundColor: AppColor.line,
                        valueColor: AlwaysStoppedAnimation<Color>(AppColor.accent),
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      '再答 ${Rank.toNext(answered)} 道到「${next.name}」',
                      style: TextStyle(fontSize: 10.5, color: AppColor.sub),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              radar,
            ],
          ),
        ),
        const SizedBox(height: 7),
        Text('战力图：答对的领域往外长，答错、跳过往里收。',
            style: TextStyle(fontSize: 10.5, color: AppColor.sub)),
        const SizedBox(height: 18),
        Text('再来一轮，题数', style: TextStyle(fontSize: 11.5, color: AppColor.sub)),
        const SizedBox(height: 5),
        Text(
          '平时只问今天「${DailyFocus.today.name}」这一门；选「全部」则四门全开，题库现在有 $total 道，还会继续加。',
          style: TextStyle(fontSize: 10.5, height: 1.5, color: AppColor.sub),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in kQuizCounts)
              _chip(quizCountLabel(c), c == _count, () => _startRound(c)),
          ],
        ),
        const SizedBox(height: 18),
        SizedBox(
          height: 50,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColor.ink,
              foregroundColor: AppColor.onInk,
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
            onPressed: () => _startRound(),
            child: const Text('继续答题'),
          ),
        ),
        const SizedBox(height: 6),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('回首页', style: TextStyle(fontSize: 12.5, color: AppColor.sub)),
        ),
      ],
    );
  }

  Widget _chip(String label, bool on, VoidCallback tap) {
    return GestureDetector(
      onTap: tap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: on ? AppColor.accentSoft : AppColor.card,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: on ? AppColor.accent : AppColor.line),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12, color: on ? AppColor.accent : AppColor.sub)),
      ),
    );
  }
}
