import 'dart:io';

import 'package:flutter/material.dart';

import 'core.dart';
import 'avatar.dart';
import 'glass.dart';
import 'journal.dart';
import 'outdoor.dart';
import 'qbank.dart';
import 'pages_glass.dart';
import 'pages_portable.dart';
import 'pages_quiz.dart';
import 'pages_rank.dart';
import 'pages_update.dart';
import 'region.dart';
import 'profile.dart';
import 'score.dart';

// ============================================================================
// 记录页
//
// v1.3.0 及以前，这一页是「每天一条汇总」：答题 3/10、播报已完成、打卡已拍。
// 它回答得了「今天做了没有」，回答不了「今天到底听了什么、答了什么」。
//
// 现在改成流水账：每发生一件事就落一条，带上时间。上面是今天的三个数字
// （打卡几杠几、答题几杠几、新闻几条），下面是按时间倒序流动的日志，
// 可以只看打卡、只看答题、只看新闻。
// ============================================================================
class RecordsPage extends StatefulWidget {
  const RecordsPage({super.key});

  @override
  State<RecordsPage> createState() => _RecordsPageState();
}

/// 日志里的一行。事件的展示形态和存储形态分开：
/// 老数据没有流水，得从每日汇总里合成几行出来，否则升级后历史看着像被清空了。
class _Row {
  final int ts;
  final JKind kind;
  final String title;
  final String detail;
  final String tag;
  final String verdict;
  final bool spoken;

  _Row({
    required this.ts,
    required this.kind,
    required this.title,
    this.detail = '',
    this.tag = '',
    this.verdict = 'neutral',
    this.spoken = false,
  });

  factory _Row.of(JEvent e) => _Row(
        ts: e.ts,
        kind: e.kind,
        title: e.title,
        detail: e.detail,
        tag: e.tag,
        verdict: e.verdict,
        spoken: e.spoken,
      );

  String get hhmm {
    final t = DateTime.fromMillisecondsSinceEpoch(ts);
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }
}

class _RecordsPageState extends State<RecordsPage> {
  int _tab = 0; // 0 = 今天，1 = 本月
  JKind? _filter; // null = 全部
  final Set<String> _open = {}; // 展开了详情的行（ts + 标题做键）

