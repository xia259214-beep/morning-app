// ============================================================================
// 本机档案（v1.17.0）
//
// 用户原话：「更新一个 APP 的头像还有登录界面」「我点进去想换个头像换不了」
// 「账号你是怎么做的，是手机号码、邮箱，还是一键登录、游客登录？」
//
// 结论先说清楚：**这个 App 不做账号**。没有注册、没有登录、没有服务器。
// 「我的」页那一栏就是本机的一个称呼，改动它不需要密码，也不需要联网。
// 为什么坚持不做：
//   1. 数据全在本机是这个 App 的立身之本，账号就意味着要有一台服务器存它；
//   2. 有了账号就要有手机号/验证码/隐私政策/实名，漏一个就是合规风险；
//   3. 闹钟和播报本来就跑在本机，账号只对「多设备同步」有意义，
//      而那个需求用「数据备份 → 导出 JSON → 新机导入」已经解决了。
//
// 所以这里只有两样东西：一张头像、一个昵称。
// 头像不存文件，存的是 256×256 JPEG 的 base64（原生侧裁好再给），
// 于是它跟着 settings 一起进备份，换手机时头像也不会丢。
// ============================================================================

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/painting.dart';

import 'core.dart';

class Avatar {
  /// settings 里的键
  static const String key = 'avatar';

  /// 原生侧裁出来的边长，和 MainActivity.AVATAR_PX 必须一致
  static const int px = 256;

  /// 上限兜底：256px JPEG 正常十几到三十几 KB，
  /// 真超过 400 KB 说明拿到的不是这里生成的东西，宁可不显示
  static const int maxBytes = 400 * 1024;

  /// 下限：比 64 字节还小的不可能是能看的图，多半是坏数据
  static const int minBytes = 64;

  static Uint8List? _cache;
  static bool _loaded = false;

  static String get raw => Store.s(key, '');

  static bool get has => raw.isNotEmpty;

  /// 头像字节；没有、或坏数据都返回 null，界面退回默认图标。
  static Uint8List? get bytes {
    if (!_loaded) {
      _loaded = true;
      _cache = decode(raw);
    }
    return _cache;
  }

  /// 给 CircleAvatar 用的图；null 时调用方画默认图标
  static MemoryImage? get image {
    final b = bytes;
    return b == null ? null : MemoryImage(b);
  }

  /// 校验 + 解码。**不信任任何外部字符串**：坏数据只让头像变回默认图标，
  /// 绝不能让「我的」页整页白屏。
  static Uint8List? decode(String b64) {
    if (b64.isEmpty) return null;
    try {
      final b = base64Decode(b64);
      if (b.length < minBytes || b.length > maxBytes) return null;
      // JPEG 的魔数。不是 JPEG 就说明这条数据来路不明，不当头像用
      if (b[0] != 0xFF || b[1] != 0xD8) return null;
      return b;
    } catch (_) {
      // base64 本身不合法
      return null;
    }
  }

  /// 存一张新头像。返回 false 表示数据不可用，界面应提示而不是静默吞掉
  static Future<bool> save(String b64) async {
    final b = decode(b64);
    if (b == null) return false;
    Store.set(key, b64);
    _cache = b;
    _loaded = true;
    await Store.saveSettings();
    return true;
  }

  /// 恢复默认图标
  static Future<void> clear() async {
    Store.settings.remove(key);
    _cache = null;
    _loaded = true;
    await Store.saveSettings();
  }

  /// 备份导入 / 覆盖之后要调一次，否则界面还在用旧的那张
  static void invalidate() {
    _loaded = false;
    _cache = null;
  }

  /// 给测试和调试用：把一段字节按同样的规则编码回去
  static String encode(Uint8List bytes) => base64Encode(bytes);
}

/// 昵称。默认「晨友」，可以改，但留不下空白。
class Nick {
  static const String key = 'nick';
  static const String fallback = '晨友';

  /// 12 个字：再长「我的」页那行会被挤，而且本来就是个称呼
  static const int maxLen = 12;

  static String get current {
    final s = Store.s(key, '').trim();
    return s.isEmpty ? fallback : s;
  }

  /// 是不是用户自己起的名（false = 还在用默认「晨友」）
  static bool get custom => Store.s(key, '').trim().isNotEmpty;

  /// 收敛成能存的样子：去首尾空白、把连续空白压成一个空格、按字数截断。
  /// 空字符串会退回默认名——用户把名字删光然后又保存，不该得到一个没有名字的档案。
  static String normalize(String raw) {
    var s = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (s.isEmpty) return fallback;
    final runes = s.runes.toList();
    if (runes.length > maxLen) {
      s = String.fromCharCodes(runes.take(maxLen));
    }
    return s;
  }

  static Future<void> save(String raw) async {
    Store.set(key, normalize(raw));
    await Store.saveSettings();
  }
}
