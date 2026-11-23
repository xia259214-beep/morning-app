// ============================================================================
// 数据搬家（v1.15.0）
//
// 用户原话：「App 需要一个导入和导出的口子……本地的加到进去，下载下来数据还在。」
//
// 这里只做一件事：把四份本地存储（闹钟 / 打卡记录 / 设置+画像 / 流水）打包成
// 一个 JSON 文件，以及把它读回来。文件怎么传是系统的事——手机上的「文件」
// 选择器本身就带着网盘（百度网盘、OneDrive、Google Drive……），
// 所以「导出到本地」和「导出到云端」是同一个动作，不需要 App 自己接云。
//
// 三条硬规则：
//   1. **不经过任何服务器。** 这个 App 从 v1.0 起就没上传过东西，导入导出也不破例。
//   2. **导入前先自动备份现在的数据。** 用户手滑点「覆盖」不该是终点。
//   3. **坏文件不写盘。** 解析不出、版本不认识、类型不对，一律在写之前拒绝，
//      宁可报错也不留半份数据——半份数据比没有更难收拾。
// ============================================================================

import 'dart:convert';

import 'core.dart';
import 'journal.dart';
import 'power.dart';
import 'score.dart';

const String kBackupApp = 'morning';
const int kBackupSchema = 1;

/// 参与搬家的四份数据。顺序固定，写盘时按它来。
const List<String> kBackupKeys = ['alarms', 'records', 'settings', 'journal'];

/// 导入前的自动备份文件名（存在应用私有目录 backups/ 下，用户看不见但能恢复）
const String kAutoBackupName = 'pre_import.json';

/// 这些是「正在进行中」的状态，不该跟着备份走：
/// 把一台手机的 flowPending 搬到另一台，会让对方一启动就被拽进晨间流程。
const Set<String> kTransientKeys = {
  'flowPending',
  'flowPendingStep',
  'lastTrigger',
};

class BackupError implements Exception {
  final String message;
  BackupError(this.message);

  @override
  String toString() => message;
}

/// 一份解好的备份
class BackupBundle {
  final String version;
  final DateTime? exportedAt;

  /// 键 → 已解码的数据（alarms/records/journal 是 List，settings 是 Map）
  final Map<String, dynamic> data;

  BackupBundle({
    required this.version,
    required this.exportedAt,
    required this.data,
  });

  List<Map<String, dynamic>> get alarms => _maps(data['alarms']);
  List<Map<String, dynamic>> get records => _maps(data['records']);
  List<Map<String, dynamic>> get journal => _maps(data['journal']);
  Map<String, String> get settings => _strMap(data['settings']);
}

/// 备份里有什么，给界面报数用
class BackupFacts {
  final String version;
  final DateTime? exportedAt;
  final int alarms;
  final int records;
  final int journal;
  final int answered;
  final int score;

  const BackupFacts({
    required this.version,
    required this.exportedAt,
    required this.alarms,
    required this.records,
    required this.journal,
    required this.answered,
    required this.score,
  });
}

/// 导入干了什么。界面照实报，不写「导入成功」四个字了事。
class ImportReport {
  final bool replaced;
  final int alarmsAdded;
  final int recordsAdded;
  final int journalAdded;

  /// 画像 / 战力 / 分数是否整体切到了备份那一份
  final bool cumulativeFromBackup;

  /// 导入前的数据是否已自动备份（true = 可以点「撤销」）
  final bool autoBackupSaved;

  const ImportReport({
    required this.replaced,
    required this.alarmsAdded,
    required this.recordsAdded,
    required this.journalAdded,
    required this.cumulativeFromBackup,
    required this.autoBackupSaved,
  });
}

/// 合并结果：要写回的四份字符串 + 账单
class MergeResult {
  final Map<String, String> prefs;
  final ImportReport report;

  const MergeResult(this.prefs, this.report);
}

