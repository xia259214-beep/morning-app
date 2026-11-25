// ============================================================================
// 题库生成器（V3）
//
// V2 的题库是两张写死的常量表：200 道知识 + 100 道偏好。要加到三千道，
// 靠手打表格是不可能维护的——加一条就要改 id、改权重、改测试。
//
// V3 改成「事实卡 → 题」。一张事实卡（节点|标题|正确说法|误解…）能长出：
//   1. 正向单选：「关于数控车工，下面哪一句是对的？」
//   2. 反向单选：「关于 G00，下面哪一句是错的？」（每个误解一条）
//   3. 配对单选：「数控车工里，G 代码指的是什么？」
//   4. 对错题：拿正确说法问（答对）、拿误解问（答错）
//   5. 多选：节点下凑齐三条以上事实时，「下列说法正确的有」
//
// 这样加一行数据 = 加 5~8 道题，而且干扰项来自同一节点的兄弟事实，
// 不是随机拼的——干扰项必须似是而非，一眼假的选项等于送分。
// ============================================================================

import 'dart:math' as math;

import 'bank_pref.dart';
import 'profile.dart';
import 'topics.dart';

enum QKind {
  /// 单选
  single,

  /// 多选，全对才算对
  multi,

  /// 判断对错
  judge,

  /// 偏好题，没有对错
  pref,
}

extension QKindLabel on QKind {
  String get label => switch (this) {
        QKind.single => '单选',
        QKind.multi => '多选',
        QKind.judge => '判断',
        QKind.pref => '偏好',
      };
}

class QItem {
  final String id;
  final QKind kind;

  /// 归属主题节点，'' 表示偏好题（不挂节点，只挂维度）
  final String topicId;

  final String prompt;
  final List<String> options;

  /// 正确选项下标。judge 题固定 0 = 对、1 = 错。
  final Set<int> answers;

  final String explain;

  /// 偏好题用：选中第 i 项各维度加多少
  final List<Map<String, double>> weights;

  final String axis;

  /// 难度档 1/2/3。0 = 没标，按题型自动推：
  /// 判断题最容易(1)，单选中等(2)，多选要全对才算对、最难(3)。
  /// 个别题确实偏难/偏易时，在题库里显式给这一项即可覆盖自动值。
  final int lv;

  const QItem({
    required this.id,
    required this.kind,
    required this.topicId,
    required this.prompt,
    required this.options,
    required this.answers,
    this.explain = '',
    this.weights = const <Map<String, double>>[],
    this.axis = '生活',
    this.lv = 0,
  });

  /// 计分用的难度档：1 易 / 2 中 / 3 难（反馈条上的难度点用）
  int get difficulty {
    if (lv >= 1 && lv <= 3) return lv;
    return switch (kind) {
      QKind.judge => 1,
      QKind.single => 2,
      QKind.multi => 3,
      QKind.pref => 0,
    };
  }

  /// 答对这道题挣多少分（v1.22.1 用户定的精确分值）：
  /// 判断 +1 · 单选 +1.35 · 多选 +1.55 · 偏好题无对错
  double get gain => switch (kind) {
        QKind.judge => 1.0,
        QKind.single => 1.35,
        QKind.multi => 1.55,
        QKind.pref => 0.0,
      };

  bool get isKnowledge => kind != QKind.pref;

  /// 展示用的题型说明
  String get kindHint => switch (kind) {
        QKind.single => '选一个',
        QKind.multi => '可多选，全选才算对',
        QKind.judge => '判断对错',
        QKind.pref => '没有对错',
      };
}

/// 没答对时错在哪一档（v1.22.1：三种错法扣的分不一样）。
enum MissKind {
  /// 完全答错：没碰到任何正确选项
  none,

  /// 纯漏选：只选了正确项，但没选全
  miss,

  /// 漏选+选错：既碰了正确项，也选了错误项
  missWrong,
}

/// 判分结果。pref 题 correct 为 null（本来就没有对错）。
class Grade {
  final bool? correct;

  /// 多选里选对了一部分但没全对（碰过正确项就算）
  final bool partial;

  /// 没答对时错在哪一档（答对时为 none）
  final MissKind miss;

  const Grade(this.correct, {this.partial = false, this.miss = MissKind.none});
}

