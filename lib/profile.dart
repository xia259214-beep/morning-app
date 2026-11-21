import 'dart:convert';
import 'dart:math' as math;

import 'core.dart';
import 'topics.dart';

/// 画像页上的一条「我看清了这条路」
class TopicEvidence {
  final String id;
  final String label;
  final String full;
  final int hits;
  final double conf;
  final int depth;

  const TopicEvidence({
    required this.id,
    required this.label,
    required this.full,
    required this.hits,
    required this.conf,
    required this.depth,
  });
}

// ============================================================================
// 画像层（V2）
//
// 设计原则：
//   1. 画像不靠「让用户填标签」，靠每天答题里的**选择偏好**自然累积；
//   2. 每个维度带**置信度**，样本不足时明确显示「还看不清」，不假装懂用户；
//   3. 答题记录持久化，题库不重复出；耗尽后自动轮回。
// ============================================================================

/// 十个维度。顺序即画像页的展示顺序，不要随意改动（会影响已存数据的可读性）。
const List<String> kAxes = <String>[
  '科技',
  '健康',
  '财经',
  '社会',
  '国际',
  '文化',
  '体育',
  '环境',
  '军事',
  '生活',
];

/// 一道题的统一形态。知识题有对错，偏好题没有——但两者都会喂给画像。
abstract class QuizItem {
  String get id;

  /// 题干
  String get question;

  List<String> get options;

  /// 左上角的小标签（知识题是学科，偏好题是「你更想了解」这类引导语）
  String get tag;

  /// true = 有标准答案，答错要给解释
  bool get isKnowledge;

  /// 知识题的正确答案下标；偏好题为 -1
  int get answer;

  String get explain;

  /// 选中第 i 个选项，各维度应得的权重增量
  Map<String, double> weightOf(int i);
}

/// 知识题：一个正确答案，答对/答错都算「接触过这个领域」，
/// 但答错时该维度的权重给得少一些——错题不代表不关心。
class KnowledgeItem implements QuizItem {
  @override
  final String id;
  final String category;
  @override
  final String question;
  @override
  final List<String> options;
  @override
  final int answer;
  @override
  final String explain;

  /// 这道题归属的维度，用于画像累积
  final List<String> axes;

  const KnowledgeItem({
    required this.id,
    required this.category,
    required this.question,
    required this.options,
    required this.answer,
    required this.explain,
    required this.axes,
  });

  @override
  String get tag => category;

  @override
  bool get isKnowledge => true;

  @override
  Map<String, double> weightOf(int i) {
    // 答对：+1.0；答错：+0.35（说明至少接触过，只是不熟）
    final v = i == answer ? 1.0 : 0.35;
    return {for (final a in axes) a: v};
  }
}

/// 偏好题：没有对错，选项本身就是「你把注意力放在哪」的证据。
class PrefItem implements QuizItem {
  @override
  final String id;
  final String scene;
  final List<String> opts;

  /// 与 opts 一一对应，每个选项携带若干维度的权重
  final List<Map<String, double>> weights;

  const PrefItem({
    required this.id,
    required this.scene,
    required this.opts,
    required this.weights,
  });

  @override
  String get question => scene;

  @override
  List<String> get options => opts;

  @override
  String get tag => '你更在意';

  @override
  bool get isKnowledge => false;

  @override
  int get answer => -1;

  @override
  String get explain => '';

  @override
  Map<String, double> weightOf(int i) =>
      (i >= 0 && i < weights.length) ? weights[i] : const {};
}

// ============================================================================
// 画像状态
// ============================================================================

class Profile {
  /// 各维度累计权重
  final Map<String, double> score;

  /// 各维度被触及的次数（用于算置信度）
  final Map<String, int> hits;

  /// 已经答过的题 id，避免短期内重复
  final Set<String> answered;

  // ---- V3：主题树上的证据 ----------------------------------------------
  //
  // 十维只能回答「你偏不偏科技」，回答不了「你在制造业这条路上走到哪了」。
  // 这三个表按节点 id 记账，树才知道该往哪钻。

  /// 每个节点被答过几次
  final Map<String, int> topicHits;

  /// 每个节点被跳过几次。跳过不是没回答——它说明这块你不关心，
  /// 跳多了这个分支就该自动变浅，别再拿它烦你。
  final Map<String, int> topicSkips;

