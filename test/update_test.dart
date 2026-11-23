import 'package:flutter_test/flutter_test.dart';
import 'package:morning/core.dart';
import 'package:morning/pages_update.dart';
import 'package:morning/update.dart';

void main() {
  setUp(() {
    Store.settings = {};
  });

  group('版本比较', () {
    test('线上更高', () {
      expect(compareVersions('1.16.0', '1.15.0'), 1);
      expect(compareVersions('v1.16.0', '1.15.9'), 1);
    });

    test('同版本，忽略 v 前缀与构建号', () {
      expect(compareVersions('v1.16.0', '1.16.0'), 0);
      expect(compareVersions('1.16.0+30', '1.16.0+29'), 0);
      expect(compareVersions('1.16', '1.16.0'), 0);
    });

    test('按数字比，不是按字符串比', () {
      // 字符串比较会把 1.9 判成大于 1.10，这是最容易踩的坑
      expect(compareVersions('1.9.0', '1.10.0'), -1);
      expect(compareVersions('1.10.0', '1.9.0'), 1);
    });

    test('本机比线上还新（刚打完包还没发）', () {
      // 调用处是 compareVersions(线上, 本机)：线上更小 → -1 → 不提示更新
      expect(compareVersions('1.16.0', '1.17.0'), -1);
    });
  });

  group('解析 GitHub release', () {
    Map<String, dynamic> payload({String tag = 'v1.16.0', bool withApk = true}) => {
          'tag_name': tag,
          'body': '## 更新\n- 支持应用内检查更新\n',
          'html_url': 'https://github.com/xia259214-beep/morning-app/releases/tag/$tag',
          'published_at': '2026-11-23T10:00:00Z',
          'assets': [
            if (withApk)
              {
                'name': 'morning-v1.16.0.apk',
                'browser_download_url':
                    'https://github.com/xia259214-beep/morning-app/releases/download/$tag/morning.apk',
              },
            {'name': 'checksums.txt', 'browser_download_url': 'https://x/y.txt'},
          ],
        };

    test('tag 带 v 前缀也能取出版本号，优先拿 APK 直链', () {
      final i = UpdateInfo.fromJson(payload());
      expect(i.version, '1.16.0');
      expect(i.tag, 'v1.16.0');
      expect(i.apkUrl, endsWith('.apk'));
      expect(i.downloadUrl, endsWith('.apk'));
    });

    test('没挂 APK 时退回 release 页面，不返回空链接', () {
      final i = UpdateInfo.fromJson(payload(withApk: false));
      expect(i.apkUrl, isEmpty);
      expect(i.downloadUrl, contains('/releases/tag/'));
    });
  });

  test('「以后再说」三天内不再提示，过期后重新提示', () {
    // 直接写内存副本：Store.set 会走原生通道，单测环境没有那一边
    Store.settings['updateSkipped'] = '1.16.0';
    Store.settings['updateSkippedAt'] = '${DateTime.now().millisecondsSinceEpoch}';
    expect(UpdateChecker.isSkipped('1.16.0'), isTrue);
    // 别的版本不受影响
    expect(UpdateChecker.isSkipped('1.17.0'), isFalse);

    final old = DateTime.now()
        .subtract(const Duration(days: 4))
        .millisecondsSinceEpoch;
    Store.settings['updateSkippedAt'] = '$old';
    expect(UpdateChecker.isSkipped('1.16.0'), isFalse);
  });

  test('release 说明转纯文本：去井号、去星号、表格分隔行丢掉', () {
    final txt = plainReleaseNotes('## 新增\n- **应用内**检查更新\n\n|---|---|\n| a | b |');
    expect(txt, isNot(contains('#')));
    expect(txt, isNot(contains('**')));
    expect(txt, isNot(contains('---')));
    expect(txt, contains('· 应用内检查更新'));
  });
}
