import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'glass.dart';
import 'liquid.dart';

/// App 版本号（与 pubspec.yaml 同步）。展示与崩溃日志都用它，避免写死多处。
const String kAppVersion = '1.21.0';

// ============================================================================
// 1. 设计系统（Minimal / 安静 / 温暖）
//    所有页面统一从这里取色与字号，保证视觉一致。
// ============================================================================

/// 一套配色。换肤 = 把 AppColor 指向另一个 ThemePack，整棵树重建。
class ThemePack {
  final String id;
  final String name;
  final String desc;
  final bool dark;
  final Color bg;
  final Color card;
  final Color ink;
  final Color sub;
  final Color line;
  final Color accent;
  final Color accentSoft;
  final Color ok;

  const ThemePack({
    required this.id,
    required this.name,
    required this.desc,
    required this.bg,
    required this.card,
    required this.ink,
    required this.sub,
    required this.line,
    required this.accent,
    required this.accentSoft,
    required this.ok,
    this.dark = false,
  });
}

/// 内置主题包。第一项是默认款，和 V1 的视觉完全一致。
const kThemes = <ThemePack>[
  ThemePack(
      id: 'paper',
      name: '暖纸',
      desc: '默认 · 久看不累',
      bg: Color(0xFFFBF8F3),
      card: Color(0xFFFFFFFF),
      ink: Color(0xFF1C1A17),
      sub: Color(0xFF8C857A),
      line: Color(0xFFEDE6DA),
      accent: Color(0xFFC0703C),
      accentSoft: Color(0xFFF5E7D9),
      ok: Color(0xFF5B7F6B)),
  ThemePack(
      id: 'night',
      name: '墨夜',
      desc: '深夜与早起都不刺眼',
      dark: true,
      bg: Color(0xFF161513),
      card: Color(0xFF211F1C),
      ink: Color(0xFFF2EDE4),
      sub: Color(0xFF9A9285),
      line: Color(0xFF2F2C27),
      accent: Color(0xFFD98850),
      accentSoft: Color(0xFF352A20),
      ok: Color(0xFF7FA98F)),
  ThemePack(
      id: 'moss',
      name: '青苔',
      desc: '清早的绿',
      bg: Color(0xFFF4F7F1),
      card: Color(0xFFFFFFFF),
      ink: Color(0xFF1D2A22),
      sub: Color(0xFF7C8A80),
      line: Color(0xFFE2EADF),
      accent: Color(0xFF4F7D5A),
      accentSoft: Color(0xFFE3EFE4),
      ok: Color(0xFF6F9B5E)),
  ThemePack(
      id: 'sea',
      name: '海盐',
      desc: '凉一点，适合夏天',
      bg: Color(0xFFF2F7FA),
      card: Color(0xFFFFFFFF),
      ink: Color(0xFF17242C),
      sub: Color(0xFF7A8B96),
      line: Color(0xFFDFEAF1),
      accent: Color(0xFF3F7E9B),
      accentSoft: Color(0xFFE0EFF6),
      ok: Color(0xFF4F9A87)),
  ThemePack(
      id: 'sakura',
      name: '樱灰',
      desc: '淡粉，不甜腻',
      bg: Color(0xFFFBF6F6),
      card: Color(0xFFFFFFFF),
      ink: Color(0xFF2A2224),
      sub: Color(0xFF8E8083),
      line: Color(0xFFEFE4E5),
      accent: Color(0xFFC0707E),
      accentSoft: Color(0xFFF7E6E8),
      ok: Color(0xFF6F9080)),
  ThemePack(
      id: 'mono',
      name: '极简白',
      desc: '只有黑白灰',
      bg: Color(0xFFF7F7F7),
      card: Color(0xFFFFFFFF),
      ink: Color(0xFF111111),
      sub: Color(0xFF7A7A7A),
      line: Color(0xFFE6E6E6),
      accent: Color(0xFF333333),
      accentSoft: Color(0xFFECECEC),
      ok: Color(0xFF4A7A5E)),
];

/// 全局配色入口。所有页面都写 AppColor.xxx，换肤只需要换 _pack 并通知重建。
class AppColor {
  static ThemePack _pack = kThemes.first;

  /// 换肤后监听它重建整棵树
  static final ValueNotifier<String> notifier = ValueNotifier<String>(kThemes.first.id);

  static ThemePack get pack => _pack;
  static bool get isDark => _pack.dark;

  static void apply(String id) {
    final next = kThemes.firstWhere((t) => t.id == id, orElse: () => kThemes.first);
    _pack = next;
    if (notifier.value != next.id) notifier.value = next.id;
  }

  static Color get bg => _pack.bg;
  static Color get card => _pack.card;

  /// v1.19.0：液态风格下字色跟着液态主题走，不再用纸感主题的字色。
  /// 曜石深潭是暗卡配浅字；其余三套是亮卡配深字。
  static Color get ink {
    final lt = Liquid.theme;
    return lt == null ? _pack.ink : Liquid.inkOf(lt);
  }

