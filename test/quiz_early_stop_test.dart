import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morning/core.dart';
import 'package:morning/quiz_pane.dart';

/// v1.12.2 回归：提前结束（「够了，先这样」）必须把本轮成绩交出去。
///
/// 修之前 onEarlyStop 是 VoidCallback，不携带 QuizTally：用户答了几道题、
/// 点「先停一下」之后，晨间完成页显示「答题 0 题」，答题页小结显示「这一轮 0」。
/// 这条用例盯住「早停时 tally 不为零」这个点。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('morning/native'), (call) async {
      switch (call.method) {
        case 'getPref':
          return null;
        case 'setPref':
        case 'syncAlarms':
        case 'speak':
        case 'stopSpeak':
        case 'setSpeechRate':
          return true;
        default:
          return null;
      }
    });
  });

  testWidgets('提前结束也会带走已答成绩', (tester) async {
    await Store.load();

    QuizTally? early;
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: QuizPane(
          count: 12,
          finishLabel: '进入新闻播报',
          onFinish: (_) {},
          // minBeforeStop=1：第一题就露出出口，测试不必模拟答题八次
          minBeforeStop: 1,
          earlyStopLabel: '够了，先去看新闻',
          onEarlyStop: (t) => early = t,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // 跳过一题：跳过也是「发生过」的成绩，tally.skipped 应当记上
    await tester.tap(find.text('这题不熟'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('够了，先去看新闻'));
    await tester.pumpAndSettle();

    expect(early, isNotNull, reason: '早停回调必须被触发');
    expect(early!.skipped, greaterThanOrEqualTo(1),
        reason: '早停时 tally 要带上已跳过的题，不能是 0');
  });
}
