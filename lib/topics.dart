// ============================================================================
// 主题树（V3）
//
// V1/V2 的画像是十个并排的桶：答第 1 道题和答第 1000 道题，都在回答
// 「你偏不偏科技」。答得再多，也只是那十根条更稳一点，不会更细。
//
// V3 换成树：职业 / 生活 / 工具 / 爱好 …… 每个节点都能继续长出子节点。
// 答得多的分支往下钻，没碰过的分支留在第一层。这样「轮廓」由树给出，
// 「纹理」由深度给出。
//
// 树不手写。数据行本身就是路径：
//     制造业/数控加工/数控车工|G 代码|G00 快速定位，G01 直线插补|G00 走圆弧
// 前缀自动建节点，后半段是事实卡。一份数据既建树又出题，不会出现
// 「树里有节点但没题」这种空壳。
//
// 十维仍然保留：每个节点映射到一个新闻领域，答这个节点也累加该领域，
// 新闻排序继续用十维，稳。树只负责把「你在这条路上走了多深」记下来。
// ============================================================================

import 'dart:math' as math;

import 'seed_all.dart';

/// 一级分支 → 新闻领域（十维）。子节点继承父节点的领域，
/// 所以只需在一级指定。
const Map<String, String> kRootAxis = <String, String>{
  '职业': '社会',
  '生活': '生活',
  '工具': '科技',
  '爱好': '文化',
  '健康': '健康',
  '钱': '财经',
  '世界': '国际',
  '社会': '社会',
  '科技': '科技',
  '体育': '体育',
  '环境': '环境',
  '军事': '军事',
  '文化': '文化',
};

/// 一级分支的副标题，画像页和答题页顶部用。
const Map<String, String> kRootNote = <String, String>{
  '职业': '你靠什么吃饭，手上是什么活',
  '生活': '吃住行、看病上学、人情往来',
  '工具': '你手里天天摸的那些东西',
  '爱好': '闲下来你在做什么',
  '健康': '身体这台机器怎么保养',
  '钱': '钱从哪来、往哪去',
  '世界': '地球另一边在发生什么',
  '社会': '人和人怎么相处、怎么办事',
  '科技': '东西是怎么造出来、怎么运转的',
  '体育': '比赛、训练、身体对抗',
  '环境': '天气、水土、能源',
  '军事': '装备、战法、国防',
  '文化': '书、影、乐、吃、老规矩',
};

class Topic {
  final String id;
  final String label;

  /// 根节点的 parent 是空串
  final String parentId;

  /// 1 = 一级分支（职业 / 生活 …）
  final int depth;

  /// 映射到十维里的哪一个，新闻排序用
  final String axis;

  final List<String> childIds = <String>[];

  /// 这个节点下有几张事实卡（= 能长几道题）
  int factCount = 0;

  Topic({
    required this.id,
    required this.label,
    required this.parentId,
    required this.depth,
    required this.axis,
  });

  /// 「制造业 · 数控加工」这样的短路径，答题页顶部显示
  String get pathLabel {
    final parts = id.split('/');
    if (parts.length <= 2) return id.replaceAll('/', ' · ');
    return '${parts[parts.length - 2]} · ${parts.last}';
  }

  /// 完整路径，画像页展示用
  String get fullLabel => id.replaceAll('/', ' · ');

  bool get isLeaf => childIds.isEmpty;
}

/// 一张事实卡。生成器把它展开成单选、多选、对错三种题型。
class Fact {
  final String topicId;
  final String title;

  /// 一句站得住的话
  final String right;

  /// 常见误解。必须似是而非——一眼假的干扰项等于送分。
  final List<String> wrongs;

  /// 答完之后给的解释，可以比 right 多讲一句
  final String note;

  const Fact({
    required this.topicId,
    required this.title,
    required this.right,
    required this.wrongs,
    this.note = '',
  });
}

/// 稳定短哈希。题库的 id 要跨版本可用：数据改一行，不能让所有人已答记录全失效。
String stableHash(String s) {
  var h = 2166136261;
  for (final c in s.codeUnits) {
    h ^= c;
    h = (h * 16777619) & 0xFFFFFFFF;
  }
  return h.toRadixString(36);
}