  // v1.9.0 玻璃态派生色：所有页面原来写死的 `color: AppColor.card` 换成
  // glassCard 后，卡片就自动半透明、能透出底层光斑；描边换成高光色，
  // 于是「一层背景 + 一层半透明卡 + 一层内容」的纵深全 App 都成立。
  // 选「原纸」时三个 getter 原样退回，和旧版一个像素都不差。
  // （core.dart 与 glass.dart 互相 import 是允许的：这里全是运行时 getter，
  //   不涉及循环常量初始化。）
  /// v1.17.1：液态风格下卡片用固定亮色，不跟随系统配色。
  /// 这样新闻/记录/我的等页面那些直接写 AppColor.glassCard 的容器
  /// 会自动变亮，不会在深色背景上暗成一团。
  static Color get glassCard {
    final lt = Liquid.theme;
    if (lt != null) return Liquid.surfaceOf(lt);
    return Glass.on ? _pack.card.withOpacity(Glass.style.cardAlpha) : _pack.card;
  }

  static Color get glassEdge {
    final lt = Liquid.theme;
    if (lt != null) return Liquid.edgeOf(lt);
    return glassEdgeColor();
  }

  static Color get glassPanel {
    final lt = Liquid.theme;
    if (lt != null) return Liquid.surfaceOf(lt);
    return Glass.on
        ? panel.withOpacity((Glass.style.cardAlpha - 0.06).clamp(0.12, 1.0))
        : panel;
  }
  static Color get sub {
    final lt = Liquid.theme;
    return lt == null ? _pack.sub : Liquid.subOf(lt);
  }

  static Color get line => _pack.line;

  static Color get accent {
    final lt = Liquid.theme;
    return lt == null ? _pack.accent : Liquid.accentOf(lt);
  }

  static Color get accentSoft {
    final lt = Liquid.theme;
    return lt == null ? _pack.accentSoft : lt.cardTo.withOpacity(0.55);
  }

  static Color get ok => _pack.ok;

  /// 说明性小字。旧页面（闹钟/我的）写死了比 sub 更深的褐色；
  /// 液态风格下必须换成该主题的 sub，否则暗卡上还是深字压暗底。
  static Color get softInk {
    final lt = Liquid.theme;
    return lt == null ? const Color(0xFF6B5A45) : Liquid.subOf(lt);
  }

  /// 直接画在**背景**上的字（页面大标题、分组小标题、说明行），不在卡片里。
  /// 液态风格四套背景全是深色底，这些字必须恒用浅色；卡片里的字才跟主题走。
  /// 关掉液态则原样退回纸感主题。
  static Color get bgInk => Liquid.on ? const Color(0xFFF1F7F4) : _pack.ink;
  static Color get bgSub => Liquid.on ? const Color(0xFFB9D2C6) : _pack.sub;
  static Color get bgAccent => Liquid.on ? const Color(0xFF8FE3C1) : _pack.accent;

  /// 当前主文字是不是浅色。状态栏图标、压在 ink 上的字都按它选正反色。
  static bool get textIsLight {
    final lt = Liquid.theme;
    return lt == null ? _pack.dark : Liquid.luminance(Liquid.inkOf(lt)) > 0.5;
  }

  /// 压在 ink 色块上的前景色。
  /// 浅色字配深色字，深色字配白字，避免「浅底白字」。
  static Color get onInk => textIsLight ? const Color(0xFF10201B) : const Color(0xFFFFFFFF);

  /// 浅色纸感面板底色（说明块、占位块用）。深色主题下换成同主题的浅强调底。
  static Color get panel => _pack.dark ? _pack.accentSoft : const Color(0xFFF6F2EA);

  /// 纸感面板的描边
  static Color get panelLine => _pack.dark ? _pack.line : const Color(0xFFEDE3D4);
}

ThemeData buildAppTheme() {
  final base = AppColor.isDark
      ? ThemeData.dark(useMaterial3: true)
      : ThemeData.light(useMaterial3: true);
  return base.copyWith(
    // v1.9.0：页面背景交给全局 GlassBackdrop 画，Scaffold 必须透明，
    // 否则会把那层会呼吸的光斑盖住，玻璃卡片也就没东西可透。
    scaffoldBackgroundColor: Colors.transparent,
    colorScheme: base.colorScheme.copyWith(
      primary: AppColor.accent,
      surface: AppColor.card,
      onSurface: AppColor.ink,
    ),
    textTheme: base.textTheme.apply(
      bodyColor: AppColor.ink,
      displayColor: AppColor.ink,
    ),
  );
}

// ============================================================================
// 2. 数据模型
// ============================================================================

class Alarm {
  int id;
  int hour;
  int minute;
  String label;
  List<int> days; // 1=周一 ... 7=周日；空数组表示「仅一次」
  bool enabled;
  int snoozeMinutes;
  int quizCount;

  Alarm({
    required this.id,
    required this.hour,
    required this.minute,
    this.label = '晨间唤醒',
    List<int>? days,
    this.enabled = true,
    this.snoozeMinutes = 5,
    this.quizCount = 10,
  }) : days = days ?? <int>[];