  /// 每个节点的掌握度累计（答对加满，答错加少）
  final Map<String, double> topicScore;

  /// 跳过过的题。跳过不写 answered——跳过不等于答过，
  /// 但也不该下一轮立刻再撞上来。记下来，排序时垫到最后。
  final Map<String, int> skippedItems;

  Profile({
    Map<String, double>? score,
    Map<String, int>? hits,
    Set<String>? answered,
    Map<String, int>? topicHits,
    Map<String, int>? topicSkips,
    Map<String, double>? topicScore,
    Map<String, int>? skippedItems,
  })  : score = score ?? {for (final a in kAxes) a: 0.0},
        hits = hits ?? {for (final a in kAxes) a: 0},
        answered = answered ?? <String>{},
        topicHits = topicHits ?? <String, int>{},
        topicSkips = topicSkips ?? <String, int>{},
        topicScore = topicScore ?? <String, double>{},
        skippedItems = skippedItems ?? <String, int>{};

  static Profile load() {
    final raw = Store.s('profile', '');
    if (raw.isEmpty) return Profile();
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return Profile(
        score: {
          for (final a in kAxes)
            a: ((m['score']?[a] ?? 0) as num).toDouble(),
        },
        hits: {
          for (final a in kAxes) a: ((m['hits']?[a] ?? 0) as num).toInt(),
        },
        answered: ((m['answered'] ?? const []) as List).map((e) => '$e').toSet(),
        topicHits: _intMap(m['topicHits']),
        topicSkips: _intMap(m['topicSkips']),
        topicScore: _dblMap(m['topicScore']),
        skippedItems: _intMap(m['skippedItems']),
      );
    } catch (_) {
      return Profile();
    }
  }

  static Map<String, int> _intMap(dynamic v) {
    final out = <String, int>{};
    if (v is Map) {
      v.forEach((k, val) {
        final n = (val as num?)?.toInt() ?? 0;
        if (n != 0) out['$k'] = n;
      });
    }
    return out;
  }

  static Map<String, double> _dblMap(dynamic v) {
    final out = <String, double>{};
    if (v is Map) {
      v.forEach((k, val) {
        final n = (val as num?)?.toDouble() ?? 0;
        if (n != 0) out['$k'] = n;
      });
    }
    return out;
  }

  Future<void> save() async {
    Store.set(
      'profile',
      jsonEncode({
        'score': score,
        'hits': hits,
        'answered': answered.toList(),
        'topicHits': topicHits,
        'topicSkips': topicSkips,
        'topicScore': topicScore,
        'skippedItems': skippedItems,
        'v': 3,
      }),
    );
    await Store.saveSettings();
  }

  /// 置信度 0~1：触及 1 次约 0.28，3 次 0.63，6 次 0.86，12 次 0.98
  double confidenceOf(String axis) =>
      1 - math.exp(-(hits[axis] ?? 0) / 3.0);

  /// 归一化后的偏好强度 0~1（各维度占比）
  double shareOf(String axis) {
    final total = score.values.fold<double>(0, (a, b) => a + b);
    if (total <= 0) return 0;
    return (score[axis] ?? 0) / total * kAxes.length / 3.0;
  }

  /// 最关心的 n 个维度（只在置信度够的里面挑）
  List<String> topAxes([int n = 3]) {
    final list = [...kAxes]..sort((a, b) => (score[b] ?? 0).compareTo(score[a] ?? 0));
    return list.take(n).toList();
  }

  /// 最看不清的维度——下一题优先问它
  String vaguestAxis() {
    var best = kAxes.first;
    var low = double.infinity;
    for (final a in kAxes) {
      final c = confidenceOf(a);
      if (c < low) {
        low = c;
        best = a;
      }
    }
    return best;
  }

  /// 整份画像的整体清晰度
  double get clarity {
    final sum = kAxes.fold<double>(0, (a, b) => a + confidenceOf(b));
    return sum / kAxes.length;
  }

  void apply(QuizItem item, int picked) {
    final w = item.weightOf(picked);
    w.forEach((axis, delta) {
      if (!score.containsKey(axis)) return;
      score[axis] = (score[axis] ?? 0) + delta;
      hits[axis] = (hits[axis] ?? 0) + 1;
    });
    answered.add(item.id);
  }

  // ---- V3：按树记账 ----------------------------------------------------

  /// 记一次作答。
  ///
  /// [credit] 表示这次答得多好：答对 1.0、答错 0.35、多选漏选 0.6。
  /// 答错也要记——错题说明你接触过这块，只是没掌握，跟「不关心」不同。
  void recordAnswer({
    required String id,
    required String topicId,
    required String axis,
    required double credit,
  }) {
    answered.add(id);
    if (score.containsKey(axis)) {
      score[axis] = (score[axis] ?? 0) + credit;
      hits[axis] = (hits[axis] ?? 0) + 1;
    }
    if (topicId.isNotEmpty) {
      topicScore[topicId] = (topicScore[topicId] ?? 0) + credit;
      topicHits[topicId] = (topicHits[topicId] ?? 0) + 1;
    }
  }

  /// 偏好题：只有维度权重，没有对错，也不挂节点。
  void recordPref(String id, Map<String, double> w) {
    answered.add(id);
    w.forEach((axis, delta) {
      if (!score.containsKey(axis)) return;
      score[axis] = (score[axis] ?? 0) + delta;
      hits[axis] = (hits[axis] ?? 0) + 1;
    });
  }

  /// 跳过。不记 answered —— 跳过不等于答过，下次还会遇到，
  /// 但要排到队尾，不能下一轮立刻又拿同一道来问。
  void recordSkip(String topicId, {String id = ''}) {
    if (topicId.isNotEmpty) {
      topicSkips[topicId] = (topicSkips[topicId] ?? 0) + 1;
    }
    if (id.isNotEmpty) {
      skippedItems[id] = (skippedItems[id] ?? 0) + 1;
      // 只留最近一批：跳过记录是为了避免马上重复，不是长期档案。
      if (skippedItems.length > 400) {
        final drop = skippedItems.keys.take(skippedItems.length - 400).toList();
        for (final k in drop) {
          skippedItems.remove(k);
        }
      }
    }
  }

  /// 节点的清晰度：答 2 次 0.63，4 次 0.86，6 次 0.95
  double topicConfidence(String topicId) =>
      1 - math.exp(-(topicHits[topicId] ?? 0) / 2.0);

  /// 已经钻到第几层。画像页用它说「你走到第三层了」。
  int get drillDepth {
    var d = 0;
    topicHits.forEach((id, n) {
      if (n < 2) return;
      final t = TopicTree.instance[id];
      if (t != null && t.depth > d) d = t.depth;
    });
    return d;
  }

  /// 「我看清了哪几条路」——按节点证据排，给画像页用。
  /// 只列答过两次以上的，一次就下结论等于瞎猜。
  List<TopicEvidence> clearestTopics(int n) {
    final list = <TopicEvidence>[];
    topicHits.forEach((id, h) {
      if (h < 2) return;
      final t = TopicTree.instance[id];
      if (t == null) return;
      list.add(TopicEvidence(
        id: id,
        label: t.pathLabel,
        full: t.fullLabel,
        hits: h,
        conf: topicConfidence(id),
        depth: t.depth,
      ));
    });
    list.sort((a, b) {
      if (b.depth != a.depth) return b.depth.compareTo(a.depth);
      return b.conf.compareTo(a.conf);
    });
    return list.take(n).toList();
  }

  /// 被跳过最多的分支。画像页据此提醒「这几块我以后少问」。
  List<String> avoidedTopics(int n) {
    final list = topicSkips.entries.where((e) => e.value >= 2).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [for (final e in list.take(n)) TopicTree.instance[e.key]?.pathLabel ?? e.key];
  }

  String describe() {
    if (clarity < 0.35) return '还看不清。再答几题，我就有数了。';
    final t = topAxes(3);
    final weak = [...kAxes]
      ..sort((a, b) => (score[a] ?? 0).compareTo(score[b] ?? 0));
    final who = t.join('、');
    if (clarity > 0.75) {
      return '你现在明显偏向 $who；${weak.take(2).join('、')}这块基本不看。';
    }
    return '大致偏向 $who，但还有几个方向没看清。';
  }
}