Grade gradeOf(QItem q, Set<int> picked) {
  if (q.kind == QKind.pref) return const Grade(null);
  final ok = picked.length == q.answers.length && picked.containsAll(q.answers);
  if (ok) return const Grade(true);
  final touched = picked.any(q.answers.contains);
  // 只选了正确项但没选全 = 纯漏选；混进了错误选项 = 漏选+选错；
  // 一个正确项都没碰到 = 完全答错。
  final miss = picked.isNotEmpty && picked.every(q.answers.contains)
      ? MissKind.miss
      : (touched ? MissKind.missWrong : MissKind.none);
  return Grade(false, partial: touched, miss: miss);
}

// ---------------------------------------------------------------- 生成

class QBank {
  final List<QItem> all = <QItem>[];
  final Map<String, List<QItem>> byTopic = <String, List<QItem>>{};
  final List<QItem> pref = <QItem>[];

  static QBank? _cached;

  static QBank get instance => _cached ??= _build();

  static QBank _build() {
    final b = QBank();
    final t = TopicTree.instance;

    for (final f in t.facts) {
      final topic = t[f.topicId];
      if (topic == null) continue;
      final siblings = t.factsOf(f.topicId).where((s) => s.title != f.title).toList();

      void add(QItem q) {
        b.all.add(q);
        b.byTopic.putIfAbsent(q.topicId, () => <QItem>[]).add(q);
      }

      final h = stableHash('${f.topicId}|${f.title}');

      // 1. 正向单选：选项全部围绕本条的标题，一真几假。
      //
      // 这里踩过一个坑：最初干扰项取的是兄弟事实的「正确说法」，
      // 于是「下面哪一句是对的」四个选项全是真的——题目本身不成立，
      // 用户选哪个都委屈。干扰项必须来自同一条事实的误解。
      if (f.wrongs.isNotEmpty) {
        add(QItem(
          id: 'q$h-a',
          kind: QKind.single,
          topicId: f.topicId,
          prompt: '关于${f.title}，下面哪一句是对的？',
          options: [f.right, ...f.wrongs],
          answers: const <int>{0},
          explain: f.note.isEmpty ? f.right : f.note,
          axis: topic.axis,
        ));
      }

      // 2. 反向单选：每个误解一条
      for (var i = 0; i < f.wrongs.length; i++) {
        final rights = _pickN(siblings.map((e) => e.right), 2);
        if (rights.isEmpty) continue;
        add(QItem(
          id: 'q$h-b$i',
          kind: QKind.single,
          topicId: f.topicId,
          prompt: '关于${f.title}，下面哪一句是错的？',
          options: [f.wrongs[i], ...rights],
          answers: const <int>{0},
          explain: f.right,
          axis: topic.axis,
        ));
      }

      // 3. 配对单选：这个术语指的是什么
      if (siblings.length >= 2) {
        add(QItem(
          id: 'q$h-c',
          kind: QKind.single,
          topicId: f.topicId,
          prompt: '${topic.label}这一行里，${f.title}指的是什么？',
          options: [f.right, ..._pickN(siblings.map((e) => e.right), 3)],
          answers: const <int>{0},
          explain: f.note.isEmpty ? f.right : f.note,
          axis: topic.axis,
        ));
      }

      // 4. 对错：正确说法 → 对
      add(QItem(
        id: 'q$h-d',
        kind: QKind.judge,
        topicId: f.topicId,
        prompt: f.right,
        options: const ['对', '错'],
        answers: const <int>{0},
        explain: f.note.isEmpty ? f.right : f.note,
        axis: topic.axis,
      ));

      // 5. 对错：每个误解 → 错
      for (var i = 0; i < f.wrongs.length; i++) {
        add(QItem(
          id: 'q$h-e$i',
          kind: QKind.judge,
          topicId: f.topicId,
          prompt: f.wrongs[i],
          options: const ['对', '错'],
          answers: const <int>{1},
          explain: f.right,
          axis: topic.axis,
        ));
      }
    }

    // 6. 多选：同一节点凑三条以上事实
    for (final entry in t.nodes.entries) {
      final facts = t.factsOf(entry.key);
      if (facts.length < 3) continue;
      final node = entry.value;
      final truths = facts.take(3).map((e) => e.right).toList();
      final lie = facts.map((e) => e.wrongs.first).take(2).toList();
      final opts = <String>[...truths, ...lie]..shuffle(math.Random(stableHash(entry.key).hashCode));
      final ans = <int>{};
      for (var i = 0; i < opts.length; i++) {
        if (truths.contains(opts[i])) ans.add(i);
      }
      b.all.add(QItem(
        id: 'q${stableHash('${entry.key}|multi')}-m',
        kind: QKind.multi,
        topicId: entry.key,
        prompt: '关于${node.label}，下列说法正确的有哪几条？',
        options: opts,
        answers: ans,
        explain: truths.join('；'),
        axis: node.axis,
      ));
      b.byTopic.putIfAbsent(entry.key, () => <QItem>[]).add(b.all.last);
    }

    // 7. 偏好题（V2 保留）：不挂节点，只喂十维
    for (final p in kPrefBank) {
      final q = QItem(
        id: p.id,
        kind: QKind.pref,
        topicId: '',
        prompt: p.scene,
        options: p.opts,
        answers: const <int>{},
        weights: p.weights,
        axis: p.weights.isEmpty ? '生活' : p.weights.first.keys.first,
      );
      b.pref.add(q);
      b.all.add(q);
    }

    return b;
  }