  String get timeText =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  bool get once => days.isEmpty;

  String get repeatText {
    if (days.isEmpty) return '仅一次';
    if (days.length == 7) return '每天';
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    final sorted = [...days]..sort();
    if (const [1, 2, 3, 4, 5].every(sorted.contains) && sorted.length == 5) {
      return '工作日';
    }
    if (const [6, 7].every(sorted.contains) && sorted.length == 2) return '周末';
    return sorted.map((d) => '周${names[d - 1]}').join(' ');
  }

  /// 下一次触发时间；未启用或不再触发返回 null
  DateTime? nextTrigger(DateTime now) {
    if (!enabled) return null;
    if (days.isEmpty) {
      var t = DateTime(now.year, now.month, now.day, hour, minute);
      if (!t.isAfter(now)) t = t.add(const Duration(days: 1));
      return t;
    }
    for (var i = 0; i < 8; i++) {
      final d = now.add(Duration(days: i));
      if (!days.contains(d.weekday)) continue;
      final t = DateTime(d.year, d.month, d.day, hour, minute);
      if (t.isAfter(now)) return t;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'hour': hour,
        'minute': minute,
        'label': label,
        'days': days,
        'enabled': enabled,
        'snooze': snoozeMinutes,
        'quizCount': quizCount,
      };

  static Alarm fromJson(Map<String, dynamic> m) => Alarm(
        id: (m['id'] as num).toInt(),
        hour: (m['hour'] as num).toInt(),
        minute: (m['minute'] as num).toInt(),
        label: (m['label'] ?? '晨间唤醒') as String,
        days: ((m['days'] ?? const []) as List).map((e) => (e as num).toInt()).toList(),
        enabled: (m['enabled'] ?? true) as bool,
        snoozeMinutes: ((m['snooze'] ?? 5) as num).toInt(),
        quizCount: ((m['quizCount'] ?? 10) as num).toInt(),
      );
}

class MorningRecord {
  String date; // yyyy-MM-dd
  int alarmId;
  int wokeAt; // 毫秒时间戳
  int quizCorrect;
  int quizTotal;
  bool newsDone;
  String photoPath;
  bool completed;

  MorningRecord({
    required this.date,
    required this.alarmId,
    required this.wokeAt,
    this.quizCorrect = 0,
    this.quizTotal = 0,
    this.newsDone = false,
    this.photoPath = '',
    this.completed = false,
  });

  int get durationMinutes {
    final d = DateTime.now().millisecondsSinceEpoch - wokeAt;
    return d <= 0 ? 0 : (d / 60000).round();
  }

  Map<String, dynamic> toJson() => {
        'date': date,
        'alarmId': alarmId,
        'wokeAt': wokeAt,
        'quizCorrect': quizCorrect,
        'quizTotal': quizTotal,
        'newsDone': newsDone,
        'photo': photoPath,
        'completed': completed,
      };

  static MorningRecord fromJson(Map<String, dynamic> m) => MorningRecord(
        date: m['date'] as String,
        alarmId: ((m['alarmId'] ?? 0) as num).toInt(),
        wokeAt: ((m['wokeAt'] ?? 0) as num).toInt(),
        quizCorrect: ((m['quizCorrect'] ?? 0) as num).toInt(),
        quizTotal: ((m['quizTotal'] ?? 0) as num).toInt(),
        newsDone: (m['newsDone'] ?? false) as bool,
        photoPath: (m['photo'] ?? '') as String,
        completed: (m['completed'] ?? false) as bool,
      );
}

// ============================================================================
// 3. 原生桥（闹钟调度 / 通知 / 相机 / TTS / 本地键值存储 / 权限）
//    关键能力全部走 Android 原生，不依赖第三方插件，双端各自实现即可。
// ============================================================================

class Bridge {
  static const MethodChannel _ch = MethodChannel('morning/native');

