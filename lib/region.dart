import 'dart:convert';

import 'package:flutter/material.dart';

import 'core.dart';

/// 「我住在哪里」。
///
/// 用户的原话是「让他人能选择他的县级市或者是农村，都要有一个能选择自己的地方」。
/// 这件事对新闻板块不是装饰：同一个 App，在县城和在村里，关心的东西根本不同——
/// 县里关心招聘、公积金、市场监管；村里关心医保缴费、农机补贴、宅基地和自来水。
/// 所以地区会真实影响「本地」那一栏给什么。
///
/// 四级：省 → 市 → 区县 → 乡镇/街道，外加一个「居住类型」（城区/县城/乡镇/农村），
/// 任何一级都允许手填——内置名录再全也不可能覆盖到每个社区和村。
class Region {
  final String province;
  final String city;
  final String county;
  final String town;

  /// 城区 / 县城 / 乡镇 / 农村。决定推荐哪些本地内容，不影响显示层级。
  final String area;

  const Region({
    this.province = '安徽省',
    this.city = '芜湖市',
    this.county = '南陵县',
    this.town = '',
    this.area = '县城',
  });

  static const kDefault = Region();

  /// 「安徽省 · 芜湖市 · 南陵县 · 籍山镇」
  String get full {
    final parts = [province, city, county, town].where((e) => e.trim().isNotEmpty);
    return parts.join(' · ');
  }

  /// 窄屏/标题里用的短名：优先到县，县为空再退到市
  String get short {
    if (county.trim().isNotEmpty) return county.trim();
    if (city.trim().isNotEmpty) return city.trim();
    return province.trim();
  }

  /// 是否选中了「南陵县」——本地自动抓取目前只接了这一个县
  bool get isNanling =>
      county == '南陵县' && city == '芜湖市' && province == '安徽省';

  bool get isRural => area == '农村' || area == '乡镇';

  Region copyWith({
    String? province,
    String? city,
    String? county,
    String? town,
    String? area,
  }) {
    return Region(
      province: province ?? this.province,
      city: city ?? this.city,
      county: county ?? this.county,
      town: town ?? this.town,
      area: area ?? this.area,
    );
  }

  Map<String, String> toJson() => {
        'province': province,
        'city': city,
        'county': county,
        'town': town,
        'area': area,
      };

  factory Region.fromJson(Map<String, dynamic> m) {
    String pick(String k, String d) {
      final v = m[k];
      return v is String && v.trim().isNotEmpty ? v.trim() : d;
    }

    return Region(
      province: pick('province', kDefault.province),
      city: pick('city', kDefault.city),
      county: pick('county', kDefault.county),
      town: m['town'] is String ? (m['town'] as String).trim() : '',
      area: pick('area', kDefault.area),
    );
  }

  // ---------------------------------------------------------------- 存取
  static Region _cur = kDefault;

  static Region get current => _cur;

  /// 改动计数。「我的」页和「新闻·本地」页都能改地区，改了要让另一边知道，
  /// 否则会出现「我的页显示农村、新闻页还按县城排」这种自相矛盾。
  static int _rev = 0;

  static int get revision => _rev;

  /// 读取。任何异常都退回默认值——地区选错不该让整个 App 起不来。
  static Region load() {
    try {
      final raw = Store.s('region', '');
      if (raw.isEmpty) {
        _cur = kDefault;
        return _cur;
      }
      final m = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      _cur = Region.fromJson(m);
    } catch (_) {
      _cur = kDefault;
    }
    return _cur;
  }

  static void save(Region r) {
    _cur = r;
    _rev++;
    Store.set('region', jsonEncode(r.toJson()));
  }
}

// ---------------------------------------------------------------- 内置名录
//
// 只收「到县」和「南陵县到镇」两级。全国乡镇有 3 万多个，塞进包里既大又必然过时，
// 所以乡镇一级一律允许手填——内置的只是常用项，不是全部项。

const List<String> kProvinces = [
  '北京市', '天津市', '河北省', '山西省', '内蒙古自治区', '辽宁省', '吉林省',
  '黑龙江省', '上海市', '江苏省', '浙江省', '安徽省', '福建省', '江西省',
  '山东省', '河南省', '湖北省', '湖南省', '广东省', '广西壮族自治区', '海南省',
  '重庆市', '四川省', '贵州省', '云南省', '西藏自治区', '陕西省', '甘肃省',
  '青海省', '宁夏回族自治区', '新疆维吾尔自治区', '台湾省',
  '香港特别行政区', '澳门特别行政区',
];

const List<String> kAnhuiCities = [
  '合肥市', '芜湖市', '蚌埠市', '淮南市', '马鞍山市', '淮北市', '铜陵市', '安庆市',
  '黄山市', '滁州市', '阜阳市', '宿州市', '六安市', '亳州市', '池州市', '宣城市',
];

const List<String> kWuhuDistricts = [
  '镜湖区', '弋江区', '鸠江区', '湾沚区', '繁昌区', '南陵县', '无为市',
];

