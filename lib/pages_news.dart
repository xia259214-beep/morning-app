import 'dart:async';

import 'package:flutter/material.dart';

import 'bank.dart';
import 'bank_local.dart';
import 'core.dart';
import 'glass.dart';
import 'journal.dart';
import 'local_feed.dart';
import 'morning_news.dart';
import 'news_engine.dart';
import 'news_slot.dart';
import 'region.dart';
import 'speech.dart';

/// 一条能念的东西。可能是包里带的真人音色（sample），也可能只有文字（text）。
class _Track {
  /// 唯一键：同一页里用来标「正在念的是哪条」
  final String key;
  final String label;

  /// 包里音频的键（n03 / l01）。为空说明要走系统 TTS
  final String sample;
  final String text;

  /// 念到时记进日志的东西
  final void Function()? onPlayed;

  const _Track({
    required this.key,
    required this.label,
    this.sample = '',
    this.text = '',
    this.onPlayed,
  });
}

/// 「新闻」板块。
///
/// v1.5.0 补齐了「没有新闻板块」这件事，但还留着两个硬伤：
///   1. 每条新闻都得点一下才念，念完就停，用户要的是点一次一路念下去；
///   2. 内容全是全国向的示例，没有本地——他在南陵县，关心的是县里的
///      医保缴费、招聘、任前公示、停水停气。
/// v1.6.0 补的就是这两件事，外加「我住在哪儿」的选择。
class NewsPage extends StatefulWidget {
  const NewsPage({super.key});

  @override
  State<NewsPage> createState() => _NewsPageState();
}

class _NewsPageState extends State<NewsPage> {
  late List<NewsItem> _today;
  late Region _region;
  int _regionRev = -1;

  /// 0 今日 / 1 本地 / 2 全部
  int _seg = 0;

  String? _expanded;

  // ---- 真实新闻（v1.8.0）
  /// 抓到的全部条目，按时间倒序
  List<Headline> _heads = const [];

  /// 按画像排过序的一份，仅供「今日」用
  List<Headline> _ranked = const [];

  bool _headsLoading = false;
  String _chanFilter = '全部';
  int _allLimit = 20;

  /// 今日栏先铺这么多。原来固定三条，用户反馈「就更新了三个」，
  /// 所以按一屏能听完的量给——早上听 15 条约十来分钟，正好是洗漱加出门。
  static const int _todayShown = 15;

  // ---- 播报状态
  List<_Track> _tracks = const [];
  int _playingIndex = -1;
  bool _queueRunning = false;
  String _playingKey = '';
  StreamSubscription<Map<String, dynamic>>? _playSub;

  // ---- 本地抓取
  FeedResult? _feed;
  bool _feedLoading = false;
  String _feedFilter = '全部';

  /// 一次先显示几条。县里一天几十条公告，全铺开会把下面的官方渠道压到很远。
  int _feedLimit = 8;

  @override
  void initState() {
    super.initState();
    _today = todayNews(Profile.load());
    _region = Region.load();
    _regionRev = Region.revision;
    _feed = LocalFeed.cached();
    _heads = NewsEngine.cached();
    _rebuildRanked();
    _playSub = Bridge.playEvents.listen(_onPlayEvent);
    // 进来先看一眼该不该更新，而不是让用户每次自己按「联网刷新」。
    // 什么时候该刷由 NewsSchedule 说了算：只在 5:00-19:00、且隔了 5 小时、
    // 或刚过 8:30 换台的时候才会真的发请求。
    _autoRefresh();
  }

  void _rebuildRanked() {
    _ranked = _heads.isEmpty
        ? const []
        : NewsEngine.rank(_heads, Profile.load(), now: DateTime.now());
  }

  Future<void> _autoRefresh() async {
    final now = DateTime.now();
    final should = NewsSchedule.shouldFetch(
      now: now,
      lastTry: NewsEngine.lastTry(),
      lastOk: NewsEngine.lastOk(),
    );
    if (!should) return;
    await _fetchHeads(silent: true);
  }

  Future<void> _fetchHeads({bool silent = false}) async {
    if (_headsLoading) return;
    setState(() => _headsLoading = true);
    final r = await NewsEngine.fetch();
    if (!mounted) return;
    setState(() {
      _headsLoading = false;
      if (r.items.isNotEmpty) {
        _heads = r.items;
        _rebuildRanked();
        _allLimit = 20;
      }
    });
    // v1.13.2：抓到新新闻就刷新播报文本。不刷新的话，明早强制播报
    // 念的还是上一次晨间流程留下的旧文本。
    if (r.items.isNotEmpty) MorningNews.refreshSpeech(Profile.load());
    if (!silent && r.error.isNotEmpty) _toast(r.error);
  }

  @override
  void dispose() {
    _playSub?.cancel();
    Bridge.stopSpeak();
    super.dispose();
  }

