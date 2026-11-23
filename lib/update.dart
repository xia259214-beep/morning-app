import 'dart:convert';
import 'dart:io';

import 'core.dart';

/// 版本号比较：`1.16.0` / `v1.16.0` / `1.16.0+30` / `1.16.0-beta` 都能吃。
///
/// 逐段按数字比，缺的段当 0（`1.16` == `1.16.0`）。
/// 返回 -1 / 0 / 1，语义同 `compareTo`。
int compareVersions(String a, String b) {
  List<int> parse(String raw) {
    var s = raw.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    // 构建号（+30）与预发布后缀（-beta）不参与比较：
    // GitHub 的 tag 是 1.16.0，本机 versionName 也可能是 1.16.0，
    // 但 versionCode 每次发版都变，比进去会让同版本误判成「有新版」。
    final cut = s.indexOf('+');
    if (cut >= 0) s = s.substring(0, cut);
    final dash = s.indexOf('-');
    if (dash >= 0) s = s.substring(0, dash);
    return s.split('.').map((e) => int.tryParse(e.trim()) ?? 0).toList();
  }

  final x = parse(a);
  final y = parse(b);
  final n = x.length > y.length ? x.length : y.length;
  for (var i = 0; i < n; i++) {
    final l = i < x.length ? x[i] : 0;
    final r = i < y.length ? y[i] : 0;
    if (l != r) return l < r ? -1 : 1;
  }
  return 0;
}

/// 一次「检查更新」的结论。
enum UpdateStatus {
  /// 服务端有更新的版本
  hasUpdate,

  /// 已经是最新（或比线上还新，比如刚打完包还没发）
  upToDate,

  /// 查不到：断网、GitHub 被墙、接口限流
  failed,
}

class UpdateInfo {
  /// 纯版本号，如 `1.16.0`
  final String version;

  /// 原始 tag，如 `v1.16.0`
  final String tag;

  /// release 说明（Markdown 原文，展示前由 UI 简化）
  final String notes;

  /// APK 直链；线上没挂 APK 时为空，退化成 [pageUrl]
  final String apkUrl;

  /// release 页面
  final String pageUrl;

  /// 发布时间（ISO8601），拿不到就是空串
  final String publishedAt;

  const UpdateInfo({
    required this.version,
    required this.tag,
    required this.notes,
    required this.apkUrl,
    required this.pageUrl,
    required this.publishedAt,
  });

  /// 下载优先走直链，直链没有就退回页面（用户自己点资产）
  String get downloadUrl => apkUrl.isNotEmpty ? apkUrl : pageUrl;

  factory UpdateInfo.fromJson(Map<String, dynamic> m) {
    final tag = (m['tag_name'] as String?)?.trim() ?? '';
    var version = tag;
    if (version.startsWith('v') || version.startsWith('V')) {
      version = version.substring(1);
    }
    final plus = version.indexOf('+');
    if (plus >= 0) version = version.substring(0, plus);

    var apk = '';
    final assets = m['assets'];
    if (assets is List) {
      for (final a in assets) {
        if (a is! Map) continue;
        final name = (a['name'] as String?) ?? '';
        final url = (a['browser_download_url'] as String?) ?? '';
        if (url.isEmpty) continue;
        if (name.toLowerCase().endsWith('.apk')) {
          apk = url;
          break;
        }
      }
    }

    return UpdateInfo(
      version: version,
      tag: tag,
      notes: (m['body'] as String?)?.trim() ?? '',
      apkUrl: apk,
      pageUrl: (m['html_url'] as String?) ?? '',
      publishedAt: (m['published_at'] as String?) ?? '',
    );
  }
}

class UpdateResult {
  final UpdateStatus status;
  final UpdateInfo? info;

  /// 本机当前版本，用于「已是最新 v1.15.0」这种回话
  final String current;

  const UpdateResult(this.status, this.current, [this.info]);
}

/// 更新检测：直接问 GitHub 的 latest release。
///
/// 为什么不用第三方更新 SDK：这个 App 到现在零第三方依赖，
/// 为了一个「有没有新版」的判断题装一整个 SDK 不划算；
/// `dart:io` 的 HttpClient 够用，也方便单测。
///
/// 查询失败一律静默（[UpdateStatus.failed]），绝不弹错误——
/// 早上七点被人叫起来的时候，没人想看「网络异常」。
class UpdateChecker {
  static const String repo = 'xia259214-beep/morning-app';
  static const String apiUrl =
      'https://api.github.com/repos/$repo/releases/latest';
  static const String releasesPage =
      'https://github.com/$repo/releases/latest';