const List<String> kNanlingTowns = [
  '籍山镇', '许镇镇', '弋江镇', '三里镇', '何湾镇', '工山镇', '家发镇', '烟墩镇',
];

const List<String> kAreaTypes = ['城区', '县城', '乡镇', '农村'];

List<String> citiesOf(String province) =>
    province == '安徽省' ? kAnhuiCities : const <String>[];

List<String> countiesOf(String city) =>
    city == '芜湖市' ? kWuhuDistricts : const <String>[];

List<String> townsOf(String county) =>
    county == '南陵县' ? kNanlingTowns : const <String>[];

/// 手填时给一句提示，免得用户不知道能填到多细
String hintFor(String level) {
  switch (level) {
    case 'province':
      return '比如：安徽省';
    case 'city':
      return '比如：芜湖市';
    case 'county':
      return '比如：南陵县 / 无为市';
    case 'town':
      return '填到村或社区更好，比如：籍山镇 / 弋江镇浦东村';
    default:
      return '';
  }
}

// ---------------------------------------------------------------- 选择页

/// 四级选择。上面没有的，下面直接打字——名录只是省事，不是限制。
class RegionPickPage extends StatefulWidget {
  const RegionPickPage({super.key});

  @override
  State<RegionPickPage> createState() => _RegionPickPageState();
}

class _RegionPickPageState extends State<RegionPickPage> {
  late Region _r = Region.current;
  late final TextEditingController _cProvince = TextEditingController(text: _r.province);
  late final TextEditingController _cCity = TextEditingController(text: _r.city);
  late final TextEditingController _cCounty = TextEditingController(text: _r.county);
  late final TextEditingController _cTown = TextEditingController(text: _r.town);

  @override
  void dispose() {
    _cProvince.dispose();
    _cCity.dispose();
    _cCounty.dispose();
    _cTown.dispose();
    super.dispose();
  }

  void _save() {
    final r = Region(
      province: _cProvince.text.trim(),
      city: _cCity.text.trim(),
      county: _cCounty.text.trim(),
      town: _cTown.text.trim(),
      area: _r.area,
    );
    Region.save(r);
    Navigator.of(context).pop(r);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColor.bg,
      appBar: AppBar(
        backgroundColor: AppColor.bg,
        elevation: 0,
        title: const Text('我在哪儿', style: TextStyle(fontSize: 16)),
        iconTheme: IconThemeData(color: AppColor.ink),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 20),
                children: [
                  Text(
                    '选得越细，本地那一栏越准。选得不对也随时能改，不影响已有的记录。',
                    style: TextStyle(fontSize: 11.5, color: AppColor.sub, height: 1.6),
                  ),
                  const SizedBox(height: 18),
                  _level('省 / 直辖市', kProvinces, _cProvince, (v) {
                    _cCity.text = '';
                    _cCounty.text = '';
                    _cTown.text = '';
                    setState(() {});
                  }),
                  _level('市', citiesOf(_cProvince.text), _cCity, (v) {
                    _cCounty.text = '';
                    _cTown.text = '';
                    setState(() {});
                  }),
                  _level('区 / 县 / 县级市', countiesOf(_cCity.text), _cCounty, (v) {
                    _cTown.text = '';
                    setState(() {});
                  }),
                  _level('乡镇 / 街道 / 村', townsOf(_cCounty.text), _cTown, (v) => setState(() {})),
                  const SizedBox(height: 6),
                  Text('住的地方更像',
                      style: TextStyle(fontSize: 12, color: AppColor.ink, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final a in kAreaTypes)
                        _chip(a, _r.area == a, () => setState(() => _r = _r.copyWith(area: a))),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '选「农村」会把医保缴费、农机补贴、养老和宅基地这类排在前面；'
                    '选「县城」会更偏向招聘、办事和市场监管的通告。',
                    style: TextStyle(fontSize: 11, color: AppColor.sub, height: 1.6),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColor.ink,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                  ),
                  onPressed: _save,
                  child: const Text('就住这儿'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _level(
    String label,
    List<String> options,
    TextEditingController ctrl,
    void Function(String) onPick,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(fontSize: 12, color: AppColor.ink, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          if (options.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final o in options)
                    _chip(o, ctrl.text == o, () {
                      ctrl.text = o;
                      onPick(o);
                    }),
                ],
              ),
            ),
          TextField(
            controller: ctrl,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              hintText: hintFor(label.contains('省') ? 'province' : label == '市' ? 'city' : label.contains('区') ? 'county' : 'town'),
              hintStyle: TextStyle(fontSize: 12, color: AppColor.sub),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              filled: true,
              fillColor: AppColor.card,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: AppColor.line),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: AppColor.line),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String text, bool on, VoidCallback tap) {
    return GestureDetector(
      onTap: tap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: on ? AppColor.accentSoft : AppColor.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: on ? AppColor.accent : AppColor.line),
        ),
        child: Text(
          text,
          style: TextStyle(fontSize: 12, color: on ? AppColor.accent : AppColor.sub),
        ),
      ),
    );
  }
}