  static Future<T?> _call<T>(String method, [dynamic args]) async {
    try {
      final r = await _ch.invokeMethod<T>(method, args);
      return r;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  // 本地存储
  static Future<String?> getPref(String key) => _call<String>('getPref', {'key': key});
  static Future<void> setPref(String key, String value) =>
      _call('setPref', {'key': key, 'value': value});

  // 闹钟
  static Future<void> syncAlarms(String json) => _call('syncAlarms', {'json': json});
  static Future<void> ringTest() => _call('ringTest');

  // 权限
  static Future<bool> canScheduleExact() async =>
      (await _call<bool>('canScheduleExact')) ?? true;
  static Future<bool> hasNotificationPermission() async =>
      (await _call<bool>('hasNotificationPermission')) ?? true;
  static Future<bool> canUseFsi() async => (await _call<bool>('canUseFsi')) ?? true;

  /// 是否已在电池优化白名单里（true = 系统不限制后台）
  static Future<bool> isIgnoringBattery() async =>
      (await _call<bool>('isIgnoringBattery')) ?? false;
  static Future<bool> requestPermission(String what) async =>
      (await _call<bool>('requestPermission', {'what': what})) ?? false;
  static Future<void> openSettings(String target) => _call('openSettings', {'target': target});

  // 相机
  static Future<String?> takePhoto() => _call<String>('takePhoto');

  /// v1.17.0 头像：从相册挑一张。原生负责裁方、缩到 256px、压 JPEG 再 base64，
  /// 返回 {ok, b64|reason}。reason: cancel / no_picker / decode / oom / busy
  static Future<Map<String, dynamic>> pickAvatar() async {
    final r = await _call<Map>('pickAvatar');
    return r == null
        ? <String, dynamic>{'ok': false, 'reason': 'unavailable'}
        : Map<String, dynamic>.from(r);
  }

  /// v1.17.0 头像：当场拍一张。返回值同上。
  static Future<Map<String, dynamic>> shootAvatar() async {
    final r = await _call<Map>('shootAvatar');
    return r == null
        ? <String, dynamic>{'ok': false, 'reason': 'unavailable'}
        : Map<String, dynamic>.from(r);
  }

  // 语音合成
  // 返回 {ok, state}：ok=false 说明本机没有可用语音引擎，需要引导用户安装
  static Future<Map<String, dynamic>> speak(String text) async {
    final r = await _call<Map>('speak', {'text': text});
    return r == null ? <String, dynamic>{} : Map<String, dynamic>.from(r);
  }

  static Future<void> stopSpeak() => _call('stopSpeak');

  /// v1.13.0：打卡成功 → 停掉强制播报、关掉响铃页、清空今天的贪睡额度。
  /// 这是「闹钟什么时候才算结束」的唯一出口。
  static Future<void> stopRing() => _call('stopRing');

  /// 今天贪睡了几次 / 上限几次 / 现在是不是强制播报模式
  static Future<Map<String, dynamic>> snoozeState() async {
    final r = await _call<Map>('snoozeState');
    return r == null ? <String, dynamic>{} : Map<String, dynamic>.from(r);
  }

  /// v1.9.0：播报语速，立刻作用于已绑定的系统语音引擎。
  static Future<void> setSpeechRate(double rate) =>
      _call('setSpeechRate', {'rate': rate});

  /// 播放包里带的真人音色音频（键名见 [newsSampleKey]）。
  /// 返回 ok=false 表示这条没有预生成音频，调用方应退回 [speak]。
  static Future<Map<String, dynamic>> playSample(String name) async {
    final r = await _call<Map>('playSample', {'name': name});
    return r == null ? <String, dynamic>{'ok': false} : Map<String, dynamic>.from(r);
  }

  /// 连续播报：一次把整串交给原生，原生播完一条自动接下一条。
  ///
  /// 为什么不在这里用 Timer 串：MediaPlayer 播完才有 onCompletion，Flutter 侧
  /// 只能靠「时长 + 缓冲」猜下一句什么时候开始。猜早了掐掉半句，猜晚了静默几秒，
  /// 而音频长度每条都不一样——这个猜法注定不稳。串行必须交给原生。
  ///
  /// [items] 每项形如 `{'sample': 'n03'}` 或 `{'text': '…'}`。
  static Future<Map<String, dynamic>> playQueue(List<Map<String, String>> items) async {
    final r = await _call<Map>('playQueue', {'items': items});
    return r == null ? <String, dynamic>{'ok': false} : Map<String, dynamic>.from(r);
  }

  /// 连续播报的进度事件：begin / start / skip / done，字段 index、total
  static Stream<Map<String, dynamic>> get playEvents {
    _bindPlayHandler();
    return _playCtrl.stream;
  }

  static final StreamController<Map<String, dynamic>> _playCtrl =
      StreamController<Map<String, dynamic>>.broadcast();
  static bool _playHandlerBound = false;

  static void _bindPlayHandler() {
    if (_playHandlerBound) return;
    _playHandlerBound = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method != 'onPlayState') return null;
      final m = call.arguments;
      if (m is Map) _playCtrl.add(Map<String, dynamic>.from(m));
      return null;
    });
  }

  /// 用系统浏览器打开官方渠道（只放行 https）
  static Future<bool> openUrl(String url) async =>
      (await _call<bool>('openUrl', {'url': url})) ?? false;

  /// 强制重建语音引擎并重新体检。
  /// 用于「引擎被系统回收」「绑定时偶发失败」这类一次性故障——重试一次就能恢复，
  /// 不需要用户杀掉 App。
  static Future<Map<String, dynamic>> retryTts() async {
    final r = await _call<Map>('retryTts');
    return r == null ? <String, dynamic>{} : Map<String, dynamic>.from(r);
  }

  /// 语音引擎体检：{state, ready, engine, detail, mediaVolume}
  /// state: init / ready / no_engine / no_chinese / bind_failed / timeout
  static Future<Map<String, dynamic>> ttsStatus() async {
    final r = await _call<Map>('ttsStatus');
    return r == null ? <String, dynamic>{} : Map<String, dynamic>.from(r);
  }