  static const _weekday = ['一', '二', '三', '四', '五', '六', '日'];

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 32),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Text('记录',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.w300)),
              const Spacer(),
              _tabButton('今天', 0),
              const SizedBox(width: 6),
              _tabButton('${now.month} 月', 1),
            ],
          ),
          const SizedBox(height: 16),
          if (_tab == 0) ..._todayBody() else ..._monthBody(),
        ],
      ),
    );
  }

  Widget _tabButton(String text, int value) {
    final on = _tab == value;
    return GestureDetector(
      onTap: () => setState(() => _tab = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
        decoration: BoxDecoration(
          color: on ? AppColor.ink : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: on ? AppColor.ink : AppColor.line),
        ),
        child: Text(
          text,
          style: TextStyle(fontSize: 12, color: on ? AppColor.onInk : AppColor.sub),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 今天
  List<Widget> _todayBody() {
    final now = DateTime.now();
    final today = Store.today;
    final stat = Journal.statOf(today, legacy: _legacyRecord(today));
    final rows = _rowsOf(today).where(_pass).toList();

    return [
      _summaryCard(
        title: '${now.month} 月 ${now.day} 日 · 周${_weekday[now.weekday - 1]}',
        right: '连续 ${Store.streak} 天',
        cells: [
          _Cell('打卡', stat.checkedIn ? '1/1' : '0/1', stat.checkedIn ? '已记录' : '还没打卡'),
          // 答题和新闻只报「今天累计」，不写成 24/10 这种分数。
          // 分子是全天累加、分母是单轮计划，一天跑两轮就会出现「24/10」——
          // 一个自相矛盾的数字，比不显示更糟。打卡有明确目标（今天做了没有），
          // 所以只有它保留几杠几。
          _Cell('答题', '${stat.quizTotal}',
              stat.quizTotal == 0 ? '还没开始' : '对 ${stat.quizCorrect} 道'),
          _Cell('新闻', '${stat.news}',
              stat.news == 0
                  ? '还没播报'
                  : (stat.newsSpoken > 0 ? '听过 ${stat.newsSpoken} 条' : '只看未听')),
        ],
      ),
      const SizedBox(height: 16),
      _filterBar(),
      const SizedBox(height: 12),
      if (rows.isEmpty)
        _empty('今天还没有记录。\n完成一次晨间流程，这里会一条条长出来。')
      else
        ..._timeline(rows),
      const SizedBox(height: 18),
      _photoStrip(today),
    ];
  }

  // ---------------------------------------------------------------- 本月
  List<Widget> _monthBody() {
    final now = DateTime.now();
    final ms = Journal.statOfMonth(now.year, now.month);
    final days = _monthDays();
    final rows = _monthRows(days);

    return [
      _summaryCard(
        title: '${now.year} 年 ${now.month} 月',
        right: '打卡 ${ms.checkinDays} 天',
        cells: [
          _Cell('醒来', '${ms.activeDays}/${now.day}', '本月有记录的天数'),
          _Cell('答题', '${ms.quizTotal}',
              ms.quizTotal == 0 ? '还没答过' : '答对 ${ms.quizCorrect} 道'),
          _Cell('新闻', '${ms.news}', ms.news == 0 ? '还没播报' : '本月光看/听过的'),
        ],
      ),
      const SizedBox(height: 16),
      _filterBar(),
      const SizedBox(height: 12),
      if (rows.isEmpty)
        _empty('这个月还没有和「${_filter == null ? '记录' : kJKindLabel[_filter]}」有关的条目。')
      else
        ...rows,
    ];
  }

  /// 本月所有有记录的日期，新的一天在前。
  List<String> _monthDays() {
    final now = DateTime.now();
    final days = <String>{};
    for (final e in Journal.inMonth(now.year, now.month)) {
      days.add(e.dateKey);
    }
    for (final r in Store.records) {
      final p = r.date.split('-');
      if (p.length != 3) continue;
      if (int.tryParse(p[0]) != now.year || int.tryParse(p[1]) != now.month) continue;
      if (r.completed) days.add(r.date);
    }
    return days.toList()..sort((a, b) => b.compareTo(a));
  }

  List<Widget> _monthRows(List<String> days) {
    final out = <Widget>[];
    for (final d in days) {
      final rows = _rowsOf(d).where(_pass).toList();
      if (rows.isEmpty) continue;
      out.add(Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 8),
        child: Row(
          children: [
            Text(_dayLabel(d), style: TextStyle(fontSize: 12, color: AppColor.sub)),
            const SizedBox(width: 10),
            Expanded(child: Divider(color: AppColor.line, height: 1)),
            const SizedBox(width: 10),
            Text('${rows.length} 条', style: TextStyle(fontSize: 10.5, color: AppColor.sub)),
          ],
        ),
      ));
      out.addAll(_timeline(rows, dense: true));
      out.add(const SizedBox(height: 8));
    }
    return out;
  }

  String _dayLabel(String date) {
    final p = date.split('-');
    if (p.length != 3) return date;
    final m = int.tryParse(p[1]) ?? 0;
    final d = int.tryParse(p[2]) ?? 0;
    final dt = DateTime.tryParse(date);
    final w = dt == null ? '' : ' 周${_weekday[dt.weekday - 1]}';
    return '$m 月 $d 日$w';
  }

  // ---------------------------------------------------------------- 组织
  bool _pass(_Row r) => _filter == null || r.kind == _filter;

  /// 某天的所有行，新的在上。
  ///
  /// 没有流水的日子（升级前的历史）用每日汇总合成两行，
  /// 让「这个月我确实起过 12 天」这件事不要凭空消失。
  List<_Row> _rowsOf(String date) {
    final rows = Journal.onDay(date).map(_Row.of).toList();
    if (rows.isNotEmpty) return rows;

    final rec = _legacyRecord(date);
    if (rec == null) return const [];
    final at = rec.wokeAt > 0 ? rec.wokeAt : DateTime.parse(date).millisecondsSinceEpoch;
    final out = <_Row>[];
    if (rec.quizTotal > 0) {
      out.add(_Row(
        ts: at + 600000,
        kind: JKind.quiz,
        title: '答题 ${rec.quizCorrect}/${rec.quizTotal}',
        detail: '这一天的逐题明细没有留存（v1.3.0 之前只记汇总）。',
        tag: '汇总',
      ));
    }
    if (rec.newsDone) {
      out.add(_Row(
        ts: at + 1200000,
        kind: JKind.news,
        title: '完成了新闻播报',
        detail: '具体播了哪几条没有留存（v1.3.0 之前只记汇总）。',
        tag: '汇总',
      ));
    }
    if (rec.photoPath.isNotEmpty) {
      out.add(_Row(
        ts: at + 1800000,
        kind: JKind.checkin,
        title: '出门打卡',
        detail: '照片还在，可以点上面的缩略图看。',
        verdict: 'right',
      ));
    }
    return out;
  }

  MorningRecord? _legacyRecord(String date) {
    for (final r in Store.records) {
      if (r.date == date) return r;
    }
    return null;
  }

  Widget _filterBar() {
    final items = <(JKind?, String)>[
      (null, '全部'),
      (JKind.checkin, '打卡'),
      (JKind.quiz, '答题'),
      (JKind.news, '新闻'),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final it in items) ...[
            GestureDetector(
              onTap: () => setState(() => _filter = it.$1),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: _filter == it.$1 ? AppColor.accentSoft : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                      color: _filter == it.$1 ? AppColor.accent : AppColor.line),
                ),
                child: Text(
                  it.$2,
                  style: TextStyle(
                    fontSize: 12,
                    color: _filter == it.$1 ? AppColor.accent : AppColor.sub,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 时间轴
  List<Widget> _timeline(List<_Row> rows, {bool dense = false}) {
    final out = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      out.add(_line(rows[i], last: i == rows.length - 1, dense: dense));
    }
    return out;
  }

  Widget _line(_Row r, {required bool last, bool dense = false}) {
    final key = '${r.ts}·${r.title}';
    final open = _open.contains(key);
    final hasDetail = r.detail.isNotEmpty;

    var dot = AppColor.accent;
    if (r.verdict == 'right') dot = AppColor.ok;
    if (r.verdict == 'wrong') dot = const Color(0xFFD08A6A);

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 42,
            child: Padding(
              padding: const EdgeInsets.only(top: 13),
              child: Text(
                dense ? '' : r.hhmm,
                style: TextStyle(fontSize: 10.5, color: AppColor.sub),
              ),
            ),
          ),
          // 竖线 + 圆点：让「一条接一条」这件事在视觉上是连续的
          SizedBox(
            width: 16,
            child: Column(
              children: [
                const SizedBox(height: 14),
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: dot),
                ),
                if (!last)
                  Expanded(
                    child: Container(width: 1, color: AppColor.line),
                  ),
              ],
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: hasDetail
                  ? () => setState(() {
                        if (open) {
                          _open.remove(key);
                        } else {
                          _open.add(key);
                        }
                      })
                  : null,
              behavior: HitTestBehavior.opaque,
              child: Container(
                margin: const EdgeInsets.only(left: 6, bottom: 8),
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                decoration: BoxDecoration(
                  color: AppColor.glassCard,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColor.glassEdge),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (dense)
                          Text(r.hhmm,
                              style: TextStyle(fontSize: 10, color: AppColor.sub)),
                        if (dense) const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            r.title,
                            maxLines: open ? 6 : 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13, height: 1.45),
                          ),
                        ),
                        if (r.tag.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Text(r.tag,
                              style: TextStyle(fontSize: 10, color: AppColor.accent)),
                        ],
                        if (r.kind == JKind.news) ...[
                          const SizedBox(width: 6),
                          Icon(
                            r.spoken ? Icons.volume_up_outlined : Icons.visibility_outlined,
                            size: 13,
                            color: AppColor.sub,
                          ),
                        ],
                      ],
                    ),
                    if (open && hasDetail) ...[
                      const SizedBox(height: 8),
                      Text(
                        r.detail,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.7,
                          color: AppColor.sub,
                        ),
                      ),
                    ] else if (hasDetail)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '展开',
                          style: TextStyle(fontSize: 10, color: AppColor.sub),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 卡片
  Widget _summaryCard({
    required String title,
    required String right,
    required List<_Cell> cells,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: AppColor.glassCard,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColor.glassEdge),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(title, style: const TextStyle(fontSize: 13)),
              const Spacer(),
              Text(right, style: TextStyle(fontSize: 11.5, color: AppColor.accent)),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final c in cells) Expanded(child: _cell(c)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _cell(_Cell c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          c.value,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w300,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 4),
        Text(c.label, style: const TextStyle(fontSize: 11.5)),
        const SizedBox(height: 2),
        Text(c.note,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10, color: AppColor.sub)),
      ],
    );
  }

  Widget _empty(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 42),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12.5, height: 1.8, color: AppColor.sub),
        ),
      ),
    );
  }

  /// 今天的打卡照片。有就看得到，没有就整块不出现——
  /// 空占位比没有更让人在意。
  Widget _photoStrip(String date) {
    final rec = _legacyRecord(date);
    if (rec == null || !fileExists(rec.photoPath)) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('今天的打卡', style: TextStyle(fontSize: 12, color: AppColor.sub)),
        const SizedBox(height: 10),
        GestureDetector(
          onTap: () => _openPhoto(rec),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              height: 160,
              width: double.infinity,
              child: Image.file(File(rec.photoPath), fit: BoxFit.cover),
            ),
          ),
        ),
      ],
    );
  }

  /// 点照片看大图。打卡照片是每天唯一的「证据」，值得单独铺满一屏看，
  /// 而不是被挤在几十像素的小方块里。
  void _openPhoto(MorningRecord r) {
    showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.88),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: InteractiveViewer(
                  maxScale: 4,
                  child: Image.file(File(r.photoPath)),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${r.date} 的早晨',
                    style: const TextStyle(fontSize: 13, color: Colors.white)),
                const SizedBox(width: 18),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('关闭', style: TextStyle(color: Colors.white70)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Cell {
  final String label;
  final String value;
  final String note;
  const _Cell(this.label, this.value, this.note);
}

// ============================================================================
// 画像卡片
//
// 刻意把「看不清」也画出来：置信度不够的维度显示为一条空槽和「—」，
// 而不是给个看似精确的百分比。宁可承认不知道，也别编一个数糊弄人。
// ============================================================================
class _ProfileCard extends StatelessWidget {
  final Profile profile;
  final Future<void> Function() onReset;

  /// 清空或答完题回来之后，让上层的画像重新读一遍
  final VoidCallback onRefresh;

  const _ProfileCard({
    required this.profile,
    required this.onReset,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final axes = [...kAxes]
      ..sort((a, b) => (p.score[b] ?? 0).compareTo(p.score[a] ?? 0));
    var maxV = 0.001;
    for (final a in axes) {
      final v = p.score[a] ?? 0;
      if (v > maxV) maxV = v;
    }
    final answered = p.answered.length;

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 6),
      decoration: BoxDecoration(
        color: AppColor.glassCard,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColor.glassEdge),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('画像', style: TextStyle(fontSize: 15)),
              const Spacer(),
              Text('清晰度 ${(p.clarity * 100).round()}%',
                  style: TextStyle(fontSize: 11, color: AppColor.sub)),
            ],
          ),
          const SizedBox(height: 12),
          // v1.15.0：总分就摆在这里。
          // 画像回答「我是谁」，分数回答「我答出来多少」——两张账并排放，
          // 用户一眼就能对上：偏哪块、在那一块答得怎么样。
          Builder(builder: (context) {
            final s = ScoreBook.instance;
            return Container(
              padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
              decoration: BoxDecoration(
                color: AppColor.accentSoft,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('总分',
                          style: TextStyle(fontSize: 10.5, color: AppColor.sub)),
                      const SizedBox(height: 1),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('${s.total}',
                              style: const TextStyle(
                                  fontSize: 30,
                                  height: 1.05,
                                  fontWeight: FontWeight.w300)),
                          Padding(
                            padding: const EdgeInsets.only(left: 3, bottom: 4),
                            child: Text('分',
                                style: TextStyle(
                                    fontSize: 10.5, color: AppColor.sub)),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const Spacer(),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('答对 ${s.right} · 答错 ${s.wrong}',
                          style: const TextStyle(fontSize: 11.5)),
                      const SizedBox(height: 3),
                      Text('正确率 ${s.accuracy}% · 跳过 ${s.skipped}',
                          style:
                              TextStyle(fontSize: 10, color: AppColor.sub)),
                      const SizedBox(height: 2),
                      Text('答对 +1 · 答错 −1',
                          style:
                              TextStyle(fontSize: 10, color: AppColor.sub)),
                    ],
                  ),
                ],
              ),
            );
          }),
          const SizedBox(height: 8),
          Text(p.describe(),
              style: TextStyle(
                fontSize: 12.5,
                height: 1.7,
                color: AppColor.isDark ? AppColor.sub : const Color(0xFF4A453D),
              )),
          const SizedBox(height: 12),
          // 树上的纹理。
          //
          // 十维条只说明「你偏哪一类」，回答不了「你在哪条路上走过」。
          // 没有这一块，答十道和答一千道的画像页看起来是一样的——
          // 这正是 v1.x 最大的问题：有轮廓，没纹理。
          _texture(p),
          const SizedBox(height: 14),
          // 只展开前 5 个，其余压成一行。
          // 十个横条会把「权限诊断」这类应急入口顶出首屏，不值得。
          for (final a in axes.take(5)) _bar(p, a, maxV),
          if (axes.skip(5).any((a) => p.confidenceOf(a) < 0.35))
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '暂未看清：${axes.skip(5).where((a) => p.confidenceOf(a) < 0.35).join(' · ')}',
                style: TextStyle(fontSize: 10.5, height: 1.6, color: AppColor.sub),
              ),
            ),
          Text(
            '条越长，说明它在你的选择里出现得越多；「—」是样本还不够，先不下结论。',
            style: TextStyle(fontSize: 10, height: 1.6, color: AppColor.sub),
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Text('已答 $answered 题 · 全部在本地',
                  style: TextStyle(fontSize: 10.5, color: AppColor.sub)),
              const Spacer(),
              TextButton(
                style: TextButton.styleFrom(
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      backgroundColor: AppColor.card,
                      title: const Text('重新开始？', style: TextStyle(fontSize: 16)),
                      content: const Text(
                          '会清空已经积累的画像和答过的题，明天开始当作第一次认识你。\n'
                          '下面的生活流水不动，那些是你做过的事，不是画像。',
                          style: TextStyle(fontSize: 13, height: 1.6)),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.of(ctx).pop(false),
                            child: Text('先留着', style: TextStyle(color: AppColor.sub))),
                        TextButton(
                            onPressed: () => Navigator.of(ctx).pop(true),
                            child: const Text('清空')),
                      ],
                    ),
                  );
                  if (ok != true) return;
                  await onReset();
                  if (!context.mounted) return;
                  // 清完不能就这么停在这儿——用户上次就是这样：清掉了，
                  // 然后翻遍整个 App 找不到重新答题的地方。
                  onRefresh();
                  await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const QuizPage()),
                  );
                  onRefresh();
                },
                child: Text('重新开始',
                    style: TextStyle(fontSize: 11, color: AppColor.sub)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 纹理区块：走到第几层、看清了哪几条路、哪几块先不问。
  Widget _texture(Profile p) {
    final paths = p.clearestTopics(4);
    final avoided = p.avoidedTopics(2);
    final depth = p.drillDepth;
    final depthText = depth <= 1 ? '还在第一层铺轮廓' : '走到第 $depth 层';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(depthText, style: TextStyle(fontSize: 10.5, color: AppColor.sub)),
            const Spacer(),
            // 这里报题库总量，不报「已答」——底下那行已经报了，
            // 两个数字口径不同却并排出现，看起来像在打架。
            Text('题库 ${QBank.instance.total} 道',
                style: TextStyle(fontSize: 10.5, color: AppColor.sub)),
          ],
        ),
        if (paths.isEmpty) ...[
          const SizedBox(height: 4),
          Text('还没走进任何一条路。答题时会按你的选择，往那条路上再走一步。',
              style: TextStyle(fontSize: 10, height: 1.6, color: AppColor.sub)),
        ],
        if (paths.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            decoration: BoxDecoration(
              color: AppColor.glassPanel,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColor.panelLine),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('我看清了这几条路',
                    style: TextStyle(fontSize: 10.5, color: AppColor.sub)),
                const SizedBox(height: 6),
                for (final e in paths)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(e.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11.5)),
                        ),
                        const SizedBox(width: 8),
                        Text('${e.hits} 题',
                            style: TextStyle(fontSize: 10, color: AppColor.sub)),
                      ],
                    ),
                  ),
                if (avoided.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2, bottom: 4),
                    child: Text('这几块先不问：${avoided.join(' · ')}',
                        style: TextStyle(
                            fontSize: 10, height: 1.6, color: AppColor.sub)),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// 单一维度的横条。置信度不足时给一条空槽，不给数字。
  Widget _bar(Profile p, String axis, double maxV) {
    final conf = p.confidenceOf(axis);
    final known = conf >= 0.35;
    final ratio = known ? ((p.score[axis] ?? 0) / maxV).clamp(0.0, 1.0) : 0.0;

    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            child: Text(axis,
                style: TextStyle(
                  fontSize: 11.5,
                  color: known ? AppColor.ink : AppColor.sub,
                )),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: known ? ratio : 0,
                minHeight: 6,
                backgroundColor: AppColor.line,
                valueColor: AlwaysStoppedAnimation<Color>(
                  known ? AppColor.accent.withOpacity(0.7) : AppColor.line,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 12,
            child: Text(
              known ? '' : '—',
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 10.5, color: AppColor.sub),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// 我的页
// ============================================================================
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  String _model = '';
  String _version = '';

  @override
  void initState() {
    super.initState();
    Bridge.deviceInfo().then((v) {
      if (mounted && v != null) {
        setState(() {
          _model = '${v['brand']} ${v['model']} · Android ${v['sdk']}';
          _version = (v['version'] as String?) ?? '';
        });
      }
    });
  }

  void _toast(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  /// v1.17.0：换头像。三条路——拍一张、从相册挑、退回默认图标。
  ///
  /// 拍照和选图都交给原生（见 MainActivity.pickAvatar/shootAvatar），
  /// 原生裁好 256px 再回来，所以这里拿到的就是一个能直接存的 base64。
  /// 「取消」要静默处理：用户点了返回不是错误，弹一句「失败」只会让人以为坏了。
  Future<void> _editAvatar() async {
    final has = Avatar.has;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColor.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColor.sub.withOpacity(0.28),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            Text('换个头像',
                style: TextStyle(fontSize: 14, color: AppColor.sub)),
            const SizedBox(height: 6),
            ListTile(
              leading: Icon(Icons.photo_camera_outlined, color: AppColor.accent),
              title: const Text('拍一张', style: TextStyle(fontSize: 15)),
              onTap: () => Navigator.pop(ctx, 'shoot'),
            ),
            ListTile(
              leading: Icon(Icons.photo_library_outlined, color: AppColor.accent),
              title: const Text('从相册选', style: TextStyle(fontSize: 15)),
              onTap: () => Navigator.pop(ctx, 'pick'),
            ),
            if (has)
              ListTile(
                leading: Icon(Icons.restart_alt, color: AppColor.sub),
                title: Text('恢复默认头像',
                    style: TextStyle(fontSize: 15, color: AppColor.sub)),
                onTap: () => Navigator.pop(ctx, 'clear'),
              ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;

    if (choice == 'clear') {
      await Avatar.clear();
      if (!mounted) return;
      setState(() {});
      _toast('头像已恢复默认');
      return;
    }

    final r = choice == 'shoot' ? await Bridge.shootAvatar() : await Bridge.pickAvatar();
    if (!mounted) return;
    if (r['ok'] == true) {
      final ok = await Avatar.save((r['b64'] ?? '').toString());
      if (!mounted) return;
      setState(() {});
      _toast(ok ? '头像换好了' : '这张图读不出来，换一张试试');
      return;
    }
    final reason = (r['reason'] ?? '').toString();
    if (reason == 'cancel') return; // 用户自己退出来的，不用报错
    _toast(switch (reason) {
      'no_picker' => '这台手机没有可用的相册选择器',
      'no_camera' => '没有找到可用的相机应用',
      'oom' => '图片太大，内存不够处理这张图',
      'busy' => '上一次还没结束，稍等一下',
      'unavailable' => '这个版本还没装好头像功能',
      _ => '这张图读不出来，换一张试试',
    });
  }

  /// v1.17.0：改称呼。空名字会退回默认「晨友」，不留一个没名字的档案。
  Future<void> _editNick() async {
    final ctrl = TextEditingController(text: Nick.current);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColor.card,
        title: const Text('改个称呼', style: TextStyle(fontSize: 16)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: Nick.maxLen,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            hintText: '比如：老张',
            counterText: '',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name == null || !mounted) return;
    await Nick.save(name);
    if (!mounted) return;
    setState(() {});
    _toast('称呼已改');
  }

  @override
  Widget build(BuildContext context) {
    final quiz = Store.i('quizCount', 10);
    final snooze = Store.i('snoozeDefault', 5);
    final avatar = Avatar.image;

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 28),
        children: [
          const Text('我的', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w300)),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: AppColor.glassCard,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColor.glassEdge),
            ),
            child: Row(
              children: [
                // v1.17.0：这块以前是个写死的图标，用户点半天换不了。
                // 现在整块可点，右下角那个小相机就是「这儿能改」的暗示。
                // Semantics 是给读屏用的：纯图形元素不加标签，TalkBack 会念出一个
                // 没有名字的按钮，视障用户根本不知道能点。
                Semantics(
                  button: true,
                  label: avatar == null ? '换头像，当前是默认头像' : '换头像',
                  child: GestureDetector(
                    onTap: _editAvatar,
                    behavior: HitTestBehavior.opaque,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          clipBehavior: Clip.antiAlias,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColor.accentSoft,
                            border: Border.all(color: AppColor.glassEdge),
                          ),
                          child: avatar == null
                              ? Icon(Icons.wb_twilight, color: AppColor.accent, size: 22)
                              : Image(image: avatar, fit: BoxFit.cover),
                        ),
                        Positioned(
                          right: -2,
                          bottom: -2,
                          child: Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: AppColor.card,
                              border: Border.all(color: AppColor.glassEdge),
                            ),
                            child: Icon(Icons.photo_camera, size: 10, color: AppColor.accent),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                // v1.15.0：多了一个「总分」，中间这段必须能收窄。
                // 不套 Expanded 的话，长机型名（「Xiaomi 24018RPACC · Android 16」）
                // 会把右边两个数字挤出屏幕——真机上不报错，只是看不见。
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // v1.17.0：名字也能改。默认还是「晨友」，但不再是写死的。
                      InkWell(
                        onTap: _editNick,
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  Nick.current,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 16),
                                ),
                              ),
                              const SizedBox(width: 4),
                              Icon(Icons.edit_outlined, size: 12, color: AppColor.sub),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _model.isEmpty ? '读设备信息…' : _model,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: AppColor.sub),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('${Store.streak}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w300)),
                    Text('连续天数', style: TextStyle(fontSize: 10, color: AppColor.sub)),
                  ],
                ),
                const SizedBox(width: 14),
                // v1.15.0：总分。同一个位置放两个数，是因为它们都是
                // 「我坚持了多久」的证据——一个是天数，一个是答出来的分。
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('${ScoreBook.instance.total}',
                        style: const TextStyle(
                            fontSize: 22, fontWeight: FontWeight.w300)),
                    Text('总分', style: TextStyle(fontSize: 10, color: AppColor.sub)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _ProfileCard(
            profile: Profile.load(),
            onReset: () async {
              Store.set('profile', '');
              await Store.saveSettings();
              setState(() {});
            },
            onRefresh: () => setState(() {}),
          ),
          const SizedBox(height: 18),
          _section('偏好'),
          _rowTile(
            '默认答题数量',
            quizCountLabel(quiz),
            onTap: () async {
              // 最后一档是「全部」：愿意一次走完整座山的人，得有个地方能选。
              final labels = [for (final c in kQuizCounts) quizCountLabel(c)];
              final v = await _choose('答题数量', labels);
              if (v == null) return;
              final i = labels.indexOf(v);
              Store.set('quizCount', '${i >= 0 ? kQuizCounts[i] : 10}');
              setState(() {});
            },
          ),
          _rowTile(
            '晨序榜',
            rankSummaryLine(),
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const RankPage()),
              );
              if (mounted) setState(() {});
            },
          ),
          _rowTile(
            '总分',
            '${ScoreBook.instance.total} 分 · 对 ${ScoreBook.instance.right} / 错 ${ScoreBook.instance.wrong}',
            onTap: _scoreSheet,
          ),
          _rowTile(
            '默认贪睡时长',
            '$snooze 分钟',
            onTap: () async {
              final v = await _choose('贪睡时长', ['3 分钟', '5 分钟', '10 分钟', '15 分钟']);
              if (v == null) return;
              Store.set('snoozeDefault', v.split(' ').first);
              setState(() {});
            },
          ),
          _rowTile(
            '我住在哪儿',
            Region.load().full,
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const RegionPickPage()),
              );
              if (mounted) setState(() {});
            },
          ),
          const SizedBox(height: 18),
          _section('外观'),
          _navTile('换肤', '${AppColor.pack.name} · 内置 ${kThemes.length} 套配色', const ThemePage()),
          _navTile(
            '界面质感',
            '${Glass.style.name} · 水晶玻璃 / 波光 / 3 套可换',
            const GlassPage(),
          ),
          _rowTile(
            '连续播报语速',
            rateLabel(savedRate()),
            onTap: () async {
              final v = await _choose('播报语速',
                  [for (final o in kRateOptions) o.$1]);
              if (v == null) return;
              final r = kRateOptions.firstWhere(
                (o) => o.$1 == v,
                orElse: () => kRateOptions[1],
              ).$2;
              Store.set('speechRate', r.toStringAsFixed(2));
              await Bridge.setSpeechRate(r);
              if (mounted) setState(() {});
            },
          ),
          const SizedBox(height: 18),
          _section('可靠性'),
          _navTile('权限诊断', '精准闹钟 / 通知 / 相机 / 电池 / 语音', const PermissionsPage()),
          // v1.13.0：出门判定的基准。没有它，打卡就只是一张照片，证明不了「人出去了」
          _navTile('出门基准照', '拍下门外常看到的样子，打卡时用来比对', const OutdoorBaselinePage()),
          _rowTile('测试响铃', '10 秒后触发', onTap: () async {
            await Bridge.ringTest();
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('已设置 10 秒后响铃，请锁屏观察')),
            );
          }),
          const SizedBox(height: 18),
          _section('数据'),
          // v1.15.0：换手机的唯一出口。放在「可靠性」和「关于」之间——
          // 它既不是每天用的功能，也不该藏在关于页里让人找不到。
          _rowTile(
            '数据备份 / 换手机',
            '导出 JSON · 导入可合并或覆盖',
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const DataPortPage()),
              );
              if (mounted) setState(() {});
            },
          ),
          const SizedBox(height: 18),
          _section('关于'),
          _rowTile(
            '版本',
            _version.isEmpty ? '读取中…' : '$_version · 检查更新',
            onTap: () => checkUpdateManually(context),
          ),
          _rowTile('存储位置', '仅本机，可导出备份'),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColor.glassPanel,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              '边界说明：本 App 不承诺「百分之百不会漏响」。部分厂商的后台限制可能导致延迟触发，请配合权限诊断页逐项检查。照片仅保存在本机应用私有目录，不上传服务器。',
              style: TextStyle(
                  fontSize: 11.5,
                  height: 1.7,
                  color: AppColor.isDark ? AppColor.sub : const Color(0xFF6B5A45)),
            ),
          ),
        ],
      ),
    );
  }

  /// 分数的说明弹层。规则必须一句话讲得清，否则用户只会觉得「分怎么少了」。
  void _scoreSheet() {
    final s = ScoreBook.instance;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColor.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('${s.total}',
                      style: const TextStyle(
                          fontSize: 34, height: 1.1, fontWeight: FontWeight.w300)),
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 4),
                    child: Text('分',
                        style: TextStyle(fontSize: 12, color: AppColor.sub)),
                  ),
                  const Spacer(),
                  Text('已答 ${s.answered} 题',
                      style: TextStyle(fontSize: 11, color: AppColor.sub)),
                ],
              ),
              const SizedBox(height: 16),
              _scoreLine('答对一题', '+1', '完全选对才加分'),
              _scoreLine('答错一题', '−1', '多选没选全也算答错'),
              _scoreLine('跳过一题', '0', '跳过是「这块先不问」，不罚分'),
              _scoreLine('偏好题', '0', '没有标准答案，只算接触过'),
              const SizedBox(height: 8),
              Text(
                '答对 ${s.right} · 答错 ${s.wrong} · 跳过 ${s.skipped} · '
                '正确率 ${s.accuracy}%（只算有对错的题）',
                style: TextStyle(fontSize: 11, height: 1.6, color: AppColor.sub),
              ),
              const SizedBox(height: 6),
              Text('分数可以是负的——答得比错得少，账就该是负的，不替你抹平。',
                  style: TextStyle(fontSize: 10.5, height: 1.6, color: AppColor.sub)),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('知道了')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _scoreLine(String label, String value, String note) => Padding(
        padding: const EdgeInsets.only(bottom: 9),
        child: Row(
          children: [
            SizedBox(
                width: 74,
                child: Text(label, style: const TextStyle(fontSize: 12.5))),
            SizedBox(
                width: 34,
                child: Text(value,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w500))),
            Expanded(
                child: Text(note,
                    style: TextStyle(fontSize: 10.5, color: AppColor.sub))),
          ],
        ),
      );

  Future<String?> _choose(String title, List<String> options) {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColor.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(title, style: TextStyle(fontSize: 14, color: AppColor.sub)),
            ),
            for (final o in options)
              ListTile(
                title: Text(o, style: const TextStyle(fontSize: 15)),
                onTap: () => Navigator.of(ctx).pop(o),
              ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text(t,
            style: TextStyle(fontSize: 11.5, color: AppColor.sub, letterSpacing: 1)),
      );

  Widget _rowTile(String title, String value, {VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        decoration: BoxDecoration(
          color: AppColor.glassCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColor.glassEdge),
        ),
        child: Row(
          children: [
            Text(title, style: const TextStyle(fontSize: 14)),
            const Spacer(),
            Text(value, style: TextStyle(fontSize: 12.5, color: AppColor.sub)),
            if (onTap != null) ...[
              const SizedBox(width: 6),
              Icon(Icons.chevron_right, size: 16, color: AppColor.sub),
            ],
          ],
        ),
      ),
    );
  }

  Widget _navTile(String title, String sub, Widget page) {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page)),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        decoration: BoxDecoration(
          color: AppColor.glassCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColor.glassEdge),
        ),
        child: Row(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 14)),
                const SizedBox(height: 4),
                Text(sub, style: TextStyle(fontSize: 11, color: AppColor.sub)),
              ],
            ),
            const Spacer(),
            Icon(Icons.chevron_right, size: 16, color: AppColor.sub),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// 权限诊断页（P0 要求：展示状态、系统设置入口、最近触发记录、测试闹钟）