  // ============================================================ 播报
  void _onPlayEvent(Map<String, dynamic> e) {
    final ev = (e['event'] ?? '') as String;
    final i = (e['index'] as num?)?.toInt() ?? -1;
    if (!mounted) return;
    switch (ev) {
      case 'start':
      case 'skip':
        if (i >= 0 && i < _tracks.length) {
          setState(() {
            _playingIndex = i;
            _playingKey = _tracks[i].key;
          });
          // 念到就算听过：不管是真人音色还是系统语音，用户耳朵里已经过了一遍
          if (ev == 'start') _tracks[i].onPlayed?.call();
        }
        break;
      case 'done':
        setState(() {
          _queueRunning = false;
          _playingIndex = -1;
          _playingKey = '';
        });
        break;
    }
  }

  /// 停止：原生侧把 token 加一，所有在飞的「下一条」立刻失效
  Future<void> _stop() async {
    await Bridge.stopSpeak();
    if (!mounted) return;
    setState(() {
      _queueRunning = false;
      _playingIndex = -1;
      _playingKey = '';
    });
  }

  Future<void> _playAll(List<_Track> tracks) async {
    if (tracks.isEmpty) return;
    // 已经在放同一串：再点就是停
    if (_queueRunning && _tracks.length == tracks.length && _tracks.first.key == tracks.first.key) {
      _stop();
      return;
    }
    await Bridge.stopSpeak();
    // v1.9.0：整串只用一种音源。以前一串里「真人录音 mp3」和「系统 TTS」
    // 交替出现，两种音色换来换去，就是用户说的「声音太杂」。
    // 只要有一条没有配套录音（真实新闻都没有），整串就统一用系统语音念。
    final uniform = useUniformVoice([for (final t in tracks) t.sample]);
    final r = await Bridge.playQueue([
      for (final t in tracks)
        if (uniform)
          {'text': cleanSpeech(t.text.isEmpty ? t.label : t.text)}
        else
          {'sample': t.sample},
    ]);
    if (!mounted) return;
    if (r['ok'] != true) {
      final reason = (r['reason'] ?? '') as String;
      final msg = switch (reason) {
        'muted' => '媒体音量是 0，听不到。把音量键往上按两下再点一次。',
        'empty' => '这一栏现在没有可播的内容。',
        'bad_items' => '这些条目没有配套音频。',
        _ => '播不出来，过一会儿再试。',
      };
      setState(() {
        _queueRunning = false;
        _playingIndex = -1;
        _playingKey = '';
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(duration: const Duration(seconds: 5), content: Text(msg)));
      return;
    }
    setState(() {
      _tracks = tracks;
      _queueRunning = true;
      _playingIndex = 0;
      _playingKey = tracks.first.key;
    });
    tracks.first.onPlayed?.call();
  }

  Future<void> _playOne(_Track t) async {
    if (_queueRunning && _playingKey == t.key) {
      _stop();
      return;
    }
    await _playAll([t]);
  }

  void _toast(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(duration: const Duration(seconds: 4), content: Text(s)));
  }

  // ============================================================ 日志
  Map<String, JEvent> get _evMap {
    final m = <String, JEvent>{};
    for (final e in Journal.onDay(Store.today)) {
      if (e.kind == JKind.news) m.putIfAbsent(e.title, () => e);
    }
    return m;
  }

  /// 「看到」就算数：展开看一眼也记一笔。同一天同一条只记一次。
  void _logSeen(String title, {String detail = '', String tag = ''}) {
    if (_evMap.containsKey(title)) return;
    Journal.add(JKind.news, title, detail: detail, tag: tag);
    setState(() {});
  }

  void _markSpoken(String title) {
    final e = _evMap[title];
    if (e != null) Journal.markSpoken(e);
    if (mounted) setState(() {});
  }

  // ============================================================ 队列组装

  /// 今天该听的那一批。有联网内容就用联网的（已按画像排过），
  /// 一条都没有才回落到内置示例——不然第一次打开是空页面，体验更差。
  List<Headline> get _todayList {
    if (_ranked.isEmpty) return const [];
    final now = DateTime.now();
    // 太旧的不进「今日」：36 小时以外的东西属于「全部」那栏。
    // 夜里不刷新，早上 5 点打开时手上最新的一批也就是十几个小时前的，
    // 这个门槛得留够。
    final fresh = _ranked.where((h) => now.difference(h.time).inHours <= 36).toList();
    final src = fresh.length >= 6 ? fresh : _ranked;
    // 打散之后再截：同一家公司连发六条时，前面几条应该是不同的事，
    // 同一件事的后续报道挪到后面去。
    return NewsEngine.interleave(src).take(_todayShown).toList();
  }

  /// 念什么：标题加摘要，摘要超过 90 字就截断。
  /// 一条念两分钟的话，十五条就是半小时，早上没那么多时间。
  String _spokenOf(Headline h) {
    if (h.summary.isEmpty) return h.title;
    final body = h.summary.length > 90 ? '${h.summary.substring(0, 90)}…' : h.summary;
    return '${h.title}。$body';
  }