  /// 从候选里挑 n 条不重复的，可能不足 n
  static List<String> _pickN(Iterable<String> src, int n) {
    final out = <String>[];
    for (final s in src) {
      if (out.length >= n) break;
      if (out.contains(s)) continue;
      out.add(s);
    }
    return out;
  }

  int get total => all.length;

  QItem? byId(String id) {
    for (final q in all) {
      if (q.id == id) return q;
    }
    return null;
  }
}

// ---------------------------------------------------------------- 抽题

/// 一轮里的题型配比。全是对错题会闷，全是单选会累。
class Mix {  final int single;
  final int judge;
  final int multi;
  final int pref;

  const Mix({this.single = 4, this.judge = 3, this.multi = 2, this.pref = 1});

  int get total => single + judge + multi + pref;

  /// 按比例换算成 count 道
  Mix scaled(int count) {
    final s = single + judge + multi + pref;
    if (s == 0) return Mix(pref: count);
    var a = (count * single / s).round();
    var b = (count * judge / s).round();
    var c = (count * multi / s).round();
    var d = count - a - b - c;
    if (d < 0) {
      // 兜底：从最大的那类里扣
      final big = [a, b, c].indexOf([a, b, c].reduce(math.max));
      if (big == 0) a += d; else if (big == 1) b += d; else c += d;
      d = 0;
    }
    return Mix(single: a, judge: b, multi: c, pref: d);
  }
}

/// 一轮的题数档位。-1 表示「不限」：把当前题库整轮端出来，答完自动轮回
/// 继续出，没有「走完」这回事。题库本身是数据驱动的，往 seed 里加一行
/// 事实卡就长 5~8 道题，到 2000 道以后照样能接着加。
const List<int> kQuizCounts = <int>[3, 5, 10, 20, 30, 50, -1];

String quizCountLabel(int v) => v < 0 ? '不限' : '$v 道';

/// 答满这么多题之后，才从「铺轮廓」转成「往下钻」。
///
/// 这个数不是拍的：一轮 10 道、每节点最多 2 道，30 道正好把十三个一级分支
/// 都摸到一遍半。注册当天只答得完二三十道，那这二三十道必须是大方向，
/// 不能一上来就钻进某个具体工种里。
const int kBreadthQuota = 30;