// ============================================================================
class PermissionsPage extends StatefulWidget {
  const PermissionsPage({super.key});

  @override
  State<PermissionsPage> createState() => _PermissionsPageState();
}

class _PermissionsPageState extends State<PermissionsPage> {
  bool? _exact;
  bool? _notify;
  bool? _camera;
  bool? _fsi;
  bool? _battery;
  bool? _tts;
  String _ttsState = 'init';
  int _lastTrigger = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final exact = await Bridge.canScheduleExact();
    final notify = await Bridge.hasNotificationPermission();
    final cam = await Bridge.requestPermission('check_camera');
    final fsi = await Bridge.canUseFsi();
    final battery = await Bridge.isIgnoringBattery();
    final tts = await Bridge.ttsStatusAwait();
    final lt = int.tryParse(Store.s('lastTrigger', '0')) ?? 0;
    if (mounted) {
      setState(() {
        _exact = exact;
        _notify = notify;
        _camera = cam;
        _fsi = fsi;
        _battery = battery;
        _ttsState = (tts['state'] as String?) ?? 'init';
        _tts = _ttsState == 'ready';
        _lastTrigger = lt;
      });
    }
  }

  /// 试听：真发一句话给引擎。既能验证出声，也能把引擎首次使用时要弹的
  /// 协议/授权页提前暴露出来——用户点完同意，后面播报就不会再被打断。
  Future<void> _ttsTry() async {
    // 引擎可能被系统回收了（熄屏一夜最常见）。先重建一次再试，
    // 这类一次性故障重试就能恢复，不该让用户以为语音彻底坏了。
    if (_ttsState != 'ready') {
      await Bridge.retryTts();
      if (!mounted) return;
      final s0 = await Bridge.ttsStatusAwait(timeoutMs: 6000);
      if (!mounted) return;
      final st0 = (s0['state'] as String?) ?? _ttsState;
      setState(() {
        _ttsState = st0;
        _tts = st0 == 'ready';
      });
    }
    final r = await Bridge.speak('晨序语音测试，一二三四五');
    if (!mounted) return;
    if (r['ok'] != true) {
      final st = (r['state'] as String?) ?? _ttsState;
      setState(() {
        _ttsState = st;
        _tts = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(duration: const Duration(seconds: 7), content: Text(Bridge.ttsStateText(st))),
      );
      return;
    }
    // 引擎是异步合成的，等它真正开始再判断
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    final s = await Bridge.ttsStatus();
    if (!mounted) return;
    final speaking = s['speaking'] == true;
    final st = (s['state'] as String?) ?? _ttsState;
    setState(() {
      _ttsState = st;
      _tts = st == 'ready';
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 8),
        content: Text(speaking
            ? '引擎已开始朗读，能听到声音就说明正常'
            : '引擎没有开始朗读。如果刚才弹出了「系统语音引擎」的协议或授权页，'
                '请点同意后再试听一次；同意之前它是不会出声的。'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text('权限诊断', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
        actions: [
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh, size: 20)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        children: [
          _item(
            '精准闹钟',
            _exact,
            'Android 12 起需要「闹钟和提醒」权限，否则系统会把闹钟当作普通任务延后。',
            () => Bridge.openSettings('exact_alarm'),
            request: () => Bridge.openSettings('exact_alarm'),
          ),
          _item(
            '通知权限',
            _notify,
            '通知用于响铃兜底与提醒；被关闭后只能靠全屏响铃页，容易错过。',
            () => Bridge.openSettings('notification'),
            request: () async {
              await Bridge.requestPermission('notification');
              _refresh();
            },
          ),
          _item(
            '全屏通知',
            _fsi,
            'Android 14 起这是独立开关。关掉后锁屏不会弹出响铃页，只会剩一条横幅，等于叫不醒。',
            () => Bridge.openSettings('fsi'),
            request: () => Bridge.openSettings('fsi'),
          ),
          _item(
            '相机权限',
            _camera,
            '打卡需要调用系统相机拍一张照片，照片只存在本机。',
            () => Bridge.openSettings('app_details'),
            request: () async {
              await Bridge.requestPermission('camera');
              _refresh();
            },
          ),
          _item(
            '电池优化 / 后台运行',
            _battery,
            '国产 ROM 建议：允许自启动、允许后台运行、电池优化选「不限制」，否则可能延迟响铃。',
            () => Bridge.openSettings('battery_request'),
            request: () => Bridge.openSettings('battery_request'),
          ),
          _item(
            '语音朗读',
            _tts,
            '${Bridge.ttsStateText(_ttsState)}。播报新闻要靠系统语音引擎，引擎或中文语音包缺任意一个，'
                '朗读都只会静默不出声（其它流程不受影响）。首次使用引擎时，它自己会弹协议与授权页，'
                '必须点同意，否则不会出声。',
            () => Bridge.openSettings('tts'),
            extra: TextButton(
              onPressed: _ttsTry,
              child: const Text('试听', style: TextStyle(fontSize: 12)),
            ),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColor.glassCard,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColor.glassEdge),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('最近一次触发', style: TextStyle(fontSize: 13)),
                const SizedBox(height: 8),
                Text(
                  _lastTrigger == 0
                      ? '暂无记录。完成一次晨间流程后这里会记录时间。'
                      : '${DateTime.fromMillisecondsSinceEpoch(_lastTrigger)}',
                  style: TextStyle(fontSize: 12, color: AppColor.sub),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 50,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColor.ink,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              onPressed: () async {
                await Bridge.ringTest();
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('10 秒后响铃，请回到桌面或锁屏观察')),
                );
              },
              child: const Text('测试响铃（10 秒后）'),
            ),
          ),
          const SizedBox(height: 10),
          Center(
            child: Text('测试会走完整链路：系统闹钟 → 全屏响铃页 → 起床进入流程',
                style: TextStyle(fontSize: 11, color: AppColor.sub)),
          ),
        ],
      ),
    );
  }

  Widget _item(String title, bool? ok, String desc, VoidCallback open,
      {Future<void> Function()? request, Widget? extra}) {
    final statusText = ok == null ? '需手动确认' : (ok ? '已开启' : '未开启');
    final color = ok == null ? AppColor.sub : (ok ? AppColor.ok : const Color(0xFFB4543F));
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColor.glassCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColor.glassEdge),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(title, style: const TextStyle(fontSize: 14.5)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(statusText, style: TextStyle(fontSize: 11, color: color)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(desc, style: TextStyle(fontSize: 11.5, height: 1.6, color: AppColor.sub)),
          const SizedBox(height: 10),
          Row(
            children: [
              if (request != null && ok == false)
                TextButton(
                  onPressed: () => request(),
                  child: const Text('申请权限', style: TextStyle(fontSize: 12)),
                ),
              if (extra != null) extra,
              TextButton(
                onPressed: open,
                child: Text('打开系统设置', style: TextStyle(fontSize: 12, color: AppColor.sub)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 换肤页：内置配色 + 每套的实时小预览。
/// 选完立刻生效（AppColor.apply 会触发根节点重建），不需要重启。
class ThemePage extends StatefulWidget {
  const ThemePage({super.key});

  @override
  State<ThemePage> createState() => _ThemePageState();
}

class _ThemePageState extends State<ThemePage> {
  void _pick(ThemePack t) {
    AppColor.apply(t.id);
    Store.set('themeId', t.id);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Text('换肤', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        iconTheme: IconThemeData(color: AppColor.ink),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 6, 18, 30),
        children: [
          Text('选一套喜欢的，立刻生效，也会记住。',
              style: TextStyle(fontSize: 12.5, color: AppColor.sub, height: 1.6)),
          const SizedBox(height: 16),
          for (final t in kThemes) _themeCard(t),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColor.glassCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColor.glassEdge),
            ),
            child: Text(
              '更多配色（自定义取色、在线主题包）在下一版。V1 先把「能换」这件事做通，'
              '保证换完每一页的文字都还看得清。',
              style: TextStyle(fontSize: 11.5, color: AppColor.sub, height: 1.75),
            ),
          ),
        ],
      ),
    );
  }

  Widget _themeCard(ThemePack t) {
    final active = AppColor.pack.id == t.id;
    return GestureDetector(
      onTap: () => _pick(t),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColor.glassCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: active ? t.accent : AppColor.line,
            width: active ? 1.6 : 1,
          ),
        ),
        child: Row(
          children: [
            // 迷你预览：底色上放一条标题、一条正文、一个强调块
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: t.bg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: t.line),
              ),
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(width: 26, height: 5, color: t.ink),
                  const SizedBox(height: 5),
                  Container(width: 38, height: 3, color: t.sub),
                  const Spacer(),
                  Container(width: 20, height: 8, color: t.accent),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(t.name,
                          style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w600,
                              color: AppColor.ink)),
                      if (t.dark) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColor.accentSoft,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text('深色',
                              style: TextStyle(fontSize: 9.5, color: AppColor.accent)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(t.desc,
                      style: TextStyle(fontSize: 11.5, color: AppColor.sub)),
                ],
              ),
            ),
            if (active)
              Icon(Icons.check_circle, size: 20, color: AppColor.accent)
            else
              Icon(Icons.circle_outlined, size: 20, color: AppColor.line),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// 出门基准照（v1.13.0）
