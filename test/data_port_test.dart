import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morning/core.dart';
import 'package:morning/pages_portable.dart';

/// 备份页的接线测试：点按钮 → 走原生通道 → 界面把结果说出来。
/// 这里不验真文件，只验「该调的调了、不该写的没写、话说明白了」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <String>[];

  void mockNative({String? importJson}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('morning/native'), (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'getPref':
          return null;
        case 'setPref':
        case 'syncAlarms':
          return true;
        case 'deviceInfo':
          return {
            'brand': 'Xiaomi',
            'model': 'TestPhone',
            'sdk': '34',
            'version': '1.15.0',
          };
        case 'exportData':
          return {'ok': true, 'name': '晨序备份_2026-11-23_2140.json'};
        case 'importData':
          return importJson == null
              ? {'ok': false, 'reason': 'cancel'}
              : {'ok': true, 'json': importJson, 'name': 'backup.json'};
        case 'readLocal':
          return null;
        default:
          return null;
      }
    });
  }

  setUp(() {
    calls.clear();
    Store.settings = {};
    Store.alarms = [];
    Store.records = [];
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: DataPortPage()));
    await tester.pumpAndSettle();
  }

  testWidgets('列出本机数据，导出走原生并回报文件名', (tester) async {
    mockNative();
    await pumpPage(tester);

    expect(find.text('数据备份与迁移'), findsOneWidget);
    expect(find.text('导出到文件'), findsOneWidget);
    expect(find.text('发送到…'), findsOneWidget);
    expect(find.text('从文件导入'), findsOneWidget);

    await tester.tap(find.text('导出到文件'));
    await tester.pumpAndSettle();

    expect(calls, contains('exportData'));
    expect(find.textContaining('已导出'), findsOneWidget);
  });

  testWidgets('选中别的 App 的 JSON，当场拒绝，一个字节都不写', (tester) async {
    mockNative(importJson: '{"app":"other","prefs":{"alarms":[]}}');
    await pumpPage(tester);

    await tester.tap(find.text('从文件导入'));
    await tester.pumpAndSettle();

    expect(find.textContaining('用不了'), findsOneWidget);
    expect(calls, isNot(contains('saveLocal')),
        reason: '解析没过就不该碰写盘，更不能覆盖用户现有数据');
  });

  testWidgets('用户取消选文件时只说「已取消」，不当错误', (tester) async {
    mockNative();
    await pumpPage(tester);

    await tester.tap(find.text('从文件导入'));
    await tester.pumpAndSettle();

    expect(find.text('已取消'), findsOneWidget);
  });
}