/// 自适应抽题。
///
/// 不再是「未答过优先 + 最模糊维度」这种一层逻辑，而是按树往下走：
///   * 一级分支先各铺一道，轮廓要有
///   * 某条路答到 3 次，它的子节点才开始放量
///   * 跳过多的分支自动降权，但不清零
///
/// [count] 越大，钻得越深；一轮只有 10 道时基本上是铺轮廓。
/// [onlyRoots] 是今日之门：只有这些一级分支的题会被抽出来。
/// 不传就是四门全开（用户主动选了「全部」档，或旧调用点）。
List<QItem> pickAdaptive(
  int count,
  Profile p, {
  math.Random? rng,
  Mix? mix,
  Set<String>? onlyRoots,
}) {
  final r = rng ?? math.Random();
  final bank = QBank.instance;
  final tree = TopicTree.instance;
  final want = count < 0 ? bank.total : count;
  final m = (mix ?? const Mix()).scaled(want);

  // 前面这一段强制广度优先：还没答到 30 道的人，最需要的是「哪儿都摸一下」，
  // 而不是在第一条路上被问到底。
  final breadth = p.answered.length < kBreadthQuota;

  var order = tree.drillOrder(
    hits: p.topicHits,
    skips: p.topicSkips,
    rng: r,
    breadth: breadth,
  );
  // 「全部」档是用户主动要求一次走完整座山，这时四门全开，不受今日之门限制。
  final roots = onlyRoots;
  final gated = roots != null && count >= 0;
  final allowed = <String>{...?roots};
  if (gated) {
    order = [for (final id in order) if (allowed.contains(id.split('/').first)) id];
  }

  final picked = <QItem>[];
  final used = <String>{};

  // 每个节点按题型分桶，已答过的排到队尾
  List<QItem> bucket(String topicId, QKind kind) {
    final list = (bank.byTopic[topicId] ?? const <QItem>[])
        .where((q) => q.kind == kind)
        .toList();
    list.sort((a, b) => _rank(a, p).compareTo(_rank(b, p)));
    return list;
  }

  void take(QKind kind, int n) {
    var want = n;
    for (final id in order) {
      if (want <= 0) break;
      // 同一个节点在一轮里最多出几道。
      //
      // 平时是 2：只出 1 道的话，一轮 10 题铺在 10 个节点上，每个节点永远
      // 只有一次证据，够不到「看清」的门槛。
      //
      // 但新人的头几轮反过来——只出 1 道。他注册那天只答得完二三十道，
      // 这二三十道要拿来把「兴趣、工作、生活」这些大方向各摸一遍，
      // 不能在第一支里连问两道。过了这个阶段自然回到 2。
      final cap = breadth ? 1 : 2;
      var perTopic = picked.where((q) => q.topicId == id).length;
      if (perTopic >= cap) continue;
      for (final q in bucket(id, kind)) {
        if (want <= 0 || perTopic >= cap) break;
        if (used.contains(q.id)) continue;
        picked.add(q);
        used.add(q.id);
        want--;
        perTopic++;
      }
    }
    // 还不够就放宽「每节点最多一道」
    if (want > 0) {
      for (final id in order) {
        if (want <= 0) break;
        for (final q in bucket(id, kind)) {
          if (want <= 0) break;
          if (used.contains(q.id)) continue;
          picked.add(q);
          used.add(q.id);
          want--;
          break;
        }
      }
    }
  }

  take(QKind.single, m.single);
  take(QKind.judge, m.judge);
  take(QKind.multi, m.multi);

  // 偏好题：题库不够时补位，也负责在答穿后保证有题
  final prefs = [...bank.pref]..sort((a, b) => _rank(a, p).compareTo(_rank(b, p)));
  for (final q in prefs) {
    if (picked.length >= want) break;
    if (used.contains(q.id)) continue;
    picked.add(q);
    used.add(q.id);
  }

  // 还差：从全库兜底（答穿后轮回）。
  //
  // 这里原来是随机洗一遍再取，选「全部」时会变成一大把乱序题。改成沿
  // drillOrder 的顺序补——同样是补满，但补进来的仍然沿着走过的路往下，
  // 不会答到第 800 题时突然跳回一级分支。
  if (picked.length < want) {
    for (final id in order) {
      if (picked.length >= want) break;
      for (final q in [...bank.byTopic[id] ?? const <QItem>[]]
        ..sort((a, b) => _rank(a, p).compareTo(_rank(b, p)))) {
        if (picked.length >= want) break;
        if (used.contains(q.id)) continue;
        picked.add(q);
        used.add(q.id);
      }
    }
    // 还差就说明 order 里没覆盖到（理论上不会），兜底扫全库。
    // 门控时只能从今日之门里补，不能把另外三门的题漏进来。
    if (picked.length < want) {
      for (final q in bank.all) {
        if (picked.length >= want) break;
        if (used.contains(q.id)) continue;
        if (gated && q.topicId.isNotEmpty &&
            !allowed.contains(q.topicId.split('/').first)) continue;
        picked.add(q);
        used.add(q.id);
      }
    }
  }

  picked.shuffle(r);
  // 第一题给偏好题：刚醒来不适合先判断一句专业话的真假
  final i = picked.indexWhere((q) => q.kind == QKind.pref);
  if (i > 0) {
    final q = picked.removeAt(i);
    picked.insert(0, q);
  }
  return [for (final q in picked) _shuffle(q, r)];
}