class Portable {
  // ---------------------------------------------------------------- 导出
  /// 打包当前数据。返回写进文件的 JSON 文本。
  static Future<String> exportJson() async {
    final data = <String, dynamic>{};
    for (final key in kBackupKeys) {
      final raw = await Bridge.getPref(key);
      if (raw == null || raw.isEmpty) continue;
      final decoded = _tryDecode(raw);
      // 解不开就原样带上：导入端认得字符串，总比丢掉强
      data[key] = decoded ?? raw;
    }
    var version = '';
    try {
      final info = await Bridge.deviceInfo();
      version = (info?['version'] as String?) ?? '';
    } catch (_) {
      version = '';
    }
    return const JsonEncoder.withIndent('  ').convert({
      'app': kBackupApp,
      'schema': kBackupSchema,
      'version': version,
      'exportedAt': DateTime.now().toIso8601String(),
      'prefs': data,
    });
  }

  /// 文件名的可读形式：晨序备份_2026-11-23_2140.json
  static String fileName([DateTime? at]) {
    final t = at ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '晨序备份_${t.year}-${two(t.month)}-${two(t.day)}_'
        '${two(t.hour)}${two(t.minute)}.json';
  }

  // ---------------------------------------------------------------- 解析
  /// 解析备份文件。任何一步不对都抛 [BackupError]，调用方直接展示 message。
  static BackupBundle parse(String raw) {
    if (raw.trim().isEmpty) {
      throw BackupError('文件是空的');
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      throw BackupError('这不是一个有效的备份文件（内容不是 JSON）');
    }
    if (decoded is! Map) {
      throw BackupError('备份文件格式不对：顶层应该是一个对象');
    }
    if (decoded['app'] != kBackupApp) {
      throw BackupError('这不是「晨序MORNING」导出的备份');
    }
    final schema = (decoded['schema'] as num?)?.toInt() ?? 1;
    if (schema > kBackupSchema) {
      throw BackupError('备份来自更新版本的晨序（格式 v$schema），请先升级本机 App 再导入');
    }
    final prefs = decoded['prefs'];
    if (prefs is! Map) {
      throw BackupError('备份文件里没有数据段（prefs）');
    }

    final data = <String, dynamic>{};
    for (final key in kBackupKeys) {
      final v = prefs[key];
      if (v == null) continue;
      // 兼容两种写法：原样字符串（自动备份）与已解码对象（手动导出）
      final value = v is String ? _tryDecode(v) : v;
      if (value == null) continue;
      if (key == 'settings') {
        if (value is Map) data[key] = _strMap(value);
      } else {
        if (value is List) data[key] = _maps(value);
      }
    }
    if (data.isEmpty) {
      throw BackupError('备份里没有能识别的数据（闹钟 / 记录 / 画像 / 流水都没有）');
    }

    DateTime? at;
    final rawAt = decoded['exportedAt'];
    if (rawAt is String) at = DateTime.tryParse(rawAt);

    return BackupBundle(
      version: (decoded['version'] ?? '') as String? ?? '',
      exportedAt: at,
      data: data,
    );
  }

  static BackupFacts factsOf(BackupBundle b) => BackupFacts(
        version: b.version,
        exportedAt: b.exportedAt,
        alarms: b.alarms.length,
        records: b.records.length,
        journal: b.journal.length,
        answered: _answeredCountOf(b.settings['profile']),
        score: _scoreOf(b.settings['score']),
      );