  _Track _headTrack(Headline h) => _Track(
        key: 'h-${h.url.isEmpty ? h.title : h.url}',
        label: h.title,
        text: _spokenOf(h),
        onPlayed: () => _logSeen(h.title, detail: h.summary, tag: '${h.channel} · ${h.source}'),
      );

  _Track _oldTrack(NewsItem n) => _Track(
        key: 'n${kNews.indexOf(n)}',
        label: n.title,
        sample: newsSampleKey(n),
        text: '${n.title}。${n.summary}',
        onPlayed: () {
          _logSeen(n.title, detail: n.summary, tag: '${n.topic} · ${n.source}');
          _markSpoken(n.title);
        },
      );

  List<_Track> get _todayTracks {
    if (_heads.isNotEmpty) return [for (final h in _todayList) _headTrack(h)];
    return [for (final n in _today) _oldTrack(n)];
  }

  /// 「全部」栏里按当前分类筛出来的条目，时间倒序
  List<Headline> get _allList {
    if (_chanFilter == '全部') return _heads;
    return _heads.where((h) => h.channel == _chanFilter).toList();
  }

  List<_Track> get _allTracks {
    if (_heads.isEmpty) return [for (final n in kNews) _oldTrack(n)];
    return [for (final h in _allList) _headTrack(h)];
  }

  List<_Track> _localTracks() {
    final list = <_Track>[
      for (final b in LocalBrief.forArea(_region.area))
        _Track(
          key: 'l-${b.key}',
          label: b.title,
          sample: localSampleKey(b),
          text: '${b.title}。${b.spoken}',
          onPlayed: () => _logSeen('${_region.short}·${b.title}',
              detail: b.steps.first, tag: '本地 · ${b.topic}'),
        ),
    ];
    for (final f in _visibleFeed().take(6)) {
      list.add(_Track(
        key: 'f-${f.url}',
        label: f.title,
        text: '${f.col}资讯。${f.title}',
        onPlayed: () =>
            _logSeen(f.title, detail: '${_region.short} · ${f.col} · ${f.date}', tag: '本地 · 官方'),
      ));
    }
    return list;
  }

  List<FeedItem> _visibleFeed() {
    final all = _feed?.items ?? const <FeedItem>[];
    switch (_feedFilter) {
      case '要闻':
        return all.where((e) => e.col == '要闻').toList();
      case '部门 · 镇村':
        return all.where((e) => e.col == '部门' || e.col == '镇村').toList();
      case '公告':
        return all.where((e) => e.col == '公告').toList();
      case '人事 · 招聘':
        return all.where((e) => e.isPersonnel).toList();
      default:
        return all;
    }
  }

  // ============================================================ 本地抓取
  Future<void> _refreshFeed() async {
    if (_feedLoading) return;
    setState(() => _feedLoading = true);
    final r = await LocalFeed.fetch(region: _region);
    if (!mounted) return;
    setState(() {
      _feedLoading = false;
      if (r.items.isNotEmpty) {
        _feed = r;
      } else {
        _toast(r.error.isEmpty ? '没拉到内容' : r.error);
      }
      if (r.items.isNotEmpty && r.error.isNotEmpty) _toast(r.error);
    });
  }

  Future<void> _changeRegion() async {
    final r = await Navigator.of(context).push<Region>(
      MaterialPageRoute(builder: (_) => const RegionPickPage()),
    );
    if (!mounted || r == null) return;
    setState(() {
      _region = r;
      // 换了地区，上一处抓的内容不再适用——清掉，别把甲县的公告贴到乙县头上
      _feed = LocalFeed.cached();
      _feedFilter = '全部';
      _feedLimit = 8;
    });
  }

  Future<void> _open(String url) async {
    final ok = await Bridge.openUrl(url);
    if (!ok) _toast('没打开，可能是手机上没有浏览器');
  }

