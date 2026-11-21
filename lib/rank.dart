// ============================================================================
// 段位与晨序榜
//
// 排名的心理很具体：想看见自己在往上走，也想看见别人走到哪了。但这个 App
// 的答题记录只存在这台手机里，不上传、不联网——真实的「全国榜」需要服务器，
// 也需要把每个人的答题记录交出去，这两件事都不是现在该悄悄做的。
//
// 所以这里只做两件老实的事：
//   1. 段位：把「答了多少题」翻译成一个能看见位置的层级，不是虚的分数。
//   2. 对拼码：想跟谁比，就把自己这段码发过去，对方贴进来即可对拼。
//      不必注册、不必上传，谁的数据都不离开自己的手机。
// ============================================================================

import 'journal.dart';
import 'profile.dart';
import 'qbank.dart';

class RankTier {
  /// 段位名
  final String name;

  /// 达到这一段需要的答题数
  final int at;

  /// 一句说明：这一段的人大概是什么状态
  final String note;

  const RankTier(this.name, this.at, this.note);
}

/// 最后一段的门槛正好是题库总量——「破晓」的意思是整座山走完了。
const List<RankTier> kTiers = <RankTier>[
  RankTier('初醒', 0, '刚睁眼，先摸清大方向'),
  RankTier('上路', 30, '几条路已经露头'),
  RankTier('熟路', 100, '走过的那几条开始有纹理'),
  RankTier('行家', 300, '问得越细，答得越稳'),
  RankTier('老手', 700, '大半张地图都踩过了'),
  RankTier('明白人', 1400, '别人说不清的地方你能说清'),
  RankTier('引路人', 2200, '能带着别人走你走过的路'),
  RankTier('破晓', 3224, '整座山走完了'),
];

class Rank {
  /// 题库总量，同时是最后一段的门槛
  static int get total => QBank.instance.total;

  static int tierIndex(int answered) {
    var i = 0;
    for (var k = 0; k < kTiers.length; k++) {
      if (answered >= kTiers[k].at) i = k;
    }
    return i;
  }

  static RankTier tierOf(int answered) => kTiers[tierIndex(answered)];

  static RankTier? nextOf(int answered) {
    final i = tierIndex(answered);
    return i + 1 < kTiers.length ? kTiers[i + 1] : null;
  }

  /// 距下一段还差几题
  static int toNext(int answered) {
    final n = nextOf(answered);
    if (n == null) return 0;
    return (n.at - answered).clamp(0, 1 << 30);
  }

  /// 本段内的进度 0~1（最后一段恒为 1）
  static double progress(int answered) {
    final i = tierIndex(answered);
    if (i + 1 >= kTiers.length) return 1.0;
    final from = kTiers[i].at;
    final to = kTiers[i + 1].at;
    if (to <= from) return 1.0;
    return ((answered - from) / (to - from)).clamp(0.0, 1.0);
  }

  /// 从画像与日志里取当前进度，供页面直接用
  static int answeredOf(Profile p) => p.answered.length;

  /// 累计答对多少道：日志里 verdict=right 的答题事件。
  /// 封顶到画像的已答数——画像被清空过而日志还留着时，不能报出
  /// 「答了 1 道、对了 17 道」这种自己打自己脸的数。
  static int correctOf() {
    final answered = Profile.load().answered.length;
    final right = Journal.events
        .where((e) => e.kind == JKind.quiz && e.verdict == 'right')
        .length;
    return right > answered ? answered : right;
  }

  // ------------------------------------------------------------ 对拼码
  //
  // 不带任何能认出人的信息：只有答题数、连续天数、答对数和一段校验位。
  // 校验位挡的是「手抖改错一个数字」和「随便编一个大数」，不是防作弊——
  // 本地应用本来也防不住作弊，与其假装严谨，不如把话说清楚。

  static String codeOf({required int answered, required int streak, required int correct}) {
    final payload = '$answered-$streak-$correct';
    return 'CX1-$payload-${_check(payload)}';
  }

  static Map<String, int>? parseCode(String raw) {
    final s = raw.trim().toUpperCase().replaceAll(' ', '');
    final parts = s.split('-');
    if (parts.length != 5 || parts[0] != 'CX1') return null;
    final a = int.tryParse(parts[1]);
    final st = int.tryParse(parts[2]);
    final c = int.tryParse(parts[3]);
    if (a == null || st == null || c == null) return null;
    if (a < 0 || st < 0 || c < 0) return null;
    if (_check('${parts[1]}-${parts[2]}-${parts[3]}') != parts[4]) return null;
    return {'answered': a, 'streak': st, 'correct': c};
  }

  /// 四位以内的十六进制校验
  static String _check(String payload) {
    var h = 0x811c9dc5;
    for (final unit in payload.codeUnits) {
      h = (h ^ unit) * 0x01000193 & 0xFFFFFFFF;
    }
    return (h & 0xFFFF).toRadixString(16).toUpperCase().padLeft(4, '0');
  }
}

/// 段位的一句话对照，给「我的」页面用
String tierLine(int answered) {
  final t = Rank.tierOf(answered);
  final n = Rank.nextOf(answered);
  if (n == null) return '${t.name} · 题库已走完';
  return '${t.name} · 距${n.name}还差 ${Rank.toNext(answered)} 题';
}