  // ---------------------------------------------------------------- 合并
  /// 把备份并进当前数据。纯函数，不碰平台通道——单测直接喂两个 map 就能验。
  static MergeResult mergeInto(Map<String, String> local, BackupBundle b) {
    final out = <String, String>{};

    final alarms = _mergeAlarms(local['alarms'], b.alarms);
    if (alarms != null) out['alarms'] = jsonEncode(alarms.$1);
    final records = _mergeRecords(local['records'], b.records);
    if (records != null) out['records'] = jsonEncode(records.$1);
    final journal = _mergeJournal(local['journal'], b.journal);
    if (journal != null) out['journal'] = jsonEncode(journal.$1);

    final settings = _mergeSettings(_decodeStrMap(local['settings']), b.settings);
    out['settings'] = jsonEncode(settings.$1);

    return MergeResult(
      out,
      ImportReport(
        replaced: false,
        alarmsAdded: alarms?.$2 ?? 0,
        recordsAdded: records?.$2 ?? 0,
        journalAdded: journal?.$2 ?? 0,
        cumulativeFromBackup: settings.$2,
        autoBackupSaved: true,
      ),
    );
  }

  /// 覆盖：整份换成备份的。备份里没有的块写空字符串（等于清空）。
  static Map<String, String> replaceWith(BackupBundle b) => {
        for (final key in kBackupKeys)
          key: b.data.containsKey(key) ? jsonEncode(b.data[key]) : '',
      };

  // ---------------------------------------------------------------- 应用
  /// 真正写盘。先自动备份当前数据，再写。
  static Future<ImportReport> apply(
    BackupBundle b, {
    required bool replace,
  }) async {
    // 1. 当前数据先落到私有目录，出问题能撤回来
    final before = <String, String>{};
    for (final key in kBackupKeys) {
      before[key] = (await Bridge.getPref(key)) ?? '';
    }
    var autoSaved = false;
    try {
      autoSaved = await Bridge.saveLocal(kAutoBackupName, _envelope(before));
    } catch (_) {
      autoSaved = false;
    }

    // 2. 算出要写的四份
    ImportReport? merged;
    final out = replace
        ? replaceWith(b)
        : () {
            final r = mergeInto(before, b);
            merged = r.report;
            return r.prefs;
          }();

    // 3. 落盘 → 重载 → 重新登记闹钟
    for (final key in kBackupKeys) {
      final v = out[key];
      if (v == null) continue;
      await Bridge.setPref(key, v);
    }

    // Store.load() 对「空字符串」是跳过不覆盖的（防止坏数据把老数据冲掉），
    // 所以先把内存清干净再读，否则覆盖导入会读到旧列表、再写回去。
    Store.alarms = [];
    Store.records = [];
    Store.settings = {};
    await Store.load();
    await Store.saveAlarms(); // 只改 prefs 不重排，系统里的闹钟还是旧的
    await Store.saveRecords();
    await Journal.load();
    ScoreBook.invalidate();
    PowerChart.invalidate();

    final base = merged;
    return ImportReport(
      replaced: replace,
      alarmsAdded: base?.alarmsAdded ?? b.alarms.length,
      recordsAdded: base?.recordsAdded ?? b.records.length,
      journalAdded: base?.journalAdded ?? b.journal.length,
      cumulativeFromBackup: base?.cumulativeFromBackup ?? replace,
      autoBackupSaved: autoSaved,
    );
  }

  /// 恢复「导入前」的自动备份。没有就返回 null。
  static Future<BackupBundle?> readAutoBackup() async {
    String? raw;
    try {
      raw = await Bridge.readLocal(kAutoBackupName);
    } catch (_) {
      raw = null;
    }
    if (raw == null || raw.trim().isEmpty) return null;
    return parse(raw);
  }

  // ================================================================ 内部
  static String _envelope(Map<String, String> raw) => jsonEncode({
        'app': kBackupApp,
        'schema': kBackupSchema,
        'version': 'auto',
        'exportedAt': DateTime.now().toIso8601String(),
        'prefs': raw,
      });

  static dynamic _tryDecode(String s) {
    try {
      return jsonDecode(s);
    } catch (_) {
      return null;
    }
  }

  static Map<String, String> _decodeStrMap(String? raw) {
    if (raw == null || raw.isEmpty) return <String, String>{};
    return _strMap(_tryDecode(raw));
  }