  /// 等体检跑完（引擎绑定是异步的），最多等 3 秒
  static Future<Map<String, dynamic>> ttsStatusAwait({int timeoutMs = 3000}) async {
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    var s = await ttsStatus();
    while (s['state'] == 'init' && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 250));
      s = await ttsStatus();
    }
    return s;
  }

  /// 语音不可用时给用户看的说明 + 是否可修复
  static String ttsStateText(String state) {
    switch (state) {
      case 'no_engine':
        return '本机未安装语音合成引擎，朗读无法出声';
      case 'no_chinese':
        return '语音引擎缺少中文语音包，朗读无法出声';
      case 'bind_failed':
        return '语音引擎启动失败，朗读无法出声';
      case 'timeout':
        return '语音引擎响应超时，朗读无法出声';
      case 'ready':
        return '语音引擎正常';
      default:
        return '语音引擎检测中';
    }
  }

  // 设备与启动事件
  static Future<Map<String, dynamic>?> deviceInfo() async {
    final r = await _call<Map>('deviceInfo');
    return r == null ? null : Map<String, dynamic>.from(r);
  }

  /// 由「响铃页 / 通知」拉起 App 时携带的事件，取一次即清除
  static Future<Map<String, dynamic>?> consumeLaunchEvent() async {
    final r = await _call<Map>('consumeLaunchEvent');
    return r == null ? null : Map<String, dynamic>.from(r);
  }

  /// 撤销「追赶」。打卡完成或主动放弃时必须调——不调的话，今天还会被反复拉回来。
  static Future<void> cancelChase() => _call('cancelChase');

  /// 今天已经被追了几轮（原生侧计数），用于提示语气
  static Future<int> chaseRound() async {
    final r = await _call<int>('chaseRound');
    return r ?? 0;
  }

  // v1.11.0 本地崩溃日志（零依赖，Bugly 接入后保留作离线兜底）
  static Future<void> writeCrashLog(String text) => _call('writeCrashLog', {'text': text});
  static Future<String> readCrashLog() async =>
      (await _call<String>('readCrashLog')) ?? '';
  static Future<void> clearCrashLog() => _call('clearCrashLog');

  // v1.15.0 数据搬家。
  //
  // 走系统的文件选择器（SAF）：它的列表里本来就有网盘和「下载」目录，
  // 所以「存到手机」和「存到云端」对用户是同一件事，App 不用接任何云服务，
  // 也不用向任何人证明自己拿到了存储权限。
  //
  // 返回 {ok:true, name}；用户取消是 {ok:false, reason:'cancel'}，
  // 不是异常——取消是正常操作，不该弹错误。
  static Future<Map<String, dynamic>> exportData(String json, String name) async {
    final r = await _call<Map>('exportData', {'json': json, 'name': name});
    return r == null
        ? <String, dynamic>{'ok': false, 'reason': 'unavailable'}
        : Map<String, dynamic>.from(r);
  }

  static Future<Map<String, dynamic>> importData() async {
    final r = await _call<Map>('importData');
    return r == null
        ? <String, dynamic>{'ok': false, 'reason': 'unavailable'}
        : Map<String, dynamic>.from(r);
  }

  /// 分享/发送到别的 App（微信、网盘、邮件…）：第二条「送到云端」的路
  static Future<Map<String, dynamic>> shareData(String json, String name) async {
    final r = await _call<Map>('shareData', {'json': json, 'name': name});
    return r == null
        ? <String, dynamic>{'ok': false, 'reason': 'unavailable'}
        : Map<String, dynamic>.from(r);
  }

  /// 应用私有目录里的一份文件（导入前的自动备份）
  static Future<bool> saveLocal(String name, String json) async =>
      (await _call<bool>('saveLocal', {'name': name, 'json': json})) ?? false;

  static Future<String?> readLocal(String name) =>
      _call<String>('readLocal', {'name': name});
}

// ============================================================================
// 4. 本地存储（离线优先：所有数据落本机，不联网也能完整走完闭环）
// ============================================================================

class Store {
  static List<Alarm> alarms = [];
  static List<MorningRecord> records = [];
  static Map<String, String> settings = {};