  // ============================================================ 页面
  @override
  Widget build(BuildContext context) {
    // 在「我的」页改过地区，这里要跟上。build 里直接赋值、不 setState——
    // 本来就在重建，再触发一次没意义。
    if (_regionRev != Region.revision) {
      _regionRev = Region.revision;
      _region = Region.load();
    }
    final events = _evMap;
    final spoken = events.values.where((e) => e.spoken).length;
    final seen = events.length;

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Text('新闻', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w300)),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(_dateLabel(DateTime.now()),
                    style: TextStyle(fontSize: 11.5, color: AppColor.sub)),
              ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('看 $seen · 听 $spoken',
                    style: TextStyle(fontSize: 11.5, color: AppColor.accent)),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _segBar(),
          const SizedBox(height: 14),
          if (_seg == 0) ..._todaySection(events),
          if (_seg == 1) ..._localSection(events),
          if (_seg == 2) ..._allSection(events),
          const SizedBox(height: 18),
          _note(),
        ],
      ),
    );
  }

  Widget _segBar() {
    const labels = ['今日', '本地', '全部'];
    return Row(
      children: [
        for (var i = 0; i < labels.length; i++) ...[
          GestureDetector(
            onTap: () => setState(() => _seg = i),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: glassDecoration(
                radius: 9,
                selected: _seg == i,
                accent: _seg == i ? AppColor.accent.withOpacity(0.8) : null,
                alpha: _seg == i ? 0.9 : 0.3,
                flatFill: Colors.transparent,
              ),
              child: Text(
                labels[i],
                style: TextStyle(
                  fontSize: 12.5,
                  color: _seg == i ? AppColor.bg : AppColor.sub,
                  fontWeight: _seg == i ? FontWeight.w500 : FontWeight.w400,
                ),
              ),
            ),
          ),
          if (i < labels.length - 1) const SizedBox(width: 8),
        ],
        const Spacer(),
        if (_seg == 1)
          Text(_region.short, style: TextStyle(fontSize: 11, color: AppColor.sub)),
      ],
    );
  }

  // ---------------------------------------------------------------- 今日
  List<Widget> _todaySection(Map<String, JEvent> events) {
    final list = _todayList;
    final now = DateTime.now();
    return [
      _statusBar(),
      const SizedBox(height: 12),
      if (_heads.isEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            '还没有拿到网上的新闻。下面这几条是内置的，先把页面填上；'
            '点右上角「刷新」就会换成真的。',
            style: TextStyle(fontSize: 11.5, color: AppColor.sub, height: 1.6),
          ),
        ),
      _playBar('连续播报今日 ${_heads.isEmpty ? _today.length : list.length} 条', _todayTracks),
      const SizedBox(height: 14),
      if (_heads.isEmpty)
        for (var i = 0; i < _today.length; i++)
          _card(_today[i], index: i + 1, featured: true, ev: events[_today[i].title])
      else
        for (var i = 0; i < list.length; i++)
          _headlineCard(list[i],
              index: i + 1, featured: i < 3, ev: events[list[i].title], now: now),
    ];
  }

  /// 顶部那条状态：现在处于哪个时段、上次什么时候拿的、下次什么时候拿。
  ///
  /// 这个条不是为了好看。用户的原话是「5 点到 8 点半是定制，之后是正常新闻，
  /// 7 点以后别刷了」——这套规则如果界面上看不见，他就会怀疑到底有没有生效。
  Widget _statusBar() {
    final now = DateTime.now();
    final slot = NewsSchedule.slotOf(now);
    final text = NewsSchedule.statusText(now, lastOk: NewsEngine.lastOk());
    final tint = slot == NewsSlot.silent ? AppColor.sub : AppColor.accent;

    // 时段状态条用带强调色的玻璃卡：定制时段偏暖，其余偏冷，
    // 半透后能看到背后的光晕，比原来一块死板的实心色块有层次。
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      margin: EdgeInsets.zero,
      radius: 12,
      accent: slot == NewsSlot.custom
          ? AppColor.accent.withOpacity(0.55)
          : null,
      child: Row(
        children: [
          Icon(
            slot == NewsSlot.silent
                ? Icons.nightlight_outlined
                : (slot == NewsSlot.custom ? Icons.wb_twilight : Icons.newspaper),
            size: 15,
            color: tint,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(text,
                style: TextStyle(fontSize: 11, height: 1.5, color: tint)),
          ),
          const SizedBox(width: 6),
          if (_headsLoading)
            SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(strokeWidth: 1.5, color: AppColor.sub),
            )
          else
            InkWell(
              onTap: () => _fetchHeads(),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Text('刷新', style: TextStyle(fontSize: 11.5, color: AppColor.accent)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _chanChip(String text, int count) {
    final on = _chanFilter == text;
    return GestureDetector(
      onTap: () => setState(() {
        _chanFilter = text;
        _allLimit = 20;
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: glassDecoration(
          radius: 7,
          selected: on,
          accent: on ? AppColor.accent.withOpacity(0.75) : null,
          alpha: on ? 0.85 : 0.35,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(text,
                style: TextStyle(fontSize: 11, color: on ? AppColor.accent : AppColor.sub)),
            if (count > 0) ...[
              const SizedBox(width: 4),
              Text('$count',
                  style: TextStyle(fontSize: 9.5, color: on ? AppColor.accent : AppColor.sub)),
            ],
          ],
        ),
      ),
    );
  }

  /// 「全部」栏的一张新闻卡：频道、来源、时间、摘要、播报、原文
  Widget _headlineCard(Headline h,
      {int? index, required bool featured, JEvent? ev, required DateTime now}) {
    final key = 'h-${h.url.isEmpty ? h.title : h.url}';
    final open = _expanded == key;
    final playing = _playingKey == key;
    final heard = ev?.spoken == true;

    // 真实新闻卡：前三条做真模糊（featured），后面的用轻量半透明，
    // 一屏十几张不至于堆十几个 BackdropFilter 拖慢滚动。
    return GlassCard(
      margin: const EdgeInsets.only(bottom: 10),
      padding: EdgeInsets.all(featured ? 15 : 12),
      radius: featured ? 18 : 14,
      featured: featured,
      blur: featured,
      accent: playing ? AppColor.accent.withOpacity(0.9) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (index != null) ...[
                Text(
                  index.toString().padLeft(2, '0'),
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColor.accent,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              _chip(h.channel),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  h.source,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10, color: AppColor.sub),
                ),
              ),
              const SizedBox(width: 6),
              Text(h.timeLabel(now),
                  style: TextStyle(fontSize: 10, color: AppColor.sub)),
              const Spacer(),
              if (heard)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(Icons.hearing, size: 14, color: AppColor.ok),
                ),
              InkWell(
                onTap: () => _playOne(_headTrack(h)),
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.all(5),
                  child: Icon(
                    playing ? Icons.graphic_eq : Icons.play_circle_outline,
                    size: 21,
                    color: playing ? AppColor.accent : AppColor.sub,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          GestureDetector(
            onTap: () {
              setState(() => _expanded = open ? null : key);
              if (!open) {
                _logSeen(h.title,
                    detail: h.summary, tag: '${h.channel} · ${h.source}');
              }
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  h.title,
                  style: TextStyle(
                    fontSize: featured ? 16 : 14,
                    height: 1.45,
                    fontWeight: featured ? FontWeight.w500 : FontWeight.w400,
                    color: AppColor.ink,
                  ),
                ),
                if (h.summary.isNotEmpty) ...[
                  const SizedBox(height: 7),
                  Text(
                    h.summary,
                    maxLines: open ? 20 : (featured ? 3 : 2),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: featured ? 12.5 : 11.5,
                      height: 1.7,
                      color: AppColor.sub,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (h.url.isNotEmpty)
                InkWell(
                  onTap: () {
                    _logSeen(h.title,
                        detail: h.summary, tag: '${h.channel} · ${h.source}');
                    _open(h.url);
                  },
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
                    child: Row(
                      children: [
                        Text('看原文',
                            style: TextStyle(fontSize: 10.5, color: AppColor.accent)),
                        Icon(Icons.open_in_new, size: 11, color: AppColor.accent),
                      ],
                    ),
                  ),
                ),
              const Spacer(),
              if (playing)
                Text('正在朗读…', style: TextStyle(fontSize: 10.5, color: AppColor.accent))
              else if (!open)
                Text('展开', style: TextStyle(fontSize: 10.5, color: AppColor.sub)),
            ],
          ),
        ],
      ),
    );
  }


  /// 一整串播报的开关。放在每栏最上面，点一次就一路念到底。
  Widget _playBar(String idleLabel, List<_Track> tracks, {String? note}) {
    final playing = _queueRunning && _tracks.isNotEmpty && tracks.isNotEmpty &&
        _tracks.first.key == tracks.first.key &&
        _tracks.length == tracks.length;
    final progress = playing && _playingIndex >= 0 ? '${_playingIndex + 1} / ${_tracks.length}' : '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GlassCard(
          onTap: () => _playAll(tracks),
          margin: EdgeInsets.zero,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          radius: 14,
          featured: true,
          accent: playing ? AppColor.accent.withOpacity(0.9) : null,
          child: Row(
              children: [
                Icon(playing ? Icons.stop_circle_outlined : Icons.playlist_play,
                    size: 20, color: playing ? AppColor.accent : AppColor.ink),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    playing ? '正在连续播报 · $progress　点一下停' : idleLabel,
                    style: TextStyle(
                      fontSize: 13,
                      color: playing ? AppColor.accent : AppColor.ink,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (playing && _playingKey.isNotEmpty)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 180),
                    child: Text(
                      _tracks[_playingIndex].label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: TextStyle(fontSize: 10.5, color: AppColor.sub),
                    ),
                  ),
              ],
            ),
        ),
        if (note != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 2),
            child: Text(note, style: TextStyle(fontSize: 10.5, color: AppColor.sub, height: 1.5)),
          ),
      ],
    );
  }

  // ---------------------------------------------------------------- 本地
  List<Widget> _localSection(Map<String, JEvent> events) {
    final feed = _visibleFeed();
    final shownFeed = feed.take(_feedLimit).toList();
    // 这一栏的播报串 = 六条办事指北 + 抓来的前六条要闻，条数随联网状态变
    final localTracks = _localTracks();
    final cached = _feed?.cached == true;
    final ago = LocalFeed.agoLabel();

    return [
      // 地区
      GlassCard(
        onTap: _changeRegion,
        margin: EdgeInsets.zero,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        radius: 14,
        child: Row(
            children: [
              Icon(Icons.place_outlined, size: 17, color: AppColor.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(_region.full,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: AppColor.ink)),
              ),
              Text('改', style: TextStyle(fontSize: 12, color: AppColor.accent)),
              Icon(Icons.chevron_right, size: 16, color: AppColor.accent),
            ],
        ),
      ),
      const SizedBox(height: 8),
      Text(regionHint(_region),
          style: TextStyle(fontSize: 11, color: AppColor.sub, height: 1.6)),
      const SizedBox(height: 16),

      // 政策与办事放在最前面：它不依赖联网，一进「本地」就该看到，
      // 而不是让用户先翻完几十条要闻才找到。
      Row(
        children: [
          Text('政策与办事',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColor.ink)),
          const SizedBox(width: 8),
          Text('${kLocalBriefs.length} 条', style: TextStyle(fontSize: 11, color: AppColor.sub)),
          const Spacer(),
          Text(_region.isRural ? '按农村优先排' : '按县城优先排',
              style: TextStyle(fontSize: 10.5, color: AppColor.sub)),
        ],
      ),
      const SizedBox(height: 10),
      _playBar(
        '连续播报这一栏 ${localTracks.length} 条',
        localTracks,
        note: '这几条用和早上一样的真人音色；下面抓来的县里要闻用系统语音，音色随手机而定。',
      ),
      const SizedBox(height: 12),
      for (final b in LocalBrief.forArea(_region.area)) _briefCard(b, events),

      const SizedBox(height: 22),
      // 本地要闻（联网）
      Row(
        children: [
          Text('本地要闻',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColor.ink)),
          const SizedBox(width: 8),
          if (cached)
            Text(ago.isEmpty ? '缓存' : ago, style: TextStyle(fontSize: 10.5, color: AppColor.sub)),
          const Spacer(),
          if (_feedLoading)
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 1.6, color: AppColor.sub),
            )
          else
            TextButton(
              onPressed: _refreshFeed,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 30),
              ),
              child: Text('联网刷新', style: TextStyle(fontSize: 11.5, color: AppColor.accent)),
            ),
        ],
      ),
      if (feed.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Container(
            padding: const EdgeInsets.all(13),
            decoration: glassDecoration(radius: 12, alpha: 0.35),
            child: Text(
              _feed?.error.isNotEmpty == true
                  ? _feed!.error
                  : '点「联网刷新」从县政府网站取一次，之后没网也能看上一份。',
              style: TextStyle(fontSize: 11, height: 1.65, color: AppColor.sub),
            ),
          ),
        )
      else ...[
        Wrap(
          spacing: 7,
          runSpacing: 7,
          children: [
            for (final f in const ['全部', '要闻', '部门 · 镇村', '公告', '人事 · 招聘'])
              _filterChip(f, _feedFilter == f, () => setState(() {
                    _feedFilter = f;
                    _feedLimit = 8;
                  })),
          ],
        ),
        const SizedBox(height: 10),
        for (final f in shownFeed) _feedRow(f),
        if (feed.length > _feedLimit)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Center(
              child: TextButton(
                onPressed: () => setState(() => _feedLimit += 20),
                child: Text('还有 ${feed.length - _feedLimit} 条，展开',
                    style: TextStyle(fontSize: 11.5, color: AppColor.accent)),
              ),
            ),
          ),
      ],

      const SizedBox(height: 20),
      // 官方渠道
      Text('看原文 · 官方渠道',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColor.ink)),
      const SizedBox(height: 4),
      Text('人事任免这类信息每天都在变，写死在 App 里第二天就不准了。这里直接开官方页面。',
          style: TextStyle(fontSize: 11, color: AppColor.sub, height: 1.6)),
      const SizedBox(height: 10),
      for (final c in kLocalChannels) _channelRow(c),
    ];
  }

  Widget _filterChip(String text, bool on, VoidCallback tap) {
    return GestureDetector(
      onTap: tap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: glassDecoration(
          radius: 7,
          selected: on,
          accent: on ? AppColor.accent.withOpacity(0.8) : null,
          alpha: on ? 0.85 : 0.28,
          flatFill: Colors.transparent,
          flatBorder: AppColor.line,
        ),
        child: Text(text,
            style: TextStyle(fontSize: 11, color: on ? AppColor.accent : AppColor.sub)),
      ),
    );
  }

  Widget _feedRow(FeedItem f) {
    final key = 'f-${f.url}';
    final playing = _playingKey == key;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: glassDecoration(
        radius: 12,
        accent: playing ? AppColor.accent.withOpacity(0.9) : null,
        alpha: 0.7,
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              borderRadius: const BorderRadius.horizontal(left: Radius.circular(12)),
              onTap: () {
                _logSeen(f.title, detail: '${_region.short} · ${f.col} · ${f.date}', tag: '本地 · 官方');
                _open(f.url);
              },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(13, 11, 6, 11),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(f.title,
                        style: TextStyle(fontSize: 12.5, height: 1.5, color: AppColor.ink)),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        _chip(f.col, faint: true),
                        if (f.isPersonnel) ...[
                          const SizedBox(width: 5),
                          _chip('人事', faint: false),
                        ],
                        if (f.date.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Text(f.date,
                              style: TextStyle(fontSize: 10, color: AppColor.sub)),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          InkWell(
            onTap: () => _playOne(_Track(
              key: key,
              label: f.title,
              text: '${f.col}资讯。${f.title}',
              onPlayed: () => _logSeen(f.title,
                  detail: '${_region.short} · ${f.col} · ${f.date}', tag: '本地 · 官方'),
            )),
            child: Padding(
              padding: const EdgeInsets.all(11),
              child: Icon(
                playing ? Icons.graphic_eq : Icons.play_circle_outline,
                size: 20,
                color: playing ? AppColor.accent : AppColor.sub,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _briefCard(LocalBrief b, Map<String, JEvent> events) {
    final title = '${_region.short}·${b.title}';
    final open = _expanded == title;
    final key = 'l-${b.key}';
    final playing = _playingKey == key;
    final heard = events[title]?.spoken == true;

    return GlassCard(
      onTap: () {
        setState(() => _expanded = open ? null : title);
        if (!open) _logSeen(title, detail: b.steps.first, tag: '本地 · ${b.topic}');
      },
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(13),
      radius: 14,
      blur: false,
      accent: playing ? AppColor.accent.withOpacity(0.9) : null,
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _chip(b.topic),
                const Spacer(),
                if (heard)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(Icons.hearing, size: 14, color: AppColor.ok),
                  ),
                InkWell(
                  onTap: () => _playOne(_Track(
                    key: key,
                    label: b.title,
                    sample: localSampleKey(b),
                    text: '${b.title}。${b.spoken}',
                    onPlayed: () => _logSeen(title, detail: b.steps.first, tag: '本地 · ${b.topic}'),
                  )),
                  borderRadius: BorderRadius.circular(20),
                  child: Padding(
                    padding: const EdgeInsets.all(5),
                    child: Icon(
                      playing ? Icons.graphic_eq : Icons.play_circle_outline,
                      size: 20,
                      color: playing ? AppColor.accent : AppColor.sub,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(b.title,
                style: TextStyle(fontSize: 14, height: 1.45, color: AppColor.ink)),
            const SizedBox(height: 6),
            Text(
              open ? b.spoken : b.steps.first,
              maxLines: open ? 30 : 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, height: 1.7, color: AppColor.sub),
            ),
            if (open) ...[
              const SizedBox(height: 10),
              for (final s in b.steps)
                Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('·', style: TextStyle(fontSize: 11.5, color: AppColor.accent)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(s,
                            style: TextStyle(fontSize: 11.5, height: 1.6, color: AppColor.sub)),
                      ),
                    ],
                  ),
                ),
            ],
            if (!open)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('展开看带什么、去哪办',
                    style: TextStyle(fontSize: 10.5, color: AppColor.sub)),
              ),
          ],
        ),
    );
  }

  Widget _channelRow(LocalChannel c) {
    return GlassCard(
      onTap: () => _open(c.url),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      radius: 12,
      blur: false,
      child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.name, style: TextStyle(fontSize: 12.5, color: AppColor.ink)),
                  const SizedBox(height: 3),
                  Text(c.desc, style: TextStyle(fontSize: 10.5, color: AppColor.sub)),
                ],
              ),
            ),
            Icon(Icons.open_in_new, size: 15, color: AppColor.sub),
          ],
        ),
    );
  }

  // ---------------------------------------------------------------- 全部
  List<Widget> _allSection(Map<String, JEvent> events) {
    final now = DateTime.now();

    // 没联网拿到东西时，仍然把内置那 20 条铺出来当示例，不然这一栏是空的
    if (_heads.isEmpty) {
      return [
        _statusBar(),
        const SizedBox(height: 12),
        Text('库里这 ${kNews.length} 条是内置示例，用来把「按画像挑新闻」整条链路跑通。',
            style: TextStyle(fontSize: 11.5, color: AppColor.sub, height: 1.6)),
        const SizedBox(height: 12),
        _playBar('连续播报全部 ${kNews.length} 条', _allTracks),
        const SizedBox(height: 14),
        for (final n in kNews) _card(n, featured: false, ev: events[n.title]),
      ];
    }

    final list = _allList;
    final shown = list.take(_allLimit).toList();

    return [
      _statusBar(),
      const SizedBox(height: 12),
      Wrap(
        spacing: 7,
        runSpacing: 7,
        children: [
          for (final c in NewsEngine.channels)
            _chanChip(c, c == '全部' ? _heads.length : _countOf(c)),
        ],
      ),
      const SizedBox(height: 9),
      Text('按时间倒序，新的在上面。这一栏不按你的喜好排，按发生顺序排。',
          style: TextStyle(fontSize: 10.5, color: AppColor.sub, height: 1.5)),
      const SizedBox(height: 12),
      _playBar('连续播报「$_chanFilter」${list.length} 条', _allTracks),
      const SizedBox(height: 14),
      if (list.isEmpty)
        Container(
          padding: const EdgeInsets.all(13),
          decoration: glassDecoration(radius: 12, alpha: 0.35),
          child: Text('这一类现在还没有条目，换个分类看看，或者点「刷新」拉一次。',
              style: TextStyle(fontSize: 11, height: 1.65, color: AppColor.sub)),
        )
      else ...[
        for (var i = 0; i < shown.length; i++)
          _headlineCard(shown[i],
              index: i + 1, featured: false, ev: events[shown[i].title], now: now),
        if (list.length > _allLimit)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Center(
              child: TextButton(
                onPressed: () => setState(() => _allLimit += 30),
                child: Text('还有 ${list.length - _allLimit} 条，展开',
                    style: TextStyle(fontSize: 11.5, color: AppColor.accent)),
              ),
            ),
          ),
      ],
    ];
  }

  int _countOf(String chan) => _heads.where((h) => h.channel == chan).length;


  // ---------------------------------------------------------------- 卡片
  Widget _card(NewsItem n, {int? index, required bool featured, JEvent? ev}) {
    final open = _expanded == n.title;
    final playing = _playingKey == 'n${kNews.indexOf(n)}';
    final heard = ev?.spoken == true;

    return GlassCard(
      onTap: () {
        setState(() => _expanded = open ? null : n.title);
        if (!open) _logSeen(n.title, detail: n.summary, tag: '${n.topic} · ${n.source}');
      },
      margin: const EdgeInsets.only(bottom: 10),
      padding: EdgeInsets.all(featured ? 15 : 12),
      radius: featured ? 18 : 14,
      featured: featured,
      blur: featured,
      accent: playing ? AppColor.accent.withOpacity(0.9) : null,
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (index != null) ...[
                  Text(
                    index.toString().padLeft(2, '0'),
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColor.accent,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                _chip(n.topic),
                const SizedBox(width: 6),
                _chip(n.tag, faint: true),
                const Spacer(),
                if (heard)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(Icons.hearing, size: 14, color: AppColor.ok),
                  ),
                if (ev != null && !heard)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(Icons.visibility_outlined, size: 14, color: AppColor.sub),
                  ),
                InkWell(
                  onTap: () => _playOne(_Track(
                    key: 'n${kNews.indexOf(n)}',
                    label: n.title,
                    sample: newsSampleKey(n),
                    text: '${n.title}。${n.summary}',
                    onPlayed: () {
                      _logSeen(n.title, detail: n.summary, tag: '${n.topic} · ${n.source}');
                      _markSpoken(n.title);
                    },
                  )),
                  borderRadius: BorderRadius.circular(20),
                  child: Padding(
                    padding: const EdgeInsets.all(5),
                    child: Icon(
                      playing ? Icons.graphic_eq : Icons.play_circle_outline,
                      size: 21,
                      color: playing ? AppColor.accent : AppColor.sub,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 9),
            Text(
              n.title,
              style: TextStyle(
                fontSize: featured ? 16 : 14,
                height: 1.45,
                fontWeight: featured ? FontWeight.w500 : FontWeight.w400,
                color: AppColor.ink,
              ),
            ),
            const SizedBox(height: 7),
            Text(
              n.summary,
              maxLines: open ? 20 : (featured ? 3 : 2),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: featured ? 12.5 : 11.5,
                height: 1.7,
                color: AppColor.sub,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(n.source, style: TextStyle(fontSize: 10.5, color: AppColor.sub)),
                const Spacer(),
                if (open && playing)
                  Text('正在朗读…', style: TextStyle(fontSize: 10.5, color: AppColor.accent))
                else if (!open)
                  Text('展开', style: TextStyle(fontSize: 10.5, color: AppColor.sub)),
              ],
            ),
          ],
        ),
    );
  }

  Widget _chip(String text, {bool faint = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: glassDecoration(
        radius: 6,
        alpha: faint ? 0.16 : 0.55,
        accent: faint ? null : AppColor.accent.withOpacity(0.42),
        flatFill: faint ? Colors.transparent : AppColor.accentSoft,
        flatBorder: faint ? AppColor.line : Colors.transparent,
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          color: faint ? AppColor.sub : AppColor.accent,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  Widget _note() {
    return GlassCard(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(13),
      radius: 12,
      blur: false,
      child: Text(
        '新闻来自新浪财经、新浪科技、IT之家 三个公开源，只取标题、一句话摘要和原文链接，'
        '点「看原文」回原站看全文，本机不转载正文。\n'
        '联网时机：5:00-19:00 之间每隔 5 小时拿一次，8:30 换台时补一次，'
        '19:00 之后和夜里不联网。拿到的内容存在本机，不上传任何东西。\n'
        '「本地」栏的县里要闻来自南陵县政府网站，点「联网刷新」才会去取。',
        style: TextStyle(fontSize: 11, height: 1.65, color: AppColor.sub),
      ),
    );
  }

  String _dateLabel(DateTime d) {
    const w = ['一', '二', '三', '四', '五', '六', '日'];
    return '${d.month} 月 ${d.day} 日 · 周${w[d.weekday - 1]}';
  }
}
