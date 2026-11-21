// 事实卡的汇总入口。
//
// 五份数据按「一个人周围的一切」分：
//   occup  职业 —— 你靠什么吃饭，手上是什么活
//   life   生活 —— 吃住行、看病上学、人情往来
//   tool   工具 —— 手机、电脑、家电、五金、车、软件、网络、科技
//   hobby  爱好 —— 球、钓、棋、乐、书、影、游、手工、游戏、养，加体育与文化
//   world  世界 —— 健康、钱、社会、国际、环境、军事
//
// 一行数据展开成五到八道题，所以总量是这里行数的七倍左右。
// 加内容只改这几个文件，生成器和树都不用动。

import 'seed_hobby.dart';
import 'seed_life.dart';
import 'seed_occup.dart';
import 'seed_tool.dart';
import 'seed_world.dart';

final List<String> kSeedRows = <String>[
  for (final s in <String>[kSeedOccup, kSeedLife, kSeedTool, kSeedHobby, kSeedWorld])
    ...s.split('\n'),
];
