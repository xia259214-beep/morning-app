// ============================================================================
// 答题面板（可复用）
//
// 这一块原来只长在晨间流程里。结果是：用户点了「重新开始」，画像清空了，
// 但除了等第二天闹钟响，再没有别的地方能答题——入口随着流程一起消失了。
//
// 现在把它抽成一个组件，晨间流程和独立答题页共用同一套判分、反馈、跳过、
// 再来一轮。以后加题型、改反馈，只改这一处，不会两边说法不一样。
// ============================================================================

import 'package:flutter/material.dart';

import 'core.dart';
import 'journal.dart';
import 'profile.dart';
import 'qbank.dart';
import 'topics.dart';

/// 一轮答完的账。跨「再来一轮」累加，供完成页和本次记录使用。
class QuizTally {
  final int answered;
  final int correct;
  final int skipped;

  const QuizTally({
    this.answered = 0,
    this.correct = 0,
    this.skipped = 0,
  });

  QuizTally operator +(QuizTally o) => QuizTally(
        answered: answered + o.answered,
        correct: correct + o.correct,
        skipped: skipped + o.skipped,
      );

  static const QuizTally zero = QuizTally();
}

/// 答题面板。
///
/// [count] 为 -1 表示「把题库答完」。定这个值的是设置在页面里的档位选择。
class QuizPane extends StatefulWidget {
  /// 本轮要出多少道，-1 = 全部
  final int count;

  /// 答完最后一题时主按钮的文案
  final String finishLabel;

  /// 收尾回调。中途喊停也会带上已经答的账。
  final void Function(QuizTally tally) onFinish;

  /// 「够了，先这样」。不传就不显示这个出口。
  ///
  /// v1.12.2：回调带上 [QuizTally]。以前是 VoidCallback，提前结束时本轮已答的
  /// 题数、正确数全被丢掉——晨间完成页于是显示「答题 0 题」，答题页小结显示
  /// 「这一轮 0」：用户明明答了七八道，成绩却像没答过。行为不变，只是把成绩交出去。
  final void Function(QuizTally tally)? onEarlyStop;
  final String earlyStopLabel;

  /// 至少答几道才允许提前结束
  final int minBeforeStop;

  /// 面板顶部的附加内容（段位、本轮说明之类）
  final Widget? header;

  /// 今日之门：只从这些一级分支出题。null = 四门全开
  final Set<String>? onlyRoots;

  const QuizPane({
    super.key,
    required this.count,
    required this.finishLabel,
    required this.onFinish,
    this.onEarlyStop,
    this.earlyStopLabel = '够了，先这样',
    this.minBeforeStop = 8,
    this.header,
    this.onlyRoots,
  });

  @override
  State<QuizPane> createState() => _QuizPaneState();
}

class _QuizPaneState extends State<QuizPane> {
  late List<QItem> _quiz;
  late Profile _profile;

  int _qi = 0;
  int _correct = 0;
  int _answeredCount = 0;
  int _skipped = 0;

  Set<int> _picked = <int>{};
  bool _graded = false;
  Grade? _result;

  @override
  void initState() {
    super.initState();
    _profile = Profile.load();
    _deal();
  }

  void _deal() {
    _quiz = pickAdaptive(widget.count, _profile, onlyRoots: widget.onlyRoots);
    _qi = 0;
    _picked = <int>{};
    _graded = false;
    _result = null;
  }

  QuizTally get _tally => QuizTally(
        answered: _answeredCount,
        correct: _correct,
        skipped: _skipped,
      );

  void _finishRound() => widget.onFinish(_tally);

  /// 再出一轮。用户愿意答就一直给题——「他愿意回答时就该不停给」。
  void _anotherRound() {
    setState(_deal);
  }

  void _nextQuiz() {
    if (_qi + 1 >= _quiz.length) {
      _finishRound();
      return;
    }
    setState(() {
      _qi++;
      _picked = <int>{};
      _graded = false;
      _result = null;
    });
  }

  /// 跳过。跳过不是没发生——它说明这块你不关心，画像会照记。
  void _skip() {
    final q = _quiz[_qi];
    _profile.recordSkip(q.topicId, id: q.id);
    _profile.save();
    _skipped++;
    Journal.add(
      JKind.quiz,
      q.prompt,
      detail: q.topicId.isEmpty
          ? '这题跳过了'
          : '这题跳过了，${TopicTree.instance[q.topicId]?.pathLabel ?? ''} 这块先不问',
      tag: q.kind.label,
      verdict: 'neutral',
    );
    setState(() {
      if (_qi + 1 >= _quiz.length) {
        _finishRound();
      } else {
        _qi++;
        _picked = <int>{};
        _graded = false;
        _result = null;
      }
    });
  }

