import 'dart:async';

import 'package:flutter/material.dart';

import 'core.dart';
import 'focus.dart';
import 'journal.dart';
import 'pages_more.dart';
import 'pages_quiz.dart';
import 'pages_rank.dart';
import 'profile.dart';
import 'qbank.dart';
import 'rank.dart';

class HomePage extends StatefulWidget {
  final VoidCallback onStartMorning;

  const HomePage({super.key, required this.onStartMorning});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late Timer _timer;
  DateTime _now = DateTime.now();
  bool _exactOk = true;
  bool _notifyOk = true;

  /// 答题进度。放在这里而不是每次 build 都读一遍——profile 里可能有
  /// 三千多条已答记录，跟着秒针每 20 秒解析一次不值当。
  late Profile _profile;

  @override
  void initState() {
    super.initState();
    _profile = Profile.load();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    _checkPerms();
  }

  Future<void> _openQuiz() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const QuizPage()),
    );
    if (!mounted) return;
    setState(() => _profile = Profile.load());
  }

  Future<void> _openRank() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const RankPage()),
    );
    if (!mounted) return;
    setState(() => _profile = Profile.load());
  }

  Future<void> _checkPerms() async {
    final a = await Bridge.canScheduleExact();
    final b = await Bridge.hasNotificationPermission();
    if (mounted) {
      setState(() {
        _exactOk = a;
        _notifyOk = b;
      });
    }
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final next = Store.nextAlarm();
    final nextAt = next?.nextTrigger(_now);
    final today = Store.todayRecord();
    // 三行状态改由日志派生：原来答题看 records.quizTotal、打卡看 photoPath，
    // 与记录页是两套口径——跳过拍照时日志记「已打卡」，首页却显示未打勾。
    final day = Journal.statOf(Store.today, legacy: today);

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 28),
        children: [
          // 顶部问候
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      greeting(_now),
                      style: TextStyle(
                        fontSize: 15,
                        color: AppColor.sub,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${_now.month} 月 ${_now.day} 日  周${'一二三四五六日'[_now.weekday - 1]}',
                      style: TextStyle(fontSize: 13, color: AppColor.sub),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: AppColor.accentSoft,
                  borderRadius: BorderRadius.circular(30),
                ),
                child: Text(
                  '连续 ${Store.streak} 天',
                  style: TextStyle(fontSize: 12, color: AppColor.accent),
                ),
              ),
            ],
          ),
          const SizedBox(height: 26),

          // 当前时间（大数字，极简）
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                hhmm(_now),
                style: const TextStyle(
                  fontSize: 62,
                  height: 1.0,
                  fontWeight: FontWeight.w200,
                  letterSpacing: -2,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 8, bottom: 8),
                child: Text(
                  '${two(_now.second)}"',
                  style: TextStyle(fontSize: 16, color: AppColor.sub),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '让每一个清晨都有意义',
            style: TextStyle(fontSize: 13, color: AppColor.sub, letterSpacing: 2),
          ),

          const SizedBox(height: 26),

          // 权限提示（有问题才出现）
          if (!_exactOk || !_notifyOk) _permBanner(),

          // 下一个闹钟
          _Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('下一个闹钟', style: TextStyle(fontSize: 13, color: AppColor.sub)),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const PermissionsPage()),
                      ),
                      child: Text('诊断', style: TextStyle(fontSize: 12, color: AppColor.accent)),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (next == null)
                  const Text('还没有启用的闹钟', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w300))
                else ...[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        next.timeText,
                        style: const TextStyle(
                          fontSize: 40,
                          height: 1,
                          fontWeight: FontWeight.w300,
                          letterSpacing: -1,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 5),
                        child: Text(
                          next.repeatText,
                          style: TextStyle(fontSize: 13, color: AppColor.sub),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${next.label}  ·  ${nextAt == null ? '' : _countdown(nextAt)}',
                    style: TextStyle(fontSize: 13, color: AppColor.sub),
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 14),

          // 今日晨间
          _Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('今日晨间', style: TextStyle(fontSize: 13, color: AppColor.sub)),
                    const Spacer(),
                    Text(
                      today?.completed == true ? '已完成' : '未完成',
                      style: TextStyle(
                        fontSize: 12,
                        color: today?.completed == true ? AppColor.ok : AppColor.sub,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _stepRow('晨间答题', day.quizTotal > 0,
                    // 「0/3」紧挨着右边的「已完成」，会被读成「三步里完成了 0 步」。
                    // 这里只报知识题答对几道，避免与步骤进度混淆。
                    day.quizTotal == 0 ? '' : '对 ${day.quizCorrect} 道'),
                const SizedBox(height: 10),
                _stepRow('新闻播报', day.news > 0, ''),
                const SizedBox(height: 10),
                _stepRow('出门打卡', day.checkedIn, ''),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColor.ink,
                      foregroundColor: AppColor.onInk,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    onPressed: widget.onStartMorning,
                    child: Text(today?.completed == true ? '再过一遍晨间流程' : '开始今天的晨间流程'),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 14),

          // 小数据
          Row(
            children: [
              Expanded(child: _stat('连续打卡', '${Store.streak}', '天')),
              const SizedBox(width: 12),
              Expanded(child: _stat('本月完成', '${_monthCount()}', '次')),
            ],
          ),

          const SizedBox(height: 14),

          // 答题入口。放在这两块下面，是因为它跟「打卡」是一类东西：
          // 都是每天要往前走一点的事，而且不该只活在早晨那一次流程里。
          _quizEntry(),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 答题入口
  Widget _quizEntry() {
    final answered = _profile.answered.length;
    final total = QBank.instance.total;
    final tier = Rank.tierOf(answered);
    final next = Rank.nextOf(answered);
    final ratio = total == 0 ? 0.0 : (answered / total).clamp(0.0, 1.0);

    return GestureDetector(
      onTap: _openQuiz,
      child: _Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('答题', style: TextStyle(fontSize: 13, color: AppColor.sub)),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColor.accentSoft,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(tier.name,
                      style: TextStyle(fontSize: 10.5, color: AppColor.accent)),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: _openRank,
                  child: Text('榜单 ›',
                      style: TextStyle(fontSize: 11.5, color: AppColor.sub)),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // 四个领域按天轮值。四个一起摆出来，人会挑自己熟的那门、
            // 或者干脆一门都不点；每天只开一个，今天做什么不用选。
            _gateRow(),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('$answered',
                    style: const TextStyle(
                        fontSize: 30, height: 1, fontWeight: FontWeight.w300)),
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 3),
                  child: Text(' / $total 道',
                      style: TextStyle(fontSize: 12, color: AppColor.sub)),
                ),
                const Spacer(),
                Text(
                  next == null ? '题库走完了' : '距${next.name} ${Rank.toNext(answered)} 题',
                  style: TextStyle(fontSize: 11, color: AppColor.sub),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 4,
                backgroundColor: AppColor.line,
                valueColor: AlwaysStoppedAnimation<Color>(AppColor.accent),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              answered == 0
                  ? '还没开始。第一轮不用挑，题会自己找你。'
                  : '不用等早上，想答随时答；答完的会影响新闻怎么挑。',
              style: TextStyle(fontSize: 10.5, height: 1.5, color: AppColor.sub),
            ),
          ],
        ),
      ),
    );
  }

  /// 四门格子。今天那门可点，另外三门置灰并写明哪天开放。
  /// 置灰不是装饰：点它只会告诉你「还轮不到」，不会偷偷放题出来。
  Widget _gateRow() {
    final today = DailyFocus.today;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            for (final a in kFocusAreas)
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(right: a.index == kFocusAreas.length - 1 ? 0 : 6),
                  child: _gateCell(a, today),
                ),
              ),
          ],
        ),
        const SizedBox(height: 7),
        Text(
          '今天只开「${today.name}」这一门 · ${today.note}。四天轮一遍，别的门歇着。',
          style: TextStyle(fontSize: 10.5, height: 1.5, color: AppColor.sub),
        ),
      ],
    );
  }

  Widget _gateCell(FocusArea a, FocusArea today) {
    final open = a.id == today.id;
    return GestureDetector(
      onTap: () {
        if (open) {
          _openQuiz();
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${a.name}今天没开 · ${DailyFocus.openHint(a)}'),
            duration: const Duration(seconds: 2),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: open ? AppColor.accentSoft : AppColor.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: open ? AppColor.accent : AppColor.line),
        ),
        child: Column(
          children: [
            Text(a.name,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: open ? FontWeight.w600 : FontWeight.w400,
                  color: open ? AppColor.accent : AppColor.sub,
                )),
            const SizedBox(height: 3),
            Text(
              open ? '今天 · 去答 →' : _shortHint(a),
              style: TextStyle(
                fontSize: 9.5,
                color: open ? AppColor.accent : AppColor.sub.withOpacity(0.8),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _shortHint(FocusArea a) {
    final d = DailyFocus.daysUntil(a);
    if (d == 1) return '明天开';
    if (d == 2) return '后天开';
    return '$d 天后开';
  }

  int _monthCount() {
    final prefix = '${DateTime.now().year}-${two(DateTime.now().month)}';
    return Store.records.where((r) => r.date.startsWith(prefix) && r.completed).length;
  }

  String _countdown(DateTime at) {
    final d = at.difference(_now);
    final h = d.inHours;
    final m = d.inMinutes % 60;
    if (h <= 0) return '$m 分钟后';
    return '$h 小时 $m 分钟后';
  }

  Widget _permBanner() {
    final text = !_exactOk ? '系统未授予「精准闹钟」权限，闹钟可能延后触发' : '通知权限未开启，响铃提醒可能被系统拦截';
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColor.glassPanel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColor.panelLine),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 18, color: AppColor.accent),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 12, height: 1.5))),
          TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PermissionsPage()),
            ),
            child: const Text('去处理', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _stepRow(String name, bool done, String extra) {
    return Row(
      children: [
        Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: done ? AppColor.ok : Colors.transparent,
            border: Border.all(color: done ? AppColor.ok : AppColor.line, width: 1.5),
          ),
          child: done ? const Icon(Icons.check, size: 12, color: Colors.white) : null,
        ),
        const SizedBox(width: 10),
        Text(name, style: TextStyle(fontSize: 14, color: done ? AppColor.ink : AppColor.sub)),
        const Spacer(),
        if (extra.isNotEmpty)
          Text(extra, style: TextStyle(fontSize: 12, color: AppColor.sub)),
      ],
    );
  }

  Widget _stat(String label, String value, String unit) {
    return _Panel(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(value, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w300)),
          Padding(
            padding: const EdgeInsets.only(left: 3, bottom: 4),
            child: Text(unit, style: TextStyle(fontSize: 12, color: AppColor.sub)),
          ),
          const Spacer(),
          Text(label, style: TextStyle(fontSize: 12, color: AppColor.sub)),
        ],
      ),
    );
  }
}

/// 统一的卡片容器（白底、细线、温和圆角）
class _Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;

  const _Panel({
    required this.child,
    this.padding = const EdgeInsets.all(18),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: AppColor.glassCard,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColor.glassEdge),
      ),
      child: child,
    );
  }
}