//
// 用户的原话是：「怎么才能确定他出门和没出门？……必须要让他拍生活上能拍到的
// 图片、路边、电梯、门口、小区门口这些图片。」
//
// 这里就是收这几张基准的地方。打卡时的比对逻辑在 lib/outdoor.dart：
// 把新照片缩到 24×24 灰度，和每张基准算归一化相关，取最高分。
// 它判的不是「这是哪条街」，而是「这张画面像不像你平常出门看到的样子」——
// 要求再高就得引入定位/步数/场景识别，那是 V2 的出门证据链。
// ============================================================================

class OutdoorBaselinePage extends StatefulWidget {
  const OutdoorBaselinePage({super.key});

  @override
  State<OutdoorBaselinePage> createState() => _OutdoorBaselinePageState();
}

class _OutdoorBaselinePageState extends State<OutdoorBaselinePage> {
  static const _tags = ['门口', '电梯', '路边', '小区门口'];
  String _tag = '门口';
  List<Map<String, String>> _list = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    if (!mounted) return;
    setState(() => _list = Outdoor.all());
  }

  void _toast(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  Future<void> _shoot() async {
    final p = await Bridge.takePhoto();
    if (!mounted) return;
    if (p == null || p.isEmpty) {
      _toast('未获取到照片（可能取消了拍摄或未授予相机权限）');
      return;
    }
    await Outdoor.add(p, _tag);
    _load();
    _toast('已登记「$_tag」基准照（共 ${Outdoor.all().length} 张）');
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('清空基准照？'),
        content: const Text('清空后打卡不再做比对，只保留照片作证。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('清空')),
        ],
      ),
    );
    if (ok != true) return;
    Outdoor.clear();
    _load();
    _toast('已清空');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text('出门基准照',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColor.glassPanel,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              '先拍几张你平常出门看到的画面：门口、电梯、路边、小区门口各一张最好。\n\n'
              '打卡时 App 会拿新照片跟这些比对：像 → 判定已在门外；不像 → 提示你重拍。'
              '它的作用是让「躺着拍天花板」过不去，不是密码级验证——夜里和大雾天判定会变宽松。',
              style: TextStyle(fontSize: 12, height: 1.75, color: AppColor.sub),
            ),
          ),
          const SizedBox(height: 18),
          Text('这次拍的是', style: TextStyle(fontSize: 12, color: AppColor.sub)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _tags
                .map((t) => ChoiceChip(
                      label: Text(t, style: const TextStyle(fontSize: 12)),
                      selected: _tag == t,
                      onSelected: (_) => setState(() => _tag = t),
                      selectedColor: AppColor.accentSoft,
                      backgroundColor: AppColor.glassCard,
                      side: BorderSide(color: AppColor.glassEdge),
                      showCheckmark: false,
                    ))
                .toList(),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 50,
            child: FilledButton.icon(
              onPressed: _shoot,
              icon: const Icon(Icons.camera_alt_outlined, size: 18),
              label: Text(_list.isEmpty ? '拍第一张基准照' : '再拍一张（$_tag）'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColor.ink,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
          const SizedBox(height: 22),
          Row(
            children: [
              Text('已登记 ${_list.length} 张',
                  style: TextStyle(fontSize: 12, color: AppColor.sub)),
              const Spacer(),
              if (_list.isNotEmpty)
                TextButton(onPressed: _clear, child: const Text('清空', style: TextStyle(fontSize: 12))),
            ],
          ),
          const SizedBox(height: 6),
          if (_list.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 34),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColor.glassCard,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColor.glassEdge),
              ),
              child: Text('还没有基准照，打卡时不会比对',
                  style: TextStyle(fontSize: 12, color: AppColor.sub)),
            )
          else
            ..._list.map((e) => Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColor.glassCard,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColor.glassEdge),
                  ),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.file(
                          File(e['path']!),
                          width: 62,
                          height: 62,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            width: 62,
                            height: 62,
                            color: AppColor.line.withOpacity(0.3),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(e['tag']!.isEmpty ? '未命名' : e['tag']!,
                            style: const TextStyle(fontSize: 13)),
                      ),
                      IconButton(
                        icon: Icon(Icons.close, size: 18, color: AppColor.sub),
                        onPressed: () async {
                          await Outdoor.remove(e['path']!);
                          _load();
                        },
                      ),
                    ],
                  ),
                )),
        ],
      ),
    );
  }
}