  static int _int(dynamic v) => (v is num) ? v.toInt() : int.tryParse('$v') ?? 0;

  static List<int> _days(dynamic v) {
    if (v is List) return [for (final e in v) if (e is num) e.toInt()];
    return const [];
  }

  /// 闹钟的「同一只」判据：几点几分 + 哪几天。id 只是本地序号，跨手机不可信。
  static String _alarmKey(Map<String, dynamic> a) {
    final days = _days(a['days'])..sort();
    return '${_int(a['hour'])}:${_int(a['minute'])}/${days.join(',')}';
  }

  /// 返回 (列表, 新增条数)；本地那份解析不了时返回 null（不覆盖）
  static (List<Map<String, dynamic>>, int)? _mergeAlarms(
    String? localRaw,
    List<Map<String, dynamic>> backup,
  ) {
    final hadLocal = localRaw != null && localRaw.isNotEmpty;
    final decoded = hadLocal ? _tryDecode(localRaw) : null;
    if (hadLocal && decoded is! List) return null;

    final out = <Map<String, dynamic>>[..._maps(decoded)];
    final seen = <String>{for (final a in out) _alarmKey(a)};
    var maxId = 0;
    for (final a in out) {
      final id = _int(a['id']);
      if (id > maxId) maxId = id;
    }
    var added = 0;
    for (final a in backup) {
      final key = _alarmKey(a);
      if (seen.contains(key)) continue;
      final copy = Map<String, dynamic>.from(a);
      // 同一个 id 已被占用就换一个，别让两只闹钟共用一个 PendingIntent
      if (out.any((e) => _int(e['id']) == _int(copy['id']))) {
        copy['id'] = ++maxId;
      } else {
        final id = _int(copy['id']);
        if (id > maxId) maxId = id;
      }
      out.add(copy);
      seen.add(key);
      added++;
    }
    return (out, added);
  }

  /// 打卡记录按日期合并：同一天两边都有时取信息更全的一份
  static (List<Map<String, dynamic>>, int)? _mergeRecords(
    String? localRaw,
    List<Map<String, dynamic>> backup,
  ) {
    final hadLocal = localRaw != null && localRaw.isNotEmpty;
    final decoded = hadLocal ? _tryDecode(localRaw) : null;
    if (hadLocal && decoded is! List) return null;

    final out = <Map<String, dynamic>>[..._maps(decoded)];
    final index = <String, int>{
      for (var i = 0; i < out.length; i++) '${out[i]['date']}': i,
    };
    var added = 0;
    for (final r in backup) {
      final date = '${r['date']}';
      if (date.isEmpty || date == 'null') continue;
      final i = index[date];
      if (i == null) {
        final copy = Map<String, dynamic>.from(r);
        // 照片文件不在备份里，跨手机的路径必然指空；留着只会让界面去打开一个
        // 不存在的文件，然后显示一张裂图。
        if (!fileExists('${copy['photo'] ?? ''}')) copy['photo'] = '';
        out.add(copy);
        index[date] = out.length - 1;
        added++;
        continue;
      }
      final cur = out[i];
      final merged = Map<String, dynamic>.from(cur);
      if (r['completed'] == true) merged['completed'] = true;
      if (r['newsDone'] == true) merged['newsDone'] = true;
      merged['quizCorrect'] = _maxInt(cur['quizCorrect'], r['quizCorrect']);
      merged['quizTotal'] = _maxInt(cur['quizTotal'], r['quizTotal']);
      // 照片路径跨手机是无效的（文件没跟着来），只认本机真实存在的那张
      final localPhoto = '${cur['photo'] ?? ''}';
      final backupPhoto = '${r['photo'] ?? ''}';
      merged['photo'] =
          fileExists(localPhoto) ? localPhoto : (fileExists(backupPhoto) ? backupPhoto : '');
      if (_int(cur['wokeAt']) == 0 && _int(r['wokeAt']) != 0) {
        merged['wokeAt'] = r['wokeAt'];
      }
      out[i] = merged;
    }
    out.sort((a, b) => '${b['date']}'.compareTo('${a['date']}'));
    return (out, added);
  }

