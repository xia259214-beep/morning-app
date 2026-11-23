// 本机档案（v1.17.0）的单元测试。
//
// 重点不是「能不能存」，而是**坏数据不能把页面搞崩**：头像是一段从
// 备份 JSON 里读出来的字符串，它可能被人手改过、被截断、或者根本是别的字段。
// 这些情况都只该让头像退回默认图标，不该让「我的」页白屏。

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:morning/avatar.dart';
import 'package:morning/core.dart';

/// 造一段「像 JPEG」的字节：FFD8 开头
Uint8List fakeJpeg(int length) {
  final b = Uint8List(length);
  b[0] = 0xFF;
  b[1] = 0xD8;
  for (var i = 2; i < length; i++) {
    b[i] = i % 251;
  }
  return b;
}

void main() {
  // 存头像会走到 Store.saveSettings → MethodChannel；没有 binding 时
  // 连 channel 都拿不到，会直接抛「Binding has not yet been initialized」
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    Store.settings = {};
    Avatar.invalidate();
  });

  group('Avatar.decode', () {
    test('空字符串不算头像', () {
      expect(Avatar.decode(''), isNull);
    });

    test('不是 base64 的字符串不炸，只是没有头像', () {
      expect(Avatar.decode('这不是base64!!'), isNull);
    });

    test('base64 合法但不是 JPEG：拒绝', () {
      final notJpeg = base64Encode(utf8.encode('x' * 200));
      expect(Avatar.decode(notJpeg), isNull);
    });

    test('太短的字节流不算（多半是截断的数据）', () {
      final tiny = base64Encode(fakeJpeg(20));
      expect(Avatar.decode(tiny), isNull);
    });

    test('超过 400 KB 的拒绝，避免备份里塞进一张巨图', () {
      final huge = base64Encode(fakeJpeg(Avatar.maxBytes + 1));
      expect(Avatar.decode(huge), isNull);
    });

    test('正常 JPEG 能解出字节', () {
      final bytes = fakeJpeg(4096);
      final got = Avatar.decode(base64Encode(bytes));
      expect(got, isNotNull);
      expect(got!.length, 4096);
      expect(got[0], 0xFF);
      expect(got[1], 0xD8);
    });
  });

  group('Avatar 存储', () {
    test('存进去之后 has/bytes 都成立', () async {
      final b64 = base64Encode(fakeJpeg(2048));
      expect(await Avatar.save(b64), isTrue);
      expect(Avatar.has, isTrue);
      expect(Avatar.bytes, isNotNull);
      expect(Store.s(Avatar.key, ''), b64);
    });

    test('坏数据不写进 settings，save 返回 false', () async {
      expect(await Avatar.save('乱码'), isFalse);
      expect(Store.settings.containsKey(Avatar.key), isFalse);
      expect(Avatar.has, isFalse);
    });

    test('恢复默认会把键删掉', () async {
      await Avatar.save(base64Encode(fakeJpeg(1024)));
      expect(Avatar.has, isTrue);
      await Avatar.clear();
      expect(Avatar.has, isFalse);
      expect(Store.settings.containsKey(Avatar.key), isFalse);
      expect(Avatar.bytes, isNull);
    });

    test('invalidate 之后重新从 settings 读（导入备份的场景）', () async {
      await Avatar.save(base64Encode(fakeJpeg(1024)));
      expect(Avatar.bytes, isNotNull);
      // 模拟「覆盖导入」把 settings 整个换掉
      Store.settings = {};
      Avatar.invalidate();
      expect(Avatar.bytes, isNull);
    });
  });

  group('Nick', () {
    test('没设过就是「晨友」', () {
      expect(Nick.current, Nick.fallback);
      expect(Nick.custom, isFalse);
    });

    test('去首尾空白、连续空白压成一个空格', () {
      expect(Nick.normalize('  老  张 '), '老 张');
      expect(Nick.normalize('阿明\n'), '阿明');
    });

    test('删光了退回默认名，不留没名字的档案', () {
      expect(Nick.normalize('   '), Nick.fallback);
      expect(Nick.normalize(''), Nick.fallback);
    });

    test('超过 12 个字截断', () {
      const long = '一二三四五六七八九十十一十二十三';
      expect(Nick.normalize(long).runes.length, Nick.maxLen);
    });

    test('存下来之后 current 跟着变', () async {
      await Nick.save('老张');
      expect(Nick.current, '老张');
      expect(Nick.custom, isTrue);
    });
  });
}