  static String get today {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  static Future<void> load() async {
    final a = await Bridge.getPref('alarms');
    // 「以前有没有数据」和「解析出了几条」是两件事。
    // 混为一谈的后果：一份暂时解析不了的备份会被当成「首次启动」，
    // 紧接着写入默认闹钟，把用户原来的列表覆盖掉——数据就这么没了。
    final hadAlarms = a != null && a.isNotEmpty;
    if (hadAlarms) {
      final list = <Alarm>[];
      try {
        final decoded = jsonDecode(a);
        if (decoded is List) {
          for (final e in decoded) {
            // 逐条容错：一条坏记录不该带走其余闹钟
            try {
              if (e is Map) list.add(Alarm.fromJson(Map<String, dynamic>.from(e)));
            } catch (_) {}
          }
        }
      } catch (_) {
        // 整体不可解析，保持空表但不覆盖
      }
      alarms = list;
    }
    if (alarms.isEmpty && !hadAlarms) {
      // 首次启动给一个默认闹钟，让用户马上能听到「真的响」
      alarms = [
        Alarm(id: 1, hour: 6, minute: 30, label: '晨间启动', days: [1, 2, 3, 4, 5]),
      ];
      await saveAlarms();
    }

    final r = await Bridge.getPref('records');
    if (r != null && r.isNotEmpty) {
      final list = <MorningRecord>[];
      try {
        final decoded = jsonDecode(r);
        if (decoded is List) {
          for (final e in decoded) {
            try {
              if (e is Map) {
                list.add(MorningRecord.fromJson(Map<String, dynamic>.from(e)));
              }
            } catch (_) {}
          }
        }
      } catch (_) {}
      records = list;
    }

    final s = await Bridge.getPref('settings');
    if (s != null && s.isNotEmpty) {
      try {
        settings = Map<String, String>.from(jsonDecode(s) as Map);
      } catch (_) {
        settings = {};
      }
    }
  }

  static Future<void> saveAlarms() async {
    await Bridge.setPref('alarms', jsonEncode(alarms.map((e) => e.toJson()).toList()));
    await Bridge.syncAlarms(jsonEncode(alarms.map((e) => e.toJson()).toList()));
  }

  static Future<void> saveRecords() async {
    await Bridge.setPref('records', jsonEncode(records.map((e) => e.toJson()).toList()));
  }

  static Future<void> saveSettings() async {
    await Bridge.setPref('settings', jsonEncode(settings));
  }

  static String s(String key, String fallback) => settings[key] ?? fallback;
  static bool b(String key, bool fallback) =>
      settings[key] == null ? fallback : settings[key] == '1';
  static int i(String key, int fallback) =>
      settings[key] == null ? fallback : (int.tryParse(settings[key]!) ?? fallback);

  static void set(String key, String value) {
    settings[key] = value;
    saveSettings();
  }

  static Alarm? nextAlarm() {
    final now = DateTime.now();
    Alarm? best;
    DateTime? bestAt;
    for (final a in alarms) {
      final t = a.nextTrigger(now);
      if (t == null) continue;
      if (bestAt == null || t.isBefore(bestAt)) {
        bestAt = t;
        best = a;
      }
    }
    return best;
  }

  static MorningRecord? todayRecord() {
    try {
      return records.firstWhere((r) => r.date == today);
    } catch (_) {
      return null;
    }
  }

  static MorningRecord upsertToday(int alarmId) {
    final r = todayRecord();
    if (r != null) return r;
    final rec = MorningRecord(
      date: today,
      alarmId: alarmId,
      wokeAt: DateTime.now().millisecondsSinceEpoch,
    );
    records.insert(0, rec);
    return rec;
  }

  static int get streak {
    var n = 0;
    for (var i = 0; i < 365; i++) {
      final d = DateTime.now().subtract(Duration(days: i));
      final key =
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      final hit = records.any((r) => r.date == key && r.completed);
      if (hit) {
        n++;
      } else if (i == 0) {
        continue; // 今天还没完成，不算断签
      } else {
        break;
      }
    }
    return n;
  }
}

// ============================================================================
// 5. 内置题库（V1 离线可用，题库更新在 V2 由内容侧下发）
// ============================================================================

class QuizQuestion {
  final String category;
  final String question;
  final List<String> options;
  final int answer;
  final String explain;