  /// 启动检查的节流间隔：半天。开屏就查太频繁，纯属浪费流量。
  static const Duration throttle = Duration(hours: 12);

  /// 失败后一小时内的重试冷却，避免每次开屏都卡一次超时
  static const Duration failCooldown = Duration(hours: 1);

  /// 点过「以后再说」的版本，三天内不再打扰
  static const Duration skipFor = Duration(days: 3);

  static const String _kCheckedAt = 'updateCheckedAt';
  static const String _kFailedAt = 'updateFailedAt';
  static const String _kSkipped = 'updateSkipped';
  static const String _kSkippedAt = 'updateSkippedAt';

  static String? _currentCache;

  /// 本机版本：以原生 versionName 为准，读不到才退回编译期常量。
  /// （compileSdk 升级、pubspec 改了忘同步时，常量会撒谎）
  static Future<String> currentVersion() async {
    final cached = _currentCache;
    if (cached != null && cached.isNotEmpty) return cached;
    try {
      final d = await Bridge.deviceInfo();
      final v = (d?['version'] as String?)?.trim() ?? '';
      if (v.isNotEmpty) {
        _currentCache = v;
        return v;
      }
    } catch (_) {
      // 桥不可用（比如单测环境），用常量兜底
    }
    _currentCache = kAppVersion;
    return kAppVersion;
  }

  /// 拉最新 release。任何异常都吞掉返回 null。
  static Future<UpdateInfo?> fetchLatest({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = timeout;
      final req = await client.getUrl(Uri.parse(apiUrl)).timeout(timeout);
      // GitHub API 强制要 UA，不带直接 403
      req.headers.set('User-Agent', 'MorningApp-Updater');
      req.headers.set('Accept', 'application/vnd.github+json');
      final res = await req.close().timeout(timeout);
      if (res.statusCode != 200) return null;
      final body = await res.transform(utf8.decoder).join().timeout(timeout);
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      final info = UpdateInfo.fromJson(Map<String, dynamic>.from(decoded));
      return info.version.isEmpty ? null : info;
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
    }
  }

  /// 启动时用：受节流 + 「以后再说」约束，无更新或失败都返回对应状态给调用方自己判断。
  static Future<UpdateResult> checkOnLaunch() async {
    final current = await currentVersion();
    final now = DateTime.now().millisecondsSinceEpoch;

    final checkedAt = int.tryParse(Store.s(_kCheckedAt, '')) ?? 0;
    if (checkedAt > 0 && now - checkedAt < throttle.inMilliseconds) {
      // 静默：这半天内已经问过了
      return UpdateResult(UpdateStatus.upToDate, current);
    }
    final failedAt = int.tryParse(Store.s(_kFailedAt, '')) ?? 0;
    if (failedAt > 0 && now - failedAt < failCooldown.inMilliseconds) {
      return UpdateResult(UpdateStatus.failed, current);
    }

    final info = await fetchLatest();
    if (info == null) {
      Store.set(_kFailedAt, '$now');
      return UpdateResult(UpdateStatus.failed, current);
    }
    Store.set(_kCheckedAt, '$now');
    Store.set(_kFailedAt, '');

    if (compareVersions(info.version, current) <= 0) {
      return UpdateResult(UpdateStatus.upToDate, current, info);
    }
    if (isSkipped(info.version)) {
      return UpdateResult(UpdateStatus.upToDate, current, info);
    }
    return UpdateResult(UpdateStatus.hasUpdate, current, info);
  }

  /// 用户主动点「检查更新」：无视节流，失败要说清楚
  static Future<UpdateResult> checkNow() async {
    final current = await currentVersion();
    final info = await fetchLatest();
    if (info == null) return UpdateResult(UpdateStatus.failed, current);
    Store.set(_kCheckedAt, '${DateTime.now().millisecondsSinceEpoch}');
    if (compareVersions(info.version, current) <= 0) {
      return UpdateResult(UpdateStatus.upToDate, current, info);
    }
    return UpdateResult(UpdateStatus.hasUpdate, current, info);
  }

  /// 「以后再说」：这个版本三天内不再弹
  static void skipVersion(String version) {
    Store.set(_kSkipped, version);
    Store.set(_kSkippedAt, '${DateTime.now().millisecondsSinceEpoch}');
  }

  static bool isSkipped(String version) {
    if (Store.s(_kSkipped, '') != version) return false;
    final at = int.tryParse(Store.s(_kSkippedAt, '')) ?? 0;
    if (at <= 0) return false;
    final age = DateTime.now().millisecondsSinceEpoch - at;
    return age < skipFor.inMilliseconds;
  }
}