/// 题目在候选池里的先后：没答过的最前，答过的其次，跳过过的垫底。
///
/// 跳过垫底这一条是被真机教出来的：跳过不写 answered，于是同一道题
/// 下一轮立刻又撞上来，看起来像故意找茬。
int _rank(QItem q, Profile p) {
  if (p.skippedItems.containsKey(q.id)) return 2;
  if (p.answered.contains(q.id)) return 1;
  return 0;
}

/// 打乱选项。
///
/// 不打乱的后果在 V1 出过：正确项永远在 A，用户习惯性选最上面那个，
/// 得到的不是他的水平，是他手指的习惯。
QItem _shuffle(QItem q, math.Random r) {
  if (q.options.length < 2) return q;
  final order = List<int>.generate(q.options.length, (i) => i)..shuffle(r);
  final opts = [for (final i in order) q.options[i]];
  final ans = <int>{};
  for (final a in q.answers) {
    ans.add(order.indexOf(a));
  }
  if (q.kind == QKind.pref) {
    return QItem(
      id: q.id,
      kind: q.kind,
      topicId: q.topicId,
      prompt: q.prompt,
      options: opts,
      answers: const <int>{},
      weights: [for (final i in order) q.weights[i]],
      axis: q.axis,
    );
  }
  return QItem(
    id: q.id,
    kind: q.kind,
    topicId: q.topicId,
    prompt: q.prompt,
    options: opts,
    answers: ans,
    explain: q.explain,
    axis: q.axis,
  );
}

/// 题库自检。id 重复会让「已答过」的去重失效，开发期必须跑。
List<String> auditQBank() {
  final bad = <String>[];
  final seen = <String>{};
  for (final q in QBank.instance.all) {
    if (!seen.add(q.id)) bad.add('重复 id：${q.id}');
    if (q.options.length < 2) bad.add('选项不足：${q.id}');
    if (q.isKnowledge) {
      if (q.answers.isEmpty) bad.add('没有答案：${q.id}');
      for (final a in q.answers) {
        if (a < 0 || a >= q.options.length) bad.add('答案越界：${q.id}');
      }
    }
    if (q.kind == QKind.pref && q.weights.length != q.options.length) {
      bad.add('偏好权重与选项数量不一致：${q.id}');
    }
  }
  // 正向单选的干扰项不能是「别处的正确说法」。
  //
  // 这条检查是补一个真实踩过的坑：问「哪一句是对的」，四个选项却条条都对，
  // 用户选哪个都委屈。语义判断不了，但可以退一步——干扰项不许出现在
  // 全部正确说法的集合里，这一条能挡掉整个同类错误。
  final rights = TopicTree.instance.facts.map((e) => e.right).toSet();
  for (final q in QBank.instance.all) {
    if (q.kind != QKind.single || !q.prompt.contains('哪一句是对的')) continue;
    for (var i = 0; i < q.options.length; i++) {
      if (q.answers.contains(i)) continue;
      if (rights.contains(q.options[i])) {
        bad.add('正向单选的干扰项其实是别处的正确说法：${q.id}');
      }
    }
  }

  // 联动性与合理性：一道题的选项不该自相重复，正确说法也不能是空话。
  // 这些是「一眼假」之外更容易被用户当场指出来的毛病，先在这里挡住。
  for (final q in QBank.instance.all) {
    if (q.options.any((o) => o.trim().isEmpty)) {
      bad.add('选项里有空白：${q.id}');
    }
    final distinct = q.options.map((o) => o.trim()).toSet();
    if (distinct.length != q.options.length) {
      bad.add('选项自相重复：${q.id}');
    }
  }
  for (final f in TopicTree.instance.facts) {
    if (f.right.trim().isEmpty) {
      bad.add('正确说法是空的：${f.topicId}/${f.title}');
    }
    if (f.wrongs.any((w) => w.trim() == f.right.trim())) {
      bad.add('误解和正确说法一模一样：${f.topicId}/${f.title}');
    }
  }

  bad.addAll(TopicTree.instance.audit());
  return bad;
}