  /// 点选项。单选、判断、偏好点了立刻判；多选只勾上，等确认。
  void _choose(int i) {
    final q = _quiz[_qi];
    if (_graded) return;
    if (q.kind == QKind.multi) {
      setState(() {
        if (_picked.contains(i)) {
          _picked.remove(i);
        } else {
          _picked.add(i);
        }
      });
      return;
    }
    _finish(q, <int>{i});
  }

  void _confirm() {
    if (_picked.isEmpty) return;
    _finish(_quiz[_qi], {..._picked});
  }

  /// 判分 + 记画像 + 落日志。
  void _finish(QItem q, Set<int> picked) {
    final g = gradeOf(q, picked);
    setState(() {
      _picked = picked;
      _graded = true;
      _result = g;
      if (g.correct == true) _correct++;
      _answeredCount++;
    });

    if (q.kind == QKind.pref) {
      for (final i in picked) {
        if (i >= 0 && i < q.weights.length) {
          _profile.recordPref(q.id, q.weights[i]);
        }
      }
    } else {
      // 答对给满证据；多选漏选六成；答错也给三成半——
      // 答错说明碰过这块，只是没掌握，跟「不关心」不是一回事。
      final credit = g.correct == true ? 1.0 : (g.partial ? 0.6 : 0.35);
      _profile.recordAnswer(
        id: q.id,
        topicId: q.topicId,
        axis: q.axis,
        credit: credit,
      );
    }
    _profile.save();

    final String detail;
    if (q.kind == QKind.pref) {
      detail = '你选的是「${q.options[picked.first]}」。';
    } else if (g.correct == true) {
      detail = '答对了。${q.explain}';
    } else if (g.partial) {
      final miss = q.answers.difference(picked);
      detail =
          '没选全，还差${miss.map((e) => '「${q.options[e]}」').join('')}。${q.explain}';
    } else {
      final right = q.answers.map((e) => '「${q.options[e]}」').join('');
      detail = '答案是$right。${q.explain}';
    }
    Journal.add(
      JKind.quiz,
      q.prompt,
      detail: detail,
      tag: q.topicId.isEmpty
          ? q.kind.label
          : (TopicTree.instance[q.topicId]?.pathLabel ?? q.kind.label),
      verdict: q.isKnowledge ? (g.correct == true ? 'right' : 'wrong') : 'neutral',
    );
  }

