import 'package:flutter_test/flutter_test.dart';
import 'package:morning/bank_local.dart';
import 'package:morning/local_feed.dart';
import 'package:morning/region.dart';

/// 本地区块的三件事都要能测：地区存取、HTML 抽取、按居住类型排序。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('地区', () {
    test('默认是安徽省芜湖市南陵县', () {
      const r = Region.kDefault;
      expect(r.province, '安徽省');
      expect(r.city, '芜湖市');
      expect(r.county, '南陵县');
      expect(r.isNanling, true);
      expect(r.full, '安徽省 · 芜湖市 · 南陵县');
    });

    test('json 往返不丢字段', () {
      const r = Region(
        province: '安徽省',
        city: '芜湖市',
        county: '南陵县',
        town: '籍山镇',
        area: '农村',
      );
      final back = Region.fromJson(Map<String, dynamic>.from(r.toJson()));
      expect(back.town, '籍山镇');
      expect(back.area, '农村');
      expect(back.isRural, true);
      expect(back.full, '安徽省 · 芜湖市 · 南陵县 · 籍山镇');
    });

    test('字段缺失或为空时退回默认，不抛异常', () {
      final r = Region.fromJson({'province': '', 'county': '   '});
      expect(r.province, '安徽省');
      expect(r.county, '南陵县');
    });

    test('换了县就不再算南陵', () {
      const r = Region(province: '安徽省', city: '芜湖市', county: '无为市');
      expect(r.isNanling, false);
      expect(LocalFeed.supports(r), false);
    });

    test('名录能对上：芜湖 7 个区县、南陵 8 个镇', () {
      expect(kWuhuDistricts.length, 7);
      expect(kWuhuDistricts.contains('南陵县'), true);
      expect(kNanlingTowns.length, 8);
      expect(kNanlingTowns.contains('籍山镇'), true);
      // 名录里不该出现外地的镇
      expect(townsOf('无为市').isEmpty, true);
    });
  });

  group('抓取解析', () {
    // 结构照抄南陵县政府网的真实列表页
    const html = '''
      <ul class="doc_list list-6788650">
        <li class="odd">
          <a href="https://www.nlx.gov.cn/xwzx/jrnl/12285210.html" target="_blank" title="县委常委会会议暨群众身边不正之风和腐败问题集中整治调度会召开" class="left">
            <span style='color:;'>县委常委会会议暨群众身边不正之风和腐败问题集中整治调度会召开</span>
          </a>
          <span class="right date">2026-11-20</span>
        </li>
        <li class="even">
          <a href="https://www.nlx.gov.cn/xwzx/jrnl/12285123.html" title="南陵县县属国有企业公开招聘管理层及工作人员体检进一步检查结果公布" class="left"></a>
          <span class="right date">2026-11-19</span>
        </li>
        <li class="odd">
          <a href="https://www.wuhu.gov.cn/xwzx/xqkx/41405680.html" title="这条是市里的，不该进南陵要闻" class="left"></a>
          <span class="right date">2026-11-18</span>
        </li>
      </ul>
    ''';

    test('抽出标题与日期，标题属性优先于内层文字', () {
      final list = LocalFeed.parseColumn(html, '要闻', 'jrnl');
      expect(list.length, 2);
      expect(list.first.title, contains('县委常委会会议'));
      expect(list.first.date, '2026-11-20');
      expect(list.first.col, '要闻');
      expect(list.first.url, startsWith('https://www.nlx.gov.cn/xwzx/jrnl/'));
    });

    test('别家站点的链接按栏目路径过滤掉', () {
      final list = LocalFeed.parseColumn(html, '要闻', 'jrnl');
      expect(list.any((e) => e.url.contains('wuhu.gov.cn')), false);
    });

    test('同一条重复出现只算一次', () {
      const doubled = html + html;
      final list = LocalFeed.parseColumn(doubled, '要闻', 'jrnl');
      expect(list.length, 2);
    });

    test('人事类按标题词识别', () {
      final list = LocalFeed.parseColumn(html, '公告', 'jrnl');
      final hire = list.firstWhere((e) => e.title.contains('公开招聘'));
      expect(hire.isPersonnel, true);
      const plain = FeedItem('关于清理非税收入汇缴结算账户待查收入资金的公告', 'u', '公告', '');
      expect(plain.isPersonnel, false);
      const notice = FeedItem('停 气 通 知(弋江镇浦东小区)', 'u', '公告', '');
      expect(notice.isPersonnel, false);
      const appoint = FeedItem('干部任前公示', 'u', '公告', '');
      expect(appoint.isPersonnel, true);
      // v1.6.0 真机上错标过：县里大量「项目验收结果公示」被当成人事
      const project = FeedItem('关于南陵县某优势特色产业集群完工项目验收结果的公示', 'u', '公告', '');
      expect(project.isPersonnel, false);
    });

    test('空页面不报错，返回空表', () {
      expect(LocalFeed.parseColumn('', '要闻', 'jrnl'), isEmpty);
      expect(LocalFeed.parseColumn('<html><body>no list</body></html>', '要闻', 'jrnl'), isEmpty);
    });
  });

  group('本地办事', () {
    test('六条都在，键名 l01..l06 与音频文件一一对应', () {
      expect(kLocalBriefs.length, 6);
      for (var i = 0; i < kLocalBriefs.length; i++) {
        expect(kLocalBriefs[i].key, 'l${(i + 1).toString().padLeft(2, '0')}');
      }
    });

    test('不写死金额、文号和人名——这类数字第二天就可能不准', () {
      for (final b in kLocalBriefs) {
        final all = '${b.title}${b.spoken}${b.steps.join()}';
        expect(RegExp(r'\d+\s*元').hasMatch(all), false, reason: '${b.key} 写了金额');
        expect(RegExp(r'〔\d{4}〕|\[\d{4}\]').hasMatch(all), false, reason: '${b.key} 写了文号');
        expect(all.contains('同志'), false, reason: '${b.key} 提到了具体人');
      }
    });

    test('选农村时，农村更常用的条目排在前面', () {
      final rural = LocalBrief.forArea('农村');
      final top2 = rural.take(2).map((e) => e.topic).toList();
      expect(top2.contains('医保') || top2.contains('农业') || top2.contains('养老'), true);
      final urban = LocalBrief.forArea('县城');
      expect(urban.first.prefer.contains('县城'), true);
    });

    test('官方渠道都是 https', () {
      expect(kLocalChannels.length >= 3, true);
      for (final c in kLocalChannels) {
        expect(c.url.startsWith('https://'), true, reason: c.name);
      }
    });
  });
}
