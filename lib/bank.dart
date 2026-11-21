import 'dart:math' as math;

import 'bank_know.dart';
import 'bank_pref.dart';
import 'core.dart';
import 'profile.dart';

export 'bank_know.dart' show kKnowBank;
export 'bank_pref.dart' show kPrefBank;
export 'profile.dart' show QuizItem, KnowledgeItem, PrefItem, Profile, kAxes;

/// 全部题库的入口。要扩充题量时，只往 bank_know.dart / bank_pref.dart 里加，
/// 这里不需要改。
final List<QuizItem> kBank = <QuizItem>[
  ...kKnowBank,
  ...kPrefBank,
];

int get kBankKnowCount => kKnowBank.length;

int get kBankPrefCount => kPrefBank.length;

/// 新闻挂在主题树上的哪一节。
///
/// 不把标签写进 kNews 的构造函数，是因为新闻会换源、会增减；
/// 用一张「标题关键词 → 节点」的表，源换了只改这张表，排序逻辑不用动。
/// 标不贴切也不会出错，只是那条新闻少一点加权。
const Map<String, List<String>> kNewsTopics = <String, List<String>>{
  'AI 基础设施': ['科技/人工智能/大模型'],
  '渲染框架': ['科技/软件开发/前端'],
  '固定起床时间': ['健康/睡眠/规律'],
  '呼吸道疾病': ['健康/常见病/感冒'],
  '弹性上班': ['职业/办公室/人事/招聘'],
  '生活圈': ['生活/行/坐车'],
  '昼夜温差': ['健康/常见病/感冒'],
  '消费市场': ['职业/零售/门店/收银'],
  '信贷投放': ['钱/借贷/房贷'],
  '人民币汇率': ['世界/经济/汇率'],
  '能源市场': ['环境/能源/煤电'],
  '关键矿产': ['世界/经济/供应链'],
  '战国竹简': ['文化/典籍/文献'],
  '公共文化空间': ['文化/典籍/文献'],
  '联赛进入关键阶段': ['爱好/球类/篮球'],
  '大众路跑': ['体育/跑步/配速'],
  '储能项目': ['科技/能源/储能'],
  '空气质量预报': ['环境/空气/PM2.5'],
  '国防科技': ['军事/装备/雷达'],
  '联合演习': ['军事/国防/演习'],
};

/// 这条新闻命中哪些节点。按标题片段匹配，没命中就返回空。
List<String> topicsOfNews(NewsItem n) {
  for (final e in kNewsTopics.entries) {
    if (n.title.contains(e.key)) return e.value;
  }
  return const <String>[];
}

/// 按画像挑新闻。
///
/// 规则：
///   * 用户越关心的维度，越靠前；但该维度样本还少时权重打折——
///     答过一题就以为人家爱看军事，比不排序还糟。
///   * 一次播报里同一维度最多一条，避免三条全是科技。
List<NewsItem> pickNews(Profile p, int n, {math.Random? rng}) {
  final r = rng ?? math.Random();
  final ranked = <NewsItem>[...kNews]..shuffle(r);

  double weight(NewsItem item) {
    final s = p.score[item.topic] ?? 0;
    final c = p.confidenceOf(item.topic);
    var w = s * (0.35 + 0.65 * c);

    // 主题节点加权：这才是「答得越细，新闻越对味」真正生效的地方。
    // 十维只说明你爱看科技；节点才说得清你是爱看芯片还是爱看前端框架。
    for (final id in topicsOfNews(item)) {
      final th = p.topicHits[id] ?? 0;
      final sk = p.topicSkips[id] ?? 0;
      if (th > 0) {
        w += (1 - math.exp(-th / 2.0)) * 6.0;
      }
      // 跳得多的分支，相关新闻往后排。跳过不是没回答，它是不关心的表态。
      if (sk > 0) w -= math.min(sk, 3) * 2.0;
    }
    return w;
  }

  ranked.sort((a, b) => weight(b).compareTo(weight(a)));

  final out = <NewsItem>[];
  final usedTopics = <String>{};
  for (final item in ranked) {
    if (out.length >= n) break;
    if (usedTopics.contains(item.topic)) continue;
    out.add(item);
    usedTopics.add(item.topic);
  }
  for (final item in ranked) {
    if (out.length >= n) break;
    if (!out.contains(item)) out.add(item);
  }
  return out;
}