  const QuizQuestion(this.category, this.question, this.options, this.answer, this.explain);
}

const List<QuizQuestion> kQuestions = [
  QuizQuestion('常识', '一年中昼最长的一天通常出现在哪个节气前后？',
      ['春分', '夏至', '秋分', '冬至'], 1, '夏至日太阳直射北回归线，北半球白昼最长。'),
  QuizQuestion('科学', '人体在清晨醒来后，皮质醇水平通常如何变化？',
      ['迅速升高', '迅速下降', '保持不变', '先降后升'], 0, '醒来后 30 分钟皮质醇快速上升，帮助身体进入清醒状态。'),
  QuizQuestion('地理', '世界上面积最大的岛屿是？',
      ['马达加斯加岛', '格陵兰岛', '新几内亚岛', '加里曼丹岛'], 1, '格陵兰岛面积约 216 万平方公里，为世界最大岛屿。'),
  QuizQuestion('历史', '“一日之计在于晨”这句谚语强调的是？',
      ['早晨适合休息', '清晨时间最宝贵', '午后效率最高', '夜间记忆最好'], 1, '强调清晨是一天中最值得用来做事的时段。'),
  QuizQuestion('科学', '蓝光在早晨对生物钟的主要作用是？',
      ['延后入睡时间', '提前并稳定生物钟', '没有影响', '降低体温'], 1, '清晨接触明亮光线有助于同步昼夜节律，让人白天更清醒。'),
  QuizQuestion('常识', '成年人一般建议每晚睡眠时长为？',
      ['4–5 小时', '5–6 小时', '7–9 小时', '10–12 小时'], 2, '多数成年人 7–9 小时较为适宜，个体存在差异。'),
  QuizQuestion('科学', '咖啡因的半衰期大致为？',
      ['约 30 分钟', '约 1 小时', '约 5 小时', '约 24 小时'], 2, '多数人咖啡因半衰期约 3–7 小时，因此下午晚些时候饮用会影响入睡。'),
  QuizQuestion('地理', '中国陆地面积最大的省级行政区是？',
      ['西藏', '新疆', '内蒙古', '青海'], 1, '新疆维吾尔自治区面积约 166 万平方公里。'),
  QuizQuestion('常识', '“REM 睡眠”指的是？',
      ['深睡眠', '快速眼动睡眠', '浅睡眠', '入睡阶段'], 1, 'REM 为快速眼动睡眠，与做梦和记忆巩固相关。'),
  QuizQuestion('科学', '晨起后喝水的主要意义是？',
      ['补充夜间水分流失', '提高血糖', '增加胃酸', '降低体温'], 0, '睡眠中通过呼吸与排汗持续失水，晨起补水有助于恢复体液平衡。'),
  QuizQuestion('历史', '世界上最早的报纸雏形出现在？',
      ['古罗马', '古埃及', '古印度', '古希腊'], 0, '古罗马的《每日纪闻》常被认为是最早的官方公报之一。'),
  QuizQuestion('科学', '闹钟响后再睡 5 分钟，容易感到更困，主要原因是？',
      ['打断深睡眠周期', '血糖下降', '体温升高', '心率降低'], 0, '再次入睡往往进入更深的睡眠阶段，被强行唤醒后会出现睡眠惰性。'),
  QuizQuestion('常识', '下列哪种做法最有助于晨间清醒？',
      ['立刻看手机', '拉开窗帘接触自然光', '继续躺床', '喝浓茶代替早餐'], 1, '自然光是最强的生物钟同步信号。'),
  QuizQuestion('地理', '赤道穿过的大洲中，不包含？',
      ['非洲', '南美洲', '亚洲', '欧洲'], 3, '赤道穿过非洲、南美洲、亚洲与大洋洲，不穿过欧洲。'),
  QuizQuestion('科学', '人类大脑在睡眠期间会做的重要工作是？',
      ['停止所有活动', '清理代谢废物并巩固记忆', '持续高速思考', '降低体温至 30 度'], 1, '睡眠中类淋巴系统活跃，同时进行记忆整合。'),
];

List<QuizQuestion> pickQuestions(int n) {
  final list = [...kQuestions];
  list.shuffle();
  return list.take(n.clamp(1, list.length)).toList();
}

// ============================================================================
// 6. 内置新闻（V1 为演示数据，标注来源；V2 由新闻引擎拉取公开 RSS）
// ============================================================================

class NewsItem {
  final String title;
  final String summary;
  final String source;
  final String tag;

  /// 归属维度，与画像的十维对齐；播报时按它匹配用户偏好
  final String topic;

