import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:morning/portable.dart';

/// 备份的解析与合并。这一块出错代价最高——用户的闹钟、打卡和流水全在里面，
/// 所以每条规则都单独钉一个用例。
void main() {
  String envelope(
    Map<String, dynamic> prefs, {
    String app = 'morning',
    int schema = 1,
    String version = '1.15.0',
    String exportedAt = '2026-11-23T21:40:00.000',
  }) =>
      jsonEncode({
        'app': app,
        'schema': schema,
        'version': version,
        'exportedAt': exportedAt,
        'prefs': prefs,
      });

  group('解析', () {
    test('认得出自己的备份，并数清里面有什么', () {
      final b = Portable.parse(envelope({
        'alarms': [
          {'id': 1, 'hour': 6, 'minute': 30, 'days': [1, 2, 3]},
        ],
        'records': [
          {'date': '2026-11-22', 'completed': true},
        ],
        'journal': [
          {'ts': 1000, 'kind': 'quiz', 'title': '答了一道'},
        ],
        'settings': {
          'profile': jsonEncode({'answered': ['a', 'b']}),
          'score': jsonEncode({'right': 5, 'wrong': 2}),
        },
      }));
      final f = Portable.factsOf(b);
      expect(f.alarms, 1);
      expect(f.records, 1);
      expect(f.journal, 1);
      expect(f.answered, 2);
      expect(f.score, 3);
      expect(f.version, '1.15.0');
      expect(f.exportedAt, isNotNull);
    });

    test('别的 App 的 JSON 不认', () {
      expect(
        () => Portable.parse(envelope({'alarms': []}, app: 'other')),
        throwsA(isA<BackupError>()),
      );
    });

    test('不是 JSON / 空文件，给出人话原因', () {
      expect(() => Portable.parse('随便写点东西'),
          throwsA(isA<BackupError>()));
      expect(() => Portable.parse('   '), throwsA(isA<BackupError>()));
    });

    test('更新格式的备份提示先升级，不硬读', () {
      expect(
        () => Portable.parse(envelope({'alarms': []}, schema: 99)),
        throwsA(isA<BackupError>()),
      );
    });

    test('兼容「prefs 里存原始字符串」的自动备份写法', () {
      final b = Portable.parse(envelope({
        'alarms': jsonEncode([
          {'id': 2, 'hour': 7, 'minute': 0, 'days': <int>[]},
        ]),
      }));
      expect(b.alarms.length, 1);
      expect(b.alarms.first['hour'], 7);
    });

    test('一个能认的块都没有时拒绝，不留半份数据', () {
      expect(
        () => Portable.parse(envelope({'unrelated': 'x'})),
        throwsA(isA<BackupError>()),
      );
    });
  });

  group('闹钟合并', () {
    test('同一只（时间+重复一样）不重复添加', () {
      final local = jsonEncode([
        {'id': 1, 'hour': 6, 'minute': 30, 'days': [1, 2, 3, 4, 5]},
      ]);
      final b = Portable.parse(envelope({
        'alarms': [
          {'id': 9, 'hour': 6, 'minute': 30, 'days': [1, 2, 3, 4, 5]},
        ],
      }));
      final r = Portable.mergeInto({'alarms': local}, b);
      final list = jsonDecode(r.prefs['alarms']!) as List;
      expect(list.length, 1);
      expect(r.report.alarmsAdded, 0);
    });

    test('缺的补进来；id 撞了就换一个新号', () {
      final local = jsonEncode([
        {'id': 1, 'hour': 6, 'minute': 30, 'days': [1]},
      ]);
      final b = Portable.parse(envelope({
        'alarms': [
          // 同一时间段但另一只：id 也是 1，不能直接塞进来
          {'id': 1, 'hour': 7, 'minute': 0, 'days': [1]},
          {'id': 5, 'hour': 8, 'minute': 0, 'days': <int>[]},
        ],
      }));
      final r = Portable.mergeInto({'alarms': local}, b);
      final list = jsonDecode(r.prefs['alarms']!) as List;
      expect(list.length, 3);
      expect(r.report.alarmsAdded, 2);
      final ids = list.map((e) => e['id']).toSet();
      expect(ids.length, 3, reason: '三只闹钟必须各有各的 id');
    });
  });

  group('打卡记录合并', () {
    test('同一天取信息更全的一份，补齐的日子加进来', () {
      final local = jsonEncode([
        {'date': '2026-11-22', 'completed': false, 'quizTotal': 2, 'photo': ''},
      ]);
      final b = Portable.parse(envelope({
        'records': [
          {'date': '2026-11-22', 'completed': true, 'quizTotal': 5},
          {'date': '2026-11-21', 'completed': true, 'quizTotal': 8},
        ],
      }));
      final r = Portable.mergeInto({'records': local}, b);
      final list = jsonDecode(r.prefs['records']!) as List;
      expect(list.length, 2);
      expect(r.report.recordsAdded, 1);
      final d22 = list.firstWhere((e) => e['date'] == '2026-11-22');
      expect(d22['completed'], true, reason: '任一边完成过就算完成');
      expect(d22['quizTotal'], 5);
    });

    test('照片路径不会从别的手机照搬', () {
      final b = Portable.parse(envelope({
        'records': [
          {
            'date': '2026-11-20',
            'completed': true,
            'photo': '/data/user/0/cn.morning.morning/files/photos/x.jpg',
          },
        ],
      }));
      final r = Portable.mergeInto({'records': '[]'}, b);
      final list = jsonDecode(r.prefs['records']!) as List;
      expect(list.first['photo'], '', reason: '那个文件不在这台手机上');
    });
  });

  group('流水合并', () {
    test('同一条不重复，合并后按时间倒序', () {
      final local = jsonEncode([
        {'ts': 100, 'kind': 'quiz', 'title': 'A', 'detail': ''},
      ]);
      final b = Portable.parse(envelope({
        'journal': [
          {'ts': 100, 'kind': 'quiz', 'title': 'A', 'detail': ''},
          {'ts': 300, 'kind': 'news', 'title': 'B', 'detail': ''},
        ],
      }));
      final r = Portable.mergeInto({'journal': local}, b);
      final list = jsonDecode(r.prefs['journal']!) as List;
      expect(list.length, 2);
      expect(list.first['ts'], 300);
      expect(r.report.journalAdded, 1);
    });
  });

  group('设置合并', () {
    test('进行中的晨间流程不跟着搬', () {
      final b = Portable.parse(envelope({
        'settings': {
          'flowPending': '1',
          'flowPendingStep': '2',
          'themeId': '3',
        },
      }));
      final r = Portable.mergeInto({'settings': '{}'}, b);
      final s = jsonDecode(r.prefs['settings']!) as Map;
      expect(s.containsKey('flowPending'), isFalse);
      expect(s.containsKey('flowPendingStep'), isFalse);
      expect(s['themeId'], '3', reason: '普通设置该带过来');
    });

    test('本机已有的设置不被备份覆盖', () {
      final b = Portable.parse(envelope({
        'settings': {'themeId': '3'},
      }));
      final r = Portable.mergeInto({
        'settings': jsonEncode({'themeId': '1'}),
      }, b);
      final s = jsonDecode(r.prefs['settings']!) as Map;
      expect(s['themeId'], '1');
    });

    test('画像/战力/分数整体取答得更多的一份，不相加', () {
      final localProfile = jsonEncode({
        'answered': ['a'],
      });
      final backupProfile = jsonEncode({
        'answered': ['a', 'b', 'c'],
      });
      final b = Portable.parse(envelope({
        'settings': {
          'profile': backupProfile,
          'score': jsonEncode({'right': 30, 'wrong': 5}),
          'power': jsonEncode({'科技': 70}),
        },
      }));

      final r = Portable.mergeInto({
        'settings': jsonEncode({
          'profile': localProfile,
          'score': jsonEncode({'right': 3, 'wrong': 0}),
        }),
      }, b);

      final s = jsonDecode(r.prefs['settings']!) as Map;
      expect(r.report.cumulativeFromBackup, isTrue);
      expect(s['profile'], backupProfile);
      expect(s['score'], jsonEncode({'right': 30, 'wrong': 5}));
      expect(s['power'], isNotNull);
    });

    test('本机答得更多时保留本机的三本账', () {
      final b = Portable.parse(envelope({
        'settings': {
          'profile': jsonEncode({
            'answered': ['a'],
          }),
          'score': jsonEncode({'right': 1, 'wrong': 0}),
        },
      }));
      final localScore = jsonEncode({'right': 9, 'wrong': 2});
      final r = Portable.mergeInto({
        'settings': jsonEncode({
          'profile': jsonEncode({
            'answered': ['a', 'b', 'c'],
          }),
          'score': localScore,
        }),
      }, b);

      final s = jsonDecode(r.prefs['settings']!) as Map;
      expect(r.report.cumulativeFromBackup, isFalse);
      expect(s['score'], localScore);
    });
  });

  group('覆盖', () {
    test('备份里没有的块写空，等于清空', () {
      final b = Portable.parse(envelope({
        'alarms': [
          {'id': 1, 'hour': 6, 'minute': 30, 'days': [1]},
        ],
      }));
      final out = Portable.replaceWith(b);
      expect(out['alarms'], isNotEmpty);
      expect(out['journal'], '');
      expect(out['settings'], '');
    });
  });

  test('导出文件名带日期，能一眼看出是哪天的', () {
    final name = Portable.fileName(DateTime(2026, 3, 5, 7, 8));
    expect(name, '晨序备份_2026-03-05_0708.json');
  });
}