class TopicTree {
  final Map<String, Topic> nodes = <String, Topic>{};
  final List<Fact> facts = <Fact>[];

  /// 根分支顺序，画像页按这个顺序列
  final List<String> roots = <String>[];

  static TopicTree? _cached;

  static TopicTree get instance => _cached ??= _build();

  static TopicTree _build() {
    final t = TopicTree();
    for (final row in kSeedRows) {
      t._consume(row);
    }
    return t;
  }

  /// 数据行：路径|标题|正确说法|错误说法1[|错误说法2][|说明]
  void _consume(String row) {
    final line = row.trim();
    if (line.isEmpty || line.startsWith('#')) return;
    final p = line.split('|');
    if (p.length < 4) return;

    final path = p[0].trim();
    final parts = path.split('/');
    if (parts.isEmpty) return;

    // 逐级建节点
    var cur = '';
    for (var i = 0; i < parts.length; i++) {
      final seg = parts[i].trim();
      if (seg.isEmpty) return;
      cur = cur.isEmpty ? seg : '$cur/$seg';
      if (!nodes.containsKey(cur)) {
        final parent = i == 0 ? '' : parts.take(i).join('/');
        final axis = i == 0 ? (kRootAxis[seg] ?? '生活') : nodes[parent]!.axis;
        nodes[cur] = Topic(
          id: cur,
          label: seg,
          parentId: parent,
          depth: i + 1,
          axis: axis,
        );
        if (i == 0) {
          roots.add(cur);
        } else {
          nodes[parent]!.childIds.add(cur);
        }
      }
    }

    // 「~」开头的那一段是补充说明，其余都是误解。
    // 不这么标的话，最后一段永远会被当成说明，误解就少一个。
    final raw = <String>[
      for (var i = 3; i < p.length; i++)
        if (p[i].trim().isNotEmpty) p[i].trim(),
    ];
    final fact = Fact(
      topicId: cur,
      title: p[1].trim(),
      right: p[2].trim(),
      wrongs: [for (final s in raw) if (!s.startsWith('~')) s],
      note: raw.where((s) => s.startsWith('~')).map((s) => s.substring(1)).join(' '),
    );
    if (fact.wrongs.isEmpty) return;
    facts.add(fact);
    nodes[cur]!.factCount++;
  }

  Topic? operator [](String id) => nodes[id];

  /// 从根到该节点的链
  List<Topic> chainOf(String id) {
    final out = <Topic>[];
    var cur = id;
    while (cur.isNotEmpty && nodes.containsKey(cur)) {
      out.insert(0, nodes[cur]!);
      cur = nodes[cur]!.parentId;
    }
    return out;
  }

  /// 该节点下的全部子节点 id（含自身）
  List<String> subtreeOf(String id) {
    final out = <String>[id];
    for (var i = 0; i < out.length; i++) {
      out.addAll(nodes[out[i]]?.childIds ?? const <String>[]);
    }
    return out;
  }

  List<Fact> factsOf(String topicId) =>
      facts.where((f) => f.topicId == topicId).toList(growable: false);

  /// 树的自检：空节点（有子无题）、孤立节点、单链过深
  List<String> audit() {
    final bad = <String>[];
    if (facts.isEmpty) bad.add('没有任何事实卡');
    for (final n in nodes.values) {
      if (n.factCount == 0 && n.isLeaf) bad.add('叶子节点没有题：${n.id}');
      if (n.depth > 4) bad.add('层级超过 4：${n.id}');
    }
    return bad;
  }

  /// 统计：题量预估 = 每张事实卡能长出的题数
  /// 单选(选对) + 单选(选错) + 对错(正) + 对错(误) + 多选(按节点)
  Map<String, int> stats() {
    var single = 0, judge = 0, multi = 0;
    final byTopic = <String, int>{};
    for (final f in facts) {
      byTopic[f.topicId] = (byTopic[f.topicId] ?? 0) + 1;
      single += 1 + f.wrongs.length; // 正向1 + 每个误解一条「哪句是错的」
      judge += 1 + f.wrongs.length; // right 判对 + 每个 wrong 判错
    }
    for (final c in byTopic.values) {
      if (c >= 3) multi += 1;
    }
    return {
      'facts': facts.length,
      'topics': nodes.length,
      'single': single,
      'judge': judge,
      'multi': multi,
      'total': single + judge + multi,
    };
  }