  const NewsItem(this.title, this.summary, this.source, this.tag, this.topic);
}

/// 注：V2 仍是内置示例内容，用于把「按画像挑新闻」的链路跑通。
/// 接真实源（公开 RSS）之后，只有这份数据会被替换，排序逻辑不用动。
const List<NewsItem> kNews = [
  NewsItem('全球科技行业进入年度复盘期，AI 基础设施投入继续走高',
      '多家机构在季度回顾中指出，算力与电力已成为新一轮基础设施建设的核心约束，数据中心选址正在向能源更充裕的地区迁移。',
      '示例来源 · 科技观察', '科技', '科技'),
  NewsItem('开源社区发布新一版移动端渲染框架，重点关注低端机功耗',
      '新版本将首次渲染耗时进一步压缩，并提供了针对中低端设备的功耗配置方案。',
      '示例来源 · 开发者日报', '技术', '科技'),
  NewsItem('研究显示：固定起床时间比固定入睡时间更能稳定睡眠质量',
      '一项覆盖数千人的追踪研究发现，起床时间规律的人群白天嗜睡评分显著更低，周末补觉带来的节律漂移需要更长时间恢复。',
      '示例来源 · 健康前沿', '健康', '健康'),
  NewsItem('多地疾控提示：换季阶段呼吸道疾病进入高发期',
      '门急诊量出现季节性上升，建议在人群密集场所做好防护，老人与儿童出现持续发热应尽早就诊。',
      '示例来源 · 公共卫生观察', '健康', '健康'),
  NewsItem('多家企业试点弹性上班时间，早晨时间安排更灵活',
      '试点数据显示，弹性到岗后员工迟到率下降，但团队协作时段需要重新约定重叠时间。',
      '示例来源 · 职场观察', '职场', '社会'),
  NewsItem('国内多个城市推进“15 分钟生活圈”改造，通勤结构出现变化',
      '社区商业与公共空间被重新组织，短距离步行与骑行的比例上升，早高峰的出行曲线明显变缓。',
      '示例来源 · 城市研究', '城市', '社会'),
  NewsItem('气象部门提示：本周昼夜温差加大，早晚出行注意保暖',
      '受冷空气影响，多地清晨气温明显下降，日出前后为全天最低点，晨练人群需注意热身与保暖。',
      '示例来源 · 天气服务', '生活', '生活'),
  NewsItem('消费市场进入年末旺季，线下零售客流环比回升',
      '多家商场延长营业时间，餐饮与家电换新成为主要增长点，冷链与配送环节的用工需求同步上升。',
      '示例来源 · 消费观察', '消费', '生活'),
  NewsItem('多家机构研判：明年一季度信贷投放节奏或小幅前移',
      '在稳增长政策延续的背景下，基建与制造业中长期贷款有望保持较高增速，居民端信贷需求恢复仍需时间。',
      '示例来源 · 财经观察', '宏观', '财经'),
  NewsItem('人民币汇率双向波动加大，出口企业加快套期保值',
      '企业结售汇行为趋于理性，越来越多的中小外贸企业开始使用远期与期权工具锁定利润。',
      '示例来源 · 市场观察', '汇率', '财经'),
  NewsItem('区域局势继续牵动能源市场，油价震荡走高',
      '航运保险费率上升，部分航线改道导致运输周期拉长，市场对供应中断的担忧尚未完全消退。',
      '示例来源 · 国际观察', '国际', '国际'),
  NewsItem('多国就关键矿产供应链举行磋商，强调多元化',
      '会议聚焦加工环节的产能分布与投资审查，各方在“安全”与“成本”之间的取舍仍存分歧。',
      '示例来源 · 国际观察', '国际', '国际'),
  NewsItem('一批战国竹简完成整理，释读出多处佚籍篇目',
      '研究团队通过红外成像与字形比对，确认了若干此前未见著录的文本，为思想史研究提供了新线索。',
      '示例来源 · 文博动态', '文化', '文化'),
  NewsItem('多地上线公共文化空间延时开放，夜间观展人次上升',
      '博物馆与图书馆试行错时服务，观众结构中年轻人比例明显提高，配套的讲解与导览需求同步增长。',
      '示例来源 · 文化观察', '文化', '文化'),
  NewsItem('联赛进入关键阶段，多支球队调整轮换策略',
      '密集赛程下伤病风险上升，教练组开始更多使用年轻球员，替补席的深度成为决定排名的变量。',
      '示例来源 · 体育资讯', '体育', '体育'),
  NewsItem('大众路跑赛事数量回升，完赛率与平均成绩同步变化',
      '赛事组织方加强了赛道补给与医疗保障，参赛者的备赛周期普遍拉长，科学训练的关注度明显提升。',
      '示例来源 · 体育资讯', '体育', '体育'),
  NewsItem('多地在建储能项目并网，峰谷调节能力增强',
      '新型储能与抽水蓄能同步推进，电力系统在午后光伏高峰与傍晚负荷高峰之间的调节余量有所改善。',
      '示例来源 · 能源观察', '环境', '环境'),
  NewsItem('空气质量预报能力提升，污染过程预警提前量增加',
      '模型同化了更多地面与卫星观测数据，重污染过程的开始与结束时间预报误差明显收窄。',
      '示例来源 · 环境监测', '环境', '环境'),
  NewsItem('国防科技领域多项成果公开，强调体系化能力建设',
      '相关报道聚焦探测、通信与保障环节的协同，专家指出单件装备的性能优势正在让位于体系效率。',
      '示例来源 · 国防观察', '军事', '军事'),
  NewsItem('多国海军开展联合演习，重点演练海上补给与搜救',
      '演习科目偏向非战争军事行动，参演方强调透明与通报机制，避免误判。',
      '示例来源 · 国防观察', '军事', '军事'),
];

/// 带预生成音频的新闻条数。超出这个下标的走系统 TTS 兜底。
const int kNewsWithSample = 20;

/// 预生成音频的键名：n01…n20，与 [kNews] 的声明顺序一一对应。
///
/// 用顺序而不是标题哈希：哈希在不同 Dart 版本之间不保证稳定，一旦变了就是
/// 整批音频对不上号——而且错得很安静，播出来还是人声，只是念的是别人那条。
String newsSampleKey(NewsItem n) {
  final i = kNews.indexOf(n);
  if (i < 0 || i >= kNewsWithSample) return '';
  return 'n${(i + 1).toString().padLeft(2, '0')}';
}

// 工具
String two(int v) => v.toString().padLeft(2, '0');

String hhmm(DateTime t) => '${two(t.hour)}:${two(t.minute)}';

String greeting(DateTime t) {
  final h = t.hour;
  if (h < 5) return '夜深了';
  if (h < 9) return '早安';
  if (h < 12) return '上午好';
  if (h < 14) return '午安';
  if (h < 18) return '下午好';
  return '晚上好';
}

bool fileExists(String p) => p.isNotEmpty && File(p).existsSync();
