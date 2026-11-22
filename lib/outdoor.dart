import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'core.dart';

/// 出门判定 v1：基准照比对。
///
/// 为什么不能只靠「拍了一张照片」：躺在床上拍天花板、拍自己的手掌，
/// 一样是照片。判定要回答的是一个更窄的问题——这张画面，和你平常出门时
/// 看到的样子像不像。所以先在设置里登记几张「门外基准照」（门口、电梯、路边、
/// 小区门口），打卡时拿新照片去比。
///
/// 必须说清的局限：
/// - 夜里、大雾、纯黑画面会让相似度整体偏高，判定会变宽松；
/// - 对着基准照翻拍可以绕过。
/// 它的作用是提高作弊成本，不是密码级验证。真要「证明人真的出去了」，
/// 需要定位是否离开家、步数变化、Wi-Fi/基站切换这些信号，那是 V2 的「出门证据链」，
/// V1 先把拍照 + 基准比对这条最能落地的链路跑通。
class Outdoor {
  static const _key = 'outdoorBaselines';

  /// 通过阈值。0.62 是按「同一处换个角度」和「对着床/墙拍」两类样本折中出来的：
  /// 低于它基本可以肯定画面和门外无关；再高就会把正常换角度拍的照片拦掉。
  static const passScore = 0.62;

  static List<Map<String, String>> all() {
    final raw = Store.s(_key, '');
    if (raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return [];
      return list
          .whereType<Map>()
          .map((e) => {
                'path': '${e['path'] ?? ''}',
                'tag': '${e['tag'] ?? ''}',
              })
          .where((e) => e['path']!.isNotEmpty && File(e['path']!).existsSync())
          .toList();
    } catch (_) {
      return [];
    }
  }

  static bool get registered => all().isNotEmpty;

  static Future<void> add(String path, String tag) async {
    final list = all()..add({'path': path, 'tag': tag});
    Store.set(_key, jsonEncode(list));
  }

  static Future<void> remove(String path) async {
    final list = all()..removeWhere((e) => e['path'] == path);
    Store.set(_key, jsonEncode(list));
  }

  static void clear() => Store.set(_key, '');

  /// 拍完打卡照后调用。没有登记基准照时放行，但结论里会写明「仅留证」，
  /// 界面也要提示用户去登记，否则这套判定等于没开。
  static Future<OutdoorVerdict> verify(String path) async {
    final base = all();
    if (base.isEmpty) {
      return const OutdoorVerdict(score: 1, pass: true, hasBaseline: false);
    }
    final mine = await _signature(path);
    if (mine == null) {
      return const OutdoorVerdict(score: 0, pass: false, hasBaseline: true);
    }
    var best = 0.0;
    String bestTag = '';
    for (final b in base) {
      final s = await _signature(b['path']!);
      if (s == null) continue;
      final v = _similarity(mine, s);
      if (v > best) {
        best = v;
        bestTag = b['tag'] ?? '';
      }
    }
    return OutdoorVerdict(
      score: best,
      pass: best >= passScore,
      hasBaseline: true,
      matchedTag: bestTag,
    );
  }

  /// 24×24 灰度图，归一化后做相关性比较。
  /// 先缩到这个尺寸：既抹掉噪点和细节差异，又保留「哪里亮、哪里暗」的布局，
  /// 比直方图更能区分"同一条走廊换个角度"和"对着墙拍"。
  static Future<List<double>?> _signature(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final codec =
          await ui.instantiateImageCodec(bytes, targetWidth: 24, targetHeight: 24);
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      frame.image.dispose();
      if (data == null) return null;
      final d = data.buffer.asUint8List();
      final gray = List<double>.filled(24 * 24, 0);
      for (var i = 0; i < 24 * 24; i++) {
        final r = d[i * 4].toDouble();
        final g = d[i * 4 + 1].toDouble();
        final b = d[i * 4 + 2].toDouble();
        gray[i] = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0;
      }
      return gray;
    } catch (_) {
      return null;
    }
  }

  /// 零均值归一化互相关，返回 0~1（1 = 完全一致）。
  /// 用相关性而不是逐像素差值：整体偏暗/偏亮不该影响"是不是同一个地方"。
  static double _similarity(List<double> a, List<double> b) {
    final n = math.min(a.length, b.length);
    if (n == 0) return 0;
    var ma = 0.0, mb = 0.0;
    for (var i = 0; i < n; i++) {
      ma += a[i];
      mb += b[i];
    }
    ma /= n;
    mb /= n;
    var cov = 0.0, va = 0.0, vb = 0.0;
    for (var i = 0; i < n; i++) {
      final da = a[i] - ma, db = b[i] - mb;
      cov += da * db;
      va += da * da;
      vb += db * db;
    }
    if (va <= 1e-6 || vb <= 1e-6) return 0;
    final r = cov / math.sqrt(va * vb);
    return ((r + 1) / 2).clamp(0.0, 1.0);
  }
}

class OutdoorVerdict {
  final double score;
  final bool pass;

  /// 有没有登记过基准照。false = 这次只是留证，判定没生效
  final bool hasBaseline;
  final String matchedTag;

  const OutdoorVerdict({
    required this.score,
    required this.pass,
    required this.hasBaseline,
    this.matchedTag = '',
  });

  int get percent => (score * 100).round();
}