  /// 某个一级分支下的题量，画像页用来显示「这条路有多少可问的」
  int factCountUnder(String rootId) {
    var n = 0;
    for (final id in subtreeOf(rootId)) {
      n += nodes[id]?.factCount ?? 0;
    }
    return n;
  }

  /// 按证据挑「该往哪钻」。
  ///
  /// 这里改过一版，改的原因很具体：第一版只按「没答过 + 层级浅」打分，
  /// 结果每轮 10 道题均匀铺在 10 个从没碰过的节点上，每个节点永远只有
  /// 一次证据，够不到「看清」的门槛。题库越答越宽，纹理一直是平的——
  /// 那正是用户说的「只有轮廓没有纹理」。
  ///
  /// 现在的规则：
  ///   * 沿一条路来回走三四次，把它走实，再换下一条
  ///   * 父节点答得多，子节点跟着热（这才是往下钻，不是横向摸）
  ///   * 前一小段铺开轮廓，之后就收敛，不再无限铺新分支
  ///   * 跳过降权但不清零
  List<String> drillOrder({
    required Map<String, int> hits,
    required Map<String, int> skips,
    math.Random? rng,
    bool breadth = false,
  }) {
    final r = rng ?? math.Random();

    // 已经踩过的节点数。铺满一打之后就该收手，转入深耕。
    final explored = hits.values.where((e) => e > 0).length;
    final wide = explored < 12;

    final scored = <MapEntry<String, double>>[];

    for (final n in nodes.values) {
      if (n.factCount == 0) continue;
      final h = hits[n.id] ?? 0;
      final s = skips[n.id] ?? 0;
      final heat = n.parentId.isEmpty ? 0 : (hits[n.parentId] ?? 0);

      double score;
      if (h == 0) {
        // 没答过：父节点问得多，这个子节点就优先——
        // 「越答越细」不是靠加深层级，是靠沿着走过的路往下走。
        score = (wide ? 100.0 : 42.0) - n.depth * 4.0;
      } else if (h < 4) {
        // 答过但还没吃透：接着在这条路上问。
        // 递减要够陡：答一次最急，答三次就快让位了。
        const bonus = [40.0, 25.0, 10.0];
        score = 95.0 - n.depth * 2.0 + bonus[h - 1] + r.nextDouble() * 2.0;
      } else if (n.childIds.isNotEmpty) {
        // 已经够清楚，让位给子节点
        score = 10.0 - n.depth.toDouble();
      } else {
        // 叶子节点答穿了：低优先级，但不排除（防题库被答空）
        score = 6.0 - h * 0.5;
      }

      // 父节点热，整支都抬一手。这一项是「往下钻」的引擎：
      // 父节点答得越多，它的子节点越靠前。
      score += heat * 8.0 - s * 8.0;
      scored.add(MapEntry(n.id, score));
    }

    scored.sort((a, b) => b.value.compareTo(a.value));
    if (!breadth) return [for (final e in scored) e.key];

    // 广度优先：按一级分支轮流发牌。
    //
    // 用户的原话是「第一次注册肯定只能答二三十道，那前面这段时间的题目
    // 必须是笼统的、覆盖面很广的」。所以新人的头几轮不能按分数从上往下
    // 切一刀——那样切出来的是同一支里的兄弟节点，看着多，其实只有一条路。
    //
    // 轮流发牌保证：八条一级分支，前八道题就各摸到一次。
    final byRoot = <String, List<String>>{};
    final rootsInOrder = <String>[];
    for (final e in scored) {
      final root = e.key.split('/').first;
      if (!byRoot.containsKey(root)) {
        byRoot[root] = <String>[];
        rootsInOrder.add(root);
      }
      byRoot[root]!.add(e.key);
    }
    var deepest = 0;
    for (final list in byRoot.values) {
      if (list.length > deepest) deepest = list.length;
    }
    final out = <String>[];
    for (var d = 0; d < deepest; d++) {
      for (final root in rootsInOrder) {
        final list = byRoot[root]!;
        if (d < list.length) out.add(list[d]);
      }
    }
    return out;
  }
}