  @override
  Widget build(BuildContext context) {
    final q = _quiz[_qi];
    final last = _qi + 1 >= _quiz.length;
    final isMulti = q.kind == QKind.multi;
    final topic = q.topicId.isEmpty ? null : TopicTree.instance[q.topicId];

    return Padding(
      key: ValueKey('quiz$_qi'),
      padding: const EdgeInsets.fromLTRB(24, 6, 24, 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.header != null) ...[
            widget.header!,
            const SizedBox(height: 12),
          ],
          Row(
            children: [
              Text(_progressText(),
                  style: TextStyle(fontSize: 12, color: AppColor.sub)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColor.accentSoft,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(q.kind.label,
                    style: TextStyle(fontSize: 10.5, color: AppColor.accent)),
              ),
              const Spacer(),
              if (!_graded)
                TextButton(
                  onPressed: _skip,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: const Size(0, 30),
                  ),
                  child: Text('这题不熟',
                      style: TextStyle(fontSize: 11.5, color: AppColor.sub)),
                ),
            ],
          ),
          // 这一题在树的哪一节。看得见「现在走到哪儿」，才谈得上越走越细。
          if (topic != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(topic.fullLabel,
                  style: TextStyle(
                      fontSize: 10.5, color: AppColor.sub.withOpacity(0.85))),
            ),
          const SizedBox(height: 14),
          Text(q.prompt,
              style: const TextStyle(
                  fontSize: 19.5, height: 1.5, fontWeight: FontWeight.w400)),
          const SizedBox(height: 6),
          Text(q.kindHint, style: TextStyle(fontSize: 11.5, color: AppColor.sub)),
          const SizedBox(height: 16),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  for (var i = 0; i < q.options.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _option(i, q),
                    ),
                ],
              ),
            ),
          ),
          if (_graded && _result != null) _feedback(q),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColor.ink,
                shape:
                    RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              onPressed: _mainEnabled(isMulti) ? (isMulti && !_graded ? _confirm : _nextQuiz) : null,
              child: Text(_graded
                  ? (last ? widget.finishLabel : '下一题')
                  : (isMulti ? '确认选择' : '选一个')),
            ),
          ),
          if (last && _graded)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Center(
                child: TextButton(
                  onPressed: _anotherRound,
                  child: Text('再来一轮',
                      style: TextStyle(fontSize: 12.5, color: AppColor.accent)),
                ),
              ),
            ),
          // 画像只需要一定量的证据，不必把题库答穿；
          // 但前几题样本太少，提前结束得到的画像基本是噪声，所以有门槛。
          if (!last && _qi + 1 >= widget.minBeforeStop && widget.onEarlyStop != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Center(
                child: TextButton(
                  onPressed: () => widget.onEarlyStop!(_tally),
                  child: Text(widget.earlyStopLabel,
                      style: TextStyle(fontSize: 12.5, color: AppColor.sub)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  bool _mainEnabled(bool isMulti) {
    if (_graded) return true;
    if (isMulti) return _picked.isNotEmpty;
    return false;
  }

  /// 全部题库时，分母写「3224」会把「第 1 / 3224 题」显示得像永远答不完。
  /// 这种档位只报「第几题」，题库总量放在顶部说明里。
  String _progressText() {
    if (widget.count < 0) return '第 ${_qi + 1} 题';
    return '第 ${_qi + 1} / ${_quiz.length} 题';
  }

  /// 答题后的反馈：知识题给对错和解释，偏好题只确认「记下了」，不评价。
  Widget _feedback(QItem q) {
    final g = _result!;
    final ok = g.correct == true;
    final bg = q.isKnowledge
        ? (ok ? const Color(0xFFF0F5F1) : const Color(0xFFFDF0EA))
        : AppColor.accentSoft;

    final String text;
    if (q.kind == QKind.pref) {
      text = '记下了。你选的是「${q.options[_picked.first]}」。';
    } else if (ok) {
      text = '答对了。${q.explain}';
    } else if (g.partial) {
      final miss = q.answers.difference(_picked);
      text = '没选全，还差${miss.map((e) => '「${q.options[e]}」').join('')}。${q.explain}';
    } else {
      final right = q.answers.map((e) => '「${q.options[e]}」').join('');
      text = '答案是$right。${q.explain}';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(text, style: const TextStyle(fontSize: 12.5, height: 1.6)),
    );
  }

  Widget _option(int i, QItem q) {
    final picked = _picked.contains(i);
    final isAnswer = q.kind != QKind.pref && q.answers.contains(i);
    var bg = AppColor.card;
    var border = AppColor.line;

    if (_graded) {
      if (isAnswer) {
        // 正确答案一律标绿：多选里「你没选对的那条」也要标出来，
        // 不然只看自己选的橙色，不知道漏了什么。
        bg = const Color(0xFFF0F5F1);
        border = AppColor.ok;
      } else if (picked) {
        bg = const Color(0xFFFDF0EA);
        border = const Color(0xFFD08A6A);
      }
    } else if (picked) {
      bg = AppColor.accentSoft;
      border = AppColor.accent;
    }

    final Widget lead = q.kind == QKind.multi
        ? Icon(
            picked ? Icons.check_box : Icons.check_box_outline_blank,
            size: 18,
            color: picked ? AppColor.accent : AppColor.sub,
          )
        : (q.kind == QKind.judge
            ? const SizedBox(width: 0)
            : Text(String.fromCharCode(65 + i),
                style: TextStyle(fontSize: 13, color: AppColor.sub)));

    return GestureDetector(
      key: ValueKey('opt$i'),
      onTap: _graded ? null : () => _choose(i),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(
            horizontal: 16, vertical: q.kind == QKind.judge ? 18 : 15),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: border),
        ),
        child: Row(
          mainAxisAlignment: q.kind == QKind.judge
              ? MainAxisAlignment.center
              : MainAxisAlignment.start,
          children: [
            lead,
            if (q.kind != QKind.judge) const SizedBox(width: 14),
            if (q.kind == QKind.judge)
              Text(q.options[i], style: const TextStyle(fontSize: 16))
            else
              Expanded(
                  child: Text(q.options[i], style: const TextStyle(fontSize: 14.5))),
          ],
        ),
      ),
    );
  }
}
