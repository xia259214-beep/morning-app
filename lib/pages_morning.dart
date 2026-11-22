import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'core.dart';
import 'focus.dart';
import 'journal.dart';
import 'morning_news.dart';
import 'profile.dart';
import 'quiz_pane.dart';

/// 「晨间」标签页：查看今日进度，并手动发起一次晨间流程
class MorningTabPage extends StatefulWidget {
  final VoidCallback onStartMorning;

  const MorningTabPage({super.key, required this.onStartMorning});

  @override
  State<MorningTabPage> createState() => _MorningTabPageState();
}

class _MorningTabPageState extends State<MorningTabPage> {
  @override
  Widget build(BuildContext context) {
    final today = Store.todayRecord();
    final done = today?.completed == true;

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 28),
        children: [
          const Text('晨间流程', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w300)),
          const SizedBox(height: 6),
          Text(
            '唤醒 → 答题 → 播报 → 打卡',
            style: TextStyle(fontSize: 12, color: AppColor.sub, letterSpacing: 1),
          ),
          const SizedBox(height: 22),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppColor.glassCard,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: AppColor.glassEdge),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      done ? '今天已完成' : '今天还未开始',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w400,
                        color: done ? AppColor.ok : AppColor.ink,
                      ),
                    ),
                    const Spacer(),
                    if (done)
                      Icon(Icons.check_circle, color: AppColor.ok, size: 20),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  done
                      ? '完成于 ${Store.todayRecord()!.wokeAt > 0 ? _time(Store.todayRecord()!.wokeAt) : '—'}'
                      : '闹钟响起后会自动进入，也可以现在手动开始',
                  style: TextStyle(fontSize: 12, color: AppColor.sub),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColor.ink,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    onPressed: widget.onStartMorning,
                    child: Text(done ? '再看一遍流程' : '开始晨间流程'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _block(
            '① 唤醒',
            '闹钟以系统级精准闹钟触发，全屏响铃页可直接「起床」进入流程，或「贪睡」稍后再响。',
            Icons.alarm,
          ),
          _block(
            '② 答题',
            '${Store.i('quizCount', 10)} 道题：单选、多选、判断混着出，答错立刻给解释；偏好题没有对错，只记下你的选择。答得越多，我在你走过的那条路上问得越细。',
            Icons.quiz_outlined,
          ),
          _block(
            '③ 播报',
            '本机语音朗读今日几条新闻摘要，完全离线；不想听可以一键跳过。',
            Icons.volume_up_outlined,
          ),
          _block(
            '④ 打卡',
            '调用系统相机拍一张当下的照片存进记录，作为「真的起床了」的凭证。',
            Icons.photo_camera_outlined,
          ),
        ],
      ),
    );
  }

  String _time(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return hhmm(d);
  }

  Widget _block(String title, String desc, IconData icon) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColor.glassCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColor.glassEdge),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: AppColor.accent),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                const SizedBox(height: 5),
                Text(desc, style: TextStyle(fontSize: 12, height: 1.6, color: AppColor.sub)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 晨间流程主页面：唤醒 → 答题 → 播报 → 打卡 → 完成
///
/// v1.5.0 起这个页面是**锁着的**：流程没走完，返回键、手势、右上角都出不去。
/// 起因很直接——以前点完「起床」按一下 Home 键就回桌面了，那个闹钟等于被关掉，
/// 而「必须出门打卡才能结束」根本没有发生。
class MorningFlowPage extends StatefulWidget {
  final int alarmId;

  /// 是否锁死出口。
  ///
  /// 由闹钟 / 追赶拉起的那一次必须是 true——那是「起床」这个承诺的一部分。
  /// 用户自己在「晨间」页点开看看，绝不能锁：他只是在浏览流程，
  /// 锁住的结果是他连自己的 App 都退不出去，只能杀进程。
  final bool locked;

  /// 是否正开着。追赶闹钟弹回来时用它避免叠出第二层流程页。
  static bool isOpen = false;

  const MorningFlowPage({super.key, required this.alarmId, this.locked = true});

  @override
  State<MorningFlowPage> createState() => _MorningFlowPageState();
}

class _MorningFlowPageState extends State<MorningFlowPage> {
  int _step = 0; // 0 唤醒 1 答题 2 播报 3 打卡 4 完成

  late Profile _profile;

  /// 本轮一共答了几道（跳过不算）。完成页用它报总数，不用题号——
  /// 中途跳题、再来一轮，题号就对不上了。
  int _answeredCount = 0;
  int _correct = 0;

  /// 面板用的题数档位。-1 = 全部。
  int _quizCount = 10;

  List<NewsItem> _news = [];
  int _ni = 0;

  /// 已经往日志里写过的那几条新闻（下标 → 事件）。
  /// 翻回上一条不该重复记账；朗读时还要回头把它标成「听过」。
  final Map<int, JEvent> _newsLog = {};

  bool _speaking = false;
  /// 语音引擎体检结论：init / ready / no_engine / no_chinese / ...
  String _ttsState = 'init';

  String _photo = '';
  bool _checkinLogged = false;
  late MorningRecord _record;

  /// 「我确实拍不了」要按住 3 秒才生效。
  /// 一道随手可点的跳过，等于没有锁；3 秒是让手停一下，不是考验意志。
  Timer? _giveUpTimer;
  bool _holding = false;

  @override
  void initState() {
    super.initState();
    MorningFlowPage.isOpen = true;
    _profile = Profile.load();
    // 按用户设定的题数出题；「够了，先这样」只在题还没答完时才出现，
    // 所以设 3 道就只答 3 道，设 20 道就能中途喊停。
    _quizCount = Store.i('quizCount', widget.alarmId > 0 ? _alarmQuizCount() : 10);
    // 当天固定的三条：优先用真实新闻引擎的缓存（和新闻页「今日」栏同一批），
    // 断网 / 从未刷新过时 MorningNews.pick 内部回落到内置示例，保证离线可用。
    _news = MorningNews.pick(_profile);
    _record = Store.upsertToday(widget.alarmId);
    _record.wokeAt = DateTime.now().millisecondsSinceEpoch;
    _probeTts();
  }

  /// 换到别的设备上，可能根本没有语音引擎或没装中文语音包。
  /// 进页面就体检一次，把结论落到按钮文案上，别让用户点了没反应还不知道为什么。
  Future<void> _probeTts() async {
    final s = await Bridge.ttsStatusAwait();
    if (!mounted) return;
    setState(() => _ttsState = (s['state'] as String?) ?? 'init');
  }

  int _alarmQuizCount() {
    try {
      return Store.alarms.firstWhere((e) => e.id == widget.alarmId).quizCount;
    } catch (_) {
      return Store.i('quizCount', 10);
    }
  }

  @override
  void dispose() {
    MorningFlowPage.isOpen = false;
    _giveUpTimer?.cancel();
    _speakTimer?.cancel();
    Bridge.stopSpeak();
    super.dispose();
  }

  /// 播预生成音频。返回 true 表示「这件事已经处理完了」，调用方别再走系统 TTS。
  ///
  /// 返回 false 只在一种情况下发生：这条新闻没有对应的音频（以后题库/新闻
  /// 会继续加，不能因为漏生成就让这一条变成哑巴）。
  Future<bool> _speakSample(NewsItem n) async {
    final key = newsSampleKey(n);
    if (key.isEmpty) return false;

    setState(() => _speaking = true);
    final r = await Bridge.playSample(key);
    if (!mounted) return true;

    if (r['ok'] != true) {
      setState(() => _speaking = false);
      return false;
    }

    final vol = (r['mediaVolume'] as num?)?.toInt() ?? -1;
    if (vol == 0) {
      setState(() => _speaking = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          duration: Duration(seconds: 6),
          content: Text('媒体音量是 0，播报听不到。把音量键往上按两下，再点一次。'),
        ),
      );
      return true;
    }

    // MediaPlayer 给了真实时长，不用再按字数估
    final ms = (r['duration'] as num?)?.toInt() ?? 0;
    _speakTimer?.cancel();
    _speakTimer = Timer(
      Duration(milliseconds: (ms > 0 ? ms : n.title.length * 230) + 300),
      () {
        if (mounted) setState(() => _speaking = false);
      },
    );

    final logged = _newsLog[_ni];
    if (logged != null) Journal.markSpoken(logged);
    return true;
  }

  Future<void> _speak(NewsItem n) async {
    final text = '${n.title}。${n.summary}';

    // 第一条路：播包里带的真人音色。
    // 系统 TTS 的音色由各机型引擎决定，同一段文字在小米、华为、平板上声音不同；
    // 用户要的是「跟电脑里那个声音差不多」，只有把音频本身带在包里才做得到。
    if (await _speakSample(n)) return;
    if (!mounted) return;

    // 已知本机没有可用引擎，直接给修复入口，不要假装在读
    if (_ttsState != 'ready' && _ttsState != 'init') {
      _showTtsHelp(_ttsState);
      return;
    }
    setState(() => _speaking = true);
    final r = await Bridge.speak(text);
    if (!mounted) return;

    final state = (r['state'] as String?) ?? 'ready';
    if (r['ok'] != true) {
      setState(() {
        _speaking = false;
        _ttsState = state;
      });
      _showTtsHelp(state);
      return;
    }

    // 引擎真的开始读了，才在日志里标成「听过」。
    // 点了按钮但引擎没起来的情况不算——那只是点过，不算听过。
    final logged = _newsLog[_ni];
    if (logged != null) Journal.markSpoken(logged);

    // 引擎正常、但媒体音量是 0：用户就是听不到。直接说清是音量问题，
    // 别让他以为语音又坏了（这一条和「引擎没起来」是两回事）。
    final vol = (r['mediaVolume'] as num?)?.toInt() ?? -1;
    if (vol == 0) {
      setState(() => _speaking = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          duration: Duration(seconds: 6),
          content: Text('媒体音量是 0，播报听不到。把音量键往上按两下，再点一次。'),
        ),
      );
      return;
    }

    if (state == 'init') {
      // 首次调用时引擎还在异步绑定；冷引擎「绑定 + 首句合成」经常要 3~5 秒，
      // 等 2.5 秒会误报成失败，这里放宽到 6 秒。
      final s = await Bridge.ttsStatusAwait(timeoutMs: 6000);
      if (!mounted) return;
      final st = (s['state'] as String?) ?? '';
      if (st != 'ready' && st.isNotEmpty) {
        setState(() {
          _speaking = false;
          _ttsState = st;
        });
        _showTtsHelp(st);
        return;
      }
      if (mounted) setState(() => _ttsState = 'ready');
    }

    // 原生 speak 只是把文本排进引擎队列就返回了，这里按字数估一个播报时长，
    // 让按钮能够显示「正在朗读…」并在读完后自己复位（真机实测约 230ms/字）。
    _speakTimer?.cancel();
    _speakTimer = Timer(Duration(milliseconds: 600 + text.length * 230), () {
      if (mounted) setState(() => _speaking = false);
    });

    // 换设备的头号坑：系统语音引擎第一次被调用时，会弹它自己的隐私协议页
    // （部分机型还会再弹麦克风、电话状态等授权）。用户没点同意，合成根本不会开始。
    // 5 秒还没 onStart 才提示——2 秒太短，会把「首句合成慢」误报成「卡在协议页」。
    Timer(const Duration(seconds: 5), () async {
      if (!mounted || !_speaking) return;
      final s = await Bridge.ttsStatus();
      if (!mounted || s['speaking'] == true || !_speaking) return;
      setState(() => _speaking = false);
      _speakTimer?.cancel();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 10),
          content: const Text(
            '语音引擎还没开始朗读。如果刚才弹出了「系统语音引擎」的协议或授权页，'
            '请点同意后，再点一次「朗读这条」。',
          ),
          action: SnackBarAction(
            label: '重试',
            onPressed: () => _retryTts(),
          ),
        ),
      );
    });
  }

  /// 引擎被系统回收、或绑定时偶发失败时，重建一次通常就好了，不该逼用户杀进程
  Future<void> _retryTts() async {
    final s = await Bridge.retryTts();
    if (!mounted) return;
    final st = (s['state'] as String?) ?? 'init';
    setState(() => _ttsState = st);
    if (st == 'init') {
      final done = await Bridge.ttsStatusAwait(timeoutMs: 6000);
      if (!mounted) return;
      setState(() => _ttsState = (done['state'] as String?) ?? 'init');
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_ttsState == 'ready' ? '语音引擎已就绪，再点一次朗读' : Bridge.ttsStateText(_ttsState)),
        ),
      );
    }
  }

  /// 语音不可用时的说明与修复入口：去系统语音设置换引擎、或直接装语音数据
  void _showTtsHelp(String state) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColor.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('朗读没法出声',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            Text(Bridge.ttsStateText(state),
                style: const TextStyle(fontSize: 13.5, height: 1.7)),
            const SizedBox(height: 8),
            Text(
              '这台设备缺少可用的语音合成引擎或中文语音包。晨间流程里的答题、打卡不受影响，'
              '只有「朗读新闻」这一项需要装好引擎才能出声。',
              style: TextStyle(fontSize: 12, height: 1.75, color: AppColor.sub),
            ),
            const SizedBox(height: 18),
            SizedBox(
              height: 48,
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColor.ink,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: () async {
                  Navigator.of(ctx).pop();
                  await Bridge.openSettings('tts');
                },
                child: const Text('去系统语音设置'),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: TextButton(
                onPressed: () async {
                  Navigator.of(ctx).pop();
                  await _retryTts();
                },
                child: Text('重试一次', style: TextStyle(color: AppColor.accent)),
              ),
            ),
            Center(
              child: TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text('知道了', style: TextStyle(color: AppColor.sub)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _stopSpeak() {
    _speakTimer?.cancel();
    Bridge.stopSpeak();
    if (mounted) setState(() => _speaking = false);
  }

  Timer? _speakTimer;

  Future<void> _takePhoto() async {
    final p = await Bridge.takePhoto();
    if (!mounted) return;
    if (p == null || p.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未获取到照片（可能取消了拍摄或未授予相机权限）')),
      );
      return;
    }
    setState(() => _photo = p);
  }

  /// 落盘今日记录。做成幂等：重复调用只是覆盖同一字段，不会插入新记录。
  Future<void> _commit({required bool checkedIn}) async {
    _record
      ..quizCorrect = _correct
      ..quizTotal = _answeredCount > 0
          ? _answeredCount
          : (_quizCount > 0 ? _quizCount : 0)
      ..newsDone = true
      ..photoPath = _photo
      ..completed = checkedIn;
    await Store.saveRecords();
    Store.set('lastTrigger', DateTime.now().millisecondsSinceEpoch.toString());

    // 打卡只在第一次完成时记一笔。重复进来不该在日志里出现两条。
    if (!_checkinLogged) {
      _checkinLogged = true;
      Journal.add(
        JKind.checkin,
        checkedIn ? '出门打卡' : '没打卡就结束了',
        detail: checkedIn ? '照片已存入记录' : '用了「我确实拍不了」，今天记为未打卡',
        verdict: checkedIn ? 'right' : 'wrong',
      );
    }
    // 流程已经结束：不管打卡还是放弃，追赶都必须停，否则今天还会被拉回来
    await Bridge.cancelChase();
    // 也没有「欠着的流程」了，回 App 时不该再被塞回这里
    Store.set('flowPending', '');
  }

  /// 进入「完成」页：必须先把记录写进去再切页。
  /// v1.1.0 及以前是切页后才在按钮里写，导致完成页读到的还是打卡前的数据，
  /// 真机上刚打完卡却显示「连续 0 天」。
  ///
  /// v1.5.0：没拍照就不算完成。以前 photo 为空也写 completed = true，
  /// 「跳过拍照」的人在日志里是「晨间完成」、连续天数照涨——那条捷径比打卡还划算，
  /// 所以「必须出门打卡才能结束」从来没有真正成立过。
  Future<void> _toDone() async {
    await _commit(checkedIn: _photo.isNotEmpty);
    if (!mounted) return;
    setState(() => _step = 4);
  }

  /// 按住 3 秒才触发：真的拍不了照片时唯一的出口，代价是今天记为未打卡。
  void _startGiveUp() {
    _giveUpTimer?.cancel();
    setState(() => _holding = true);
    _giveUpTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _holding = false);
      _toDone();
    });
  }

  void _cancelGiveUp() {
    _giveUpTimer?.cancel();
    _giveUpTimer = null;
    if (_holding) setState(() => _holding = false);
  }

  /// 「收好，开始今天」：退出整个晨间流程回到首页。
  /// 以前这个按钮绑的是 _finish()，只做了保存、没有真正 pop，
  /// 结果又回到第一步「唤醒」，看着像没结束。
  void _closeFlow() {
    Navigator.of(context).pop();
  }

  /// 流程没走完就不许离开。完成页（_step == 4）才解锁。
  /// 手动打开的流程（widget.locked == false）不设限。
  bool get _locked => widget.locked && _step < 4;

  void _hintLocked() {
    final msg = _step == 3
        ? '拍一张照片就结束了。真的拍不了，长按下面的说明。'
        : '流程还没走完。打卡之后自动解锁。';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 3),
      content: Text(msg),
    ));
  }

  @override
  Widget build(BuildContext context) {
    // 返回键 / 侧滑手势都走这里。canPop=false 时系统不会退页，
    // 回调里只给一句提示，告诉用户为什么退不掉、以及怎么才能退掉。
    return PopScope(
      canPop: !_locked,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _hintLocked();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 8, 6),
                child: Row(
                  children: [
                    _dot(0, '唤醒'),
                    _dot(1, '答题'),
                    _dot(2, '播报'),
                    _dot(3, '打卡'),
                    const Spacer(),
                    // 原来是「关闭」。点了就走，等于整个锁形同虚设。
                    // 现在它是一个状态指示：锁着的时候点它，告诉你还差什么。
                    IconButton(
                      onPressed: _locked
                          ? _hintLocked
                          : () async {
                              await Bridge.stopSpeak();
                              if (!context.mounted) return;
                              Navigator.of(context).pop();
                            },
                      icon: Icon(
                        _locked ? Icons.lock_outline : Icons.lock_open,
                        size: 19,
                        color: _locked ? AppColor.accent : AppColor.ok,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 260),
                  child: _body(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dot(int i, String label) {
    final active = _step >= i;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? AppColor.accent : AppColor.line,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: active ? AppColor.ink : AppColor.sub,
              fontWeight: active ? FontWeight.w500 : FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    switch (_step) {
      case 0:
        return _wakeView();
      case 1:
        return _quizView();
      case 2:
        return _newsView();
      case 3:
        return _photoView();
      default:
        return _doneView();
    }
  }

  // ---------------------------------------------------------------- 唤醒
  Widget _wakeView() {
    final now = DateTime.now();
    return Padding(
      key: const ValueKey('wake'),
      padding: const EdgeInsets.symmetric(horizontal: 26),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            hhmm(now),
            style: const TextStyle(fontSize: 76, fontWeight: FontWeight.w200, letterSpacing: -3),
          ),
          const SizedBox(height: 10),
          Text('早上好，新的一天开始了',
              style: TextStyle(fontSize: 14, color: AppColor.sub, letterSpacing: 1)),
          const SizedBox(height: 48),
          SizedBox(
            width: double.infinity,
            height: 54,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColor.ink,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              ),
              onPressed: () {
                // 整条流水账的第一笔：几点醒的，是靠闹钟还是自己起来的
                Journal.add(JKind.wake, '醒来，开始晨间',
                    detail: widget.alarmId > 0 ? '闹钟响后开始' : '手动开始');
                setState(() => _step = 1);
              },
              child: const Text('我已醒来，开始晨间'),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            '建议先起身、拉开窗帘，再完成接下来的三步',
            style: TextStyle(fontSize: 11.5, color: AppColor.sub),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 答题
  Widget _quizView() {
    // 判分、反馈、跳过、再来一轮都在 QuizPane 里，跟独立答题页共用一套。
    // 以前这段是内嵌的，于是「重新开始」之后就没有第二个地方能答题了。
    return QuizPane(
      count: _quizCount,
      onlyRoots: _quizCount < 0 ? null : DailyFocus.todayRoots,
      finishLabel: '进入新闻播报',
      onFinish: (t) {
        _answeredCount = t.answered;
        _correct = t.correct;
        setState(() => _step = 2);
      },
      onEarlyStop: (t) {
        // 提前结束也要把已答的成绩带走，否则完成页会显示「答题 0 题」
        _answeredCount = t.answered;
        _correct = t.correct;
        setState(() => _step = 2);
      },
      earlyStopLabel: '够了，先去看新闻',
    );
  }

  // ---------------------------------------------------------------- 播报
  /// 进入某条新闻时记一笔。用户「看到」就算数，不必真的点朗读——
  /// 有人只想扫一眼标题，那也算今天接触过这条。
  void _logNewsOnce(NewsItem n) {
    if (_newsLog.containsKey(_ni)) return;
    _newsLog[_ni] = Journal.add(
      JKind.news,
      n.title,
      detail: n.summary,
      tag: '${n.topic} · ${n.source}',
    );
  }

  Widget _newsView() {
    final n = _news[_ni];
    _logNewsOnce(n);
    return Padding(
      key: ValueKey('news$_ni'),
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('播报 ${_ni + 1} / ${_news.length}',
                  style: TextStyle(fontSize: 12, color: AppColor.sub)),
              const Spacer(),
              Text(n.tag, style: TextStyle(fontSize: 11, color: AppColor.accent)),
            ],
          ),
          const SizedBox(height: 18),
          Text(n.title,
              style: const TextStyle(fontSize: 19, height: 1.45, fontWeight: FontWeight.w400)),
          const SizedBox(height: 14),
          Text(n.summary,
              style: const TextStyle(fontSize: 13.5, height: 1.8, color: Color(0xFF4A453D))),
          const SizedBox(height: 14),
          Text('来源：${n.source}',
              style: TextStyle(fontSize: 11, color: AppColor.sub)),
          const SizedBox(height: 22),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _speaking ? null : () => _speak(n),
                icon: Icon(
                    _speaking
                        ? Icons.graphic_eq
                        : (_ttsState == 'ready' || _ttsState == 'init'
                            ? Icons.play_arrow
                            : Icons.volume_off),
                    size: 18,
                    color: _ttsState == 'ready' || _ttsState == 'init'
                        ? AppColor.accent
                        : AppColor.sub),
                label: Text(
                    _speaking
                        ? '正在朗读…'
                        : (_ttsState == 'ready' || _ttsState == 'init'
                            ? '朗读这条'
                            : '语音不可用'),
                    style: TextStyle(
                        color: _ttsState == 'ready' || _ttsState == 'init'
                            ? AppColor.ink
                            : AppColor.sub)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColor.ink,
                  side: BorderSide(color: AppColor.line),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
              ),
              const SizedBox(width: 10),
              TextButton(
                onPressed: _stopSpeak,
                child: Text('停止', style: TextStyle(color: AppColor.sub)),
              ),
            ],
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF6F2EA),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '这三条是按你最近答题时显露的关注方向挑的。仍是内置示例内容，正式版接新闻源后排序逻辑不变。',
              style: TextStyle(fontSize: 11, height: 1.6, color: AppColor.sub),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 50,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: AppColor.line),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    onPressed: () async {
                      await Bridge.stopSpeak();
                      setState(() => _step = 3);
                    },
                    child: Text('跳过播报', style: TextStyle(color: AppColor.sub)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 50,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColor.ink,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    onPressed: () async {
                      await Bridge.stopSpeak();
                      setState(() {
                        _speaking = false;
                        if (_ni + 1 >= _news.length) {
                          _step = 3;
                        } else {
                          _ni++;
                        }
                      });
                    },
                    child: Text(_ni + 1 >= _news.length ? '去打卡' : '下一条'),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 打卡
  Widget _photoView() {
    return Padding(
      key: const ValueKey('photo'),
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('出门打卡', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w300)),
          const SizedBox(height: 8),
          Text(
            '拍一张你眼前的画面——窗外、楼下、地铁，任何能证明「你起床了」的瞬间。',
            style: TextStyle(fontSize: 12.5, height: 1.7, color: AppColor.sub),
          ),
          const SizedBox(height: 20),
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: AppColor.glassCard,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColor.glassEdge),
              ),
              clipBehavior: Clip.antiAlias,
              child: _photo.isEmpty
                  ? Center(
                      child: Icon(Icons.photo_camera_outlined, size: 40, color: AppColor.line),
                    )
                  : Image.file(File(_photo), fit: BoxFit.cover),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 52,
                  child: OutlinedButton.icon(
                    onPressed: _takePhoto,
                    icon: const Icon(Icons.camera_alt_outlined, size: 18),
                    label: Text(_photo.isEmpty ? '拍照' : '重拍'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColor.ink,
                      side: BorderSide(color: AppColor.line),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 52,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColor.ink,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    onPressed: _photo.isEmpty ? null : _toDone,
                    child: const Text('完成打卡'),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // 这里是整个流程唯一的逃生口，所以它必须「贵」一点。
          // 以前是一个随手可点的 TextButton「相机不可用，先跳过」——
          // 点一下就能结束，还照样算完成。
          Center(
            child: GestureDetector(
              onTapDown: (_) => _startGiveUp(),
              onTapUp: (_) => _cancelGiveUp(),
              onTapCancel: _cancelGiveUp,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: _holding ? AppColor.accentSoft : Colors.transparent,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _holding ? '继续按住…' : '真的拍不了？（按住 3 秒）',
                      style: TextStyle(
                        fontSize: 12,
                        color: _holding ? AppColor.accent : AppColor.sub,
                        fontWeight: _holding ? FontWeight.w500 : FontWeight.w400,
                      ),
                    ),
                    if (_holding)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          '这样今天记为未打卡，连续天数归零',
                          style: TextStyle(fontSize: 10.5, color: AppColor.sub),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 完成
  Widget _doneView() {
    final checkedIn = _photo.isNotEmpty;
    return Padding(
      key: const ValueKey('done'),
      padding: const EdgeInsets.symmetric(horizontal: 26),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: checkedIn ? AppColor.accentSoft : AppColor.line.withOpacity(0.35),
            ),
            child: Icon(
              checkedIn ? Icons.check : Icons.remove,
              color: checkedIn ? AppColor.accent : AppColor.sub,
            ),
          ),
          const SizedBox(height: 22),
          Text(
            checkedIn ? '今天的晨间已完成' : '今天没有打卡',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w400),
          ),
          const SizedBox(height: 10),
          Text(
            // 原来写「答题 0 / 10 正确」，分母是全部题数（含 7 道没有对错的偏好题），
            // 分子只数知识题——这个分数没有意义，还会被读成「满分 10 只对了 0 道」。
            // 改成「答了几题 + 知识题对几道」，两个数字各自说得清。
            '答题 $_answeredCount 题 · 对 $_correct 道 · 播报 ${_news.length} 条',
            style: TextStyle(fontSize: 12.5, color: AppColor.sub),
          ),
          const SizedBox(height: 6),
          if (checkedIn)
            Text('连续 ${Store.streak} 天',
                style: TextStyle(fontSize: 12.5, color: AppColor.accent))
          else
            Text('连续天数已归零，明天拍一张就接上了',
                style: TextStyle(fontSize: 12.5, color: AppColor.sub)),
          const SizedBox(height: 40),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColor.ink,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              ),
              onPressed: _closeFlow,
              child: const Text('收好，开始今天'),
            ),
          ),
        ],
      ),
    );
  }
}