  /// 流水按「时间 + 类型 + 标题」去重，合并后按时间倒序，并守住上限
  static (List<Map<String, dynamic>>, int)? _mergeJournal(
    String? localRaw,
    List<Map<String, dynamic>> backup,
  ) {
    final hadLocal = localRaw != null && localRaw.isNotEmpty;
    final decoded = hadLocal ? _tryDecode(localRaw) : null;
    if (hadLocal && decoded is! List) return null;

    final out = <Map<String, dynamic>>[..._maps(decoded)];
    final seen = <String>{
      for (final e in out) '${e['ts']}|${e['kind']}|${e['title']}',
    };
    var added = 0;
    for (final e in backup) {
      final key = '${e['ts']}|${e['kind']}|${e['title']}';
      if (seen.contains(key)) continue;
      out.add(Map<String, dynamic>.from(e));
      seen.add(key);
      added++;
    }
    out.sort((a, b) => _int(b['ts']).compareTo(_int(a['ts'])));
    final capped =
        out.length > Journal.maxEvents ? out.sublist(0, Journal.maxEvents) : out;
    return (capped, added);
  }

  /// 设置合并。
  ///
  /// 画像 / 战力 / 分数是**连着答出来的三本账**，两台手机各答一半再相加，
  /// 会出现「答过 800 道但战力只有 50」这种自相矛盾的状态——
  /// 所以这里整份取「答得更多」的那一边，不做加法。
  static (Map<String, String>, bool) _mergeSettings(
    Map<String, String> local,
    Map<String, String> backup,
  ) {
    final out = <String, String>{...local};
    final takeBackup = _answeredCountOf(backup['profile']) >
        _answeredCountOf(local['profile']);

    for (final e in backup.entries) {
      if (e.key == 'profile' || e.key == 'power' || e.key == 'score') continue;
      if (kTransientKeys.contains(e.key)) continue;
      final cur = out[e.key];
      if (cur == null || cur.isEmpty) out[e.key] = e.value;
    }
    if (takeBackup) {
      for (final key in ['profile', 'power', 'score']) {
        final v = backup[key];
        if (v != null && v.isNotEmpty) out[key] = v;
      }
    }
    return (out, takeBackup);
  }

  static int _maxInt(dynamic a, dynamic b) {
    final x = _int(a);
    final y = _int(b);
    return x > y ? x : y;
  }

  static int _answeredCountOf(String? profileRaw) {
    if (profileRaw == null || profileRaw.isEmpty) return 0;
    final d = _tryDecode(profileRaw);
    if (d is Map) {
      final answered = d['answered'];
      if (answered is List) return answered.length;
    }
    return 0;
  }

  static int _scoreOf(String? scoreRaw) {
    if (scoreRaw == null || scoreRaw.isEmpty) return 0;
    final d = _tryDecode(scoreRaw);
    if (d is Map) return _int(d['right']) - _int(d['wrong']);
    return 0;
  }
}

// ============================================================================
// 文件级的小工具
//
// 放在类外，是因为 [BackupBundle] 的 getter 也要用——它比 [Portable] 早声明，
// 两个类各留一份同样逻辑只会让「哪份才是准的」变成一个问题。
// ============================================================================

List<Map<String, dynamic>> _maps(dynamic v) {
  final out = <Map<String, dynamic>>[];
  if (v is List) {
    for (final e in v) {
      if (e is Map) out.add(Map<String, dynamic>.from(e));
    }
  }
  return out;
}

Map<String, String> _strMap(dynamic v) {
  final out = <String, String>{};
  if (v is Map) {
    v.forEach((k, val) {
      if (val == null) return;
      out['$k'] = val is String ? val : jsonEncode(val);
    });
  }
  return out;
}