/// 今天该看哪三条新闻。
///
/// 第一次要的时候按当时的画像挑好并**记住**，当天不再变。
/// 不记住的后果很具体：用户上午答了几道题，画像往财经偏了一点，
/// 下午打开「新闻」板块发现今天的三条已经换了一批——播报里念的那条找不到了。
/// 新闻是「今天发生了什么」，不该随答题漂移；换天再换一批。
///
/// 顺带把 key 的数量管住：只留最近 7 天，不然 settings 里会攒出几百个键。
List<NewsItem> todayNews(Profile p, {DateTime? at}) {
  final d = at ?? DateTime.now();
  final dayKey = 'news.${d.year}-${two(d.month)}-${two(d.day)}';

  final saved = Store.s(dayKey, '');
  if (saved.isNotEmpty) {
    final titles = saved.split('\u0001');
    final out = <NewsItem>[];
    for (final t in titles) {
      for (final n in kNews) {
        if (n.title == t) {
          out.add(n);
          break;
        }
      }
    }
    // 必须全部命中才用缓存：题库换了一版、标题改了字，就重新挑，
    // 而不是返回两条旧新闻加一条空。
    if (out.length == titles.length && out.length == 3) return out;
  }

  final picked = pickNews(p, 3, rng: math.Random(d.year * 10000 + d.month * 100 + d.day));
  Store.set(dayKey, picked.map((e) => e.title).join('\u0001'));
  _trimNewsKeys(d);
  return picked;
}

/// 只保留最近 7 天的新闻缓存键
void _trimNewsKeys(DateTime today) {
  final keep = <String>{};
  for (var i = 0; i < 7; i++) {
    final d = today.subtract(Duration(days: i));
    keep.add('news.${d.year}-${two(d.month)}-${two(d.day)}');
  }
  final drop = Store.settings.keys
      .where((k) => k.startsWith('news.') && !keep.contains(k))
      .toList();
  if (drop.isEmpty) return;
  for (final k in drop) {
    Store.settings.remove(k);
  }
  Store.saveSettings();
}

/// 打乱选项顺序。
///
/// 不打乱的后果很实在：偏好题里 A 选项往往落在科技/财经上，
/// 用户如果习惯性选最上面那个，画像就会被「位置偏好」污染——
/// 得到的不是他的兴趣，而是他手指的习惯。知识题的答案下标也要跟着挪。
QuizItem _shuffleOptions(QuizItem q, math.Random r) {
  final order = List<int>.generate(q.options.length, (i) => i)..shuffle(r);
  final opts = <String>[for (final i in order) q.options[i]];

  if (q is KnowledgeItem) {
    return KnowledgeItem(
      id: q.id,
      category: q.category,
      axes: q.axes,
      question: q.question,
      options: opts,
      answer: order.indexOf(q.answer),
      explain: q.explain,
    );
  }
  final p = q as PrefItem;
  return PrefItem(
    id: p.id,
    scene: p.scene,
    opts: opts,
    weights: <Map<String, double>>[for (final i in order) p.weights[i]],
  );
}

/// 混合抽题：约 30% 知识题 + 70% 偏好题，且偏好题优先补最模糊的维度。
///
/// [count] 是一次晨间流程要出的题数；已答过的题排到队尾，但不丢弃——
/// 题库答穿以后还能轮回，不会出现「今天没题可答」。
List<QuizItem> pickMixed(int count, Profile p, {math.Random? rng}) {
  final r = rng ?? math.Random();
  final know = kKnowBank.toList()..shuffle(r);
  final pref = kPrefBank.toList()..shuffle(r);

  int unseen(QuizItem q) => p.answered.contains(q.id) ? 1 : 0;
  know.sort((a, b) => unseen(a).compareTo(unseen(b)));
  pref.sort((a, b) => unseen(a).compareTo(unseen(b)));

  // 偏好题里，先把命中「当前最模糊维度」的往前放
  final vague = p.vaguestAxis();
  pref.sort((a, b) {
    final fa = a.weights.any((w) => w.containsKey(vague)) ? 0 : 1;
    final fb = b.weights.any((w) => w.containsKey(vague)) ? 0 : 1;
    return fa.compareTo(fb);
  });

  final wantKnow = (count * 0.3).round().clamp(1, count);
  final wantPref = count - wantKnow;
  final pool = <QuizItem>[...know.take(wantKnow), ...pref.take(wantPref)];

  // 某一类不够时，用另一类补满
  var i = wantKnow, j = wantPref;
  while (pool.length < count && (i < know.length || j < pref.length)) {
    if (i < know.length) pool.add(know[i++]);
    if (pool.length < count && j < pref.length) pool.add(pref[j++]);
  }

  // 打散；但第一题固定给偏好题——刚醒来不适合先算数。
  pool.shuffle(r);
  final firstPref = pool.indexWhere((e) => !e.isKnowledge);
  if (firstPref > 0) {
    final q = pool.removeAt(firstPref);
    pool.insert(0, q);
  }
  return [for (final q in pool) _shuffleOptions(q, r)];
}

/// 题库自检：id 重复会让「已答过」的去重失效，开发期跑一下能提前发现。
List<String> auditBank() {
  final seen = <String>{};
  final dup = <String>[];
  for (final q in kBank) {
    if (!seen.add(q.id)) dup.add(q.id);
    if (q.options.length < 2) dup.add('${q.id}(选项<2)');
    if (q.isKnowledge && (q.answer < 0 || q.answer >= q.options.length)) {
      dup.add('${q.id}(答案越界)');
    }
  }
  return dup;
}
