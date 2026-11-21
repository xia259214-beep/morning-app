import 'package:flutter/material.dart';

import 'core.dart';

/// 首次启动的「开权限」引导页。
///
/// 存在的理由很朴素：闹钟类 App 在国内 ROM 上叫不醒人，九成不是代码问题，
/// 而是用户没开通知 / 全屏通知 / 电池不限制。把这三项变成一屏可点、可回检的清单，
/// 比在设置里翻五层菜单靠谱得多。
class SetupPage extends StatefulWidget {
  const SetupPage({super.key});

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> with WidgetsBindingObserver {
  bool _exact = false;
  bool _notify = false;
  bool _fsi = false;
  bool _battery = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 从系统设置页返回时会触发，自动复检，用户不用手动点刷新
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final exact = await Bridge.canScheduleExact();
    final notify = await Bridge.hasNotificationPermission();
    final fsi = await Bridge.canUseFsi();
    final battery = await Bridge.isIgnoringBattery();
    if (!mounted) return;
    setState(() {
      _exact = exact;
      _notify = notify;
      _fsi = fsi;
      _battery = battery;
      _loading = false;
    });
  }

  int get _doneCount =>
      [_exact, _notify, _fsi, _battery].where((e) => e).length;

  bool get _allDone => _doneCount == 4;

  Future<void> _jump(String target) async {
    await Bridge.openSettings(target);
    // 系统设置页是另一个进程，返回后靠 resumed 回调复检；这里再补一次，覆盖不回调的机型
    await Future.delayed(const Duration(milliseconds: 800));
    await _refresh();
  }

  Future<void> _askNotification() async {
    final ok = await Bridge.requestPermission('notification');
    if (!ok) await _jump('notification');
    await _refresh();
  }

  void _finish({required bool skipped}) {
    Store.set('setupDone', '1');
    Store.set('setupSkipped', skipped ? '1' : '0');
    Navigator.of(context).pop();
  }

  Future<void> _confirmSkip() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColor.card,
        title: const Text('先跳过？', style: TextStyle(fontSize: 16)),
        content: Text(
          '没有这些权限，闹钟仍然会响，但锁屏时可能只弹一条通知、不亮屏，也可能被系统延后几分钟。\n\n之后可以随时在「我的 → 权限诊断」里补上。',
          style: TextStyle(fontSize: 13, height: 1.6, color: AppColor.sub),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('回去设置'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('仍然跳过'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) _finish(skipped: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
          children: [
            const Text(
              '开始之前',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600, letterSpacing: -0.5),
            ),
            const SizedBox(height: 10),
            Text(
              '国内系统（小米、红米、OPPO、vivo 等）会限制第三方 App 在后台启动和弹窗。'
              '下面四项是「闹钟真能把你叫醒」的前提，逐项点开、回来会自动打勾。',
              style: TextStyle(fontSize: 13, height: 1.7, color: AppColor.sub),
            ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: AppColor.accentSoft,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Icon(
                    _allDone ? Icons.check_circle_outline : Icons.info_outline,
                    size: 18,
                    color: _allDone ? AppColor.ok : AppColor.accent,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _loading
                        ? '正在检查…'
                        : (_allDone ? '四项已就绪，可以开始了' : '已完成 $_doneCount / 4 项'),
                    style: TextStyle(
                      fontSize: 13,
                      color: _allDone ? AppColor.ok : AppColor.accent,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            _row(
              title: '精准闹钟',
              ok: _exact,
              desc: 'Android 12 起需要「闹钟和提醒」权限，否则系统会把它当普通任务，可能晚几分钟。',
              action: '去开启',
              onTap: () => _jump('exact_alarm'),
            ),
            _row(
              title: '通知权限',
              ok: _notify,
              desc: '没有通知，锁屏时就只剩声音，界面上什么都没有。',
              action: '允许通知',
              onTap: _askNotification,
            ),
            _row(
              title: '全屏通知',
              ok: _fsi,
              desc: 'Android 14 起是独立开关。这是安卓官方唯一允许「锁屏直接弹出闹钟页」的通道，关掉等于要你自己去点。',
              action: '去开启',
              onTap: () => _jump('fsi'),
            ),
            _row(
              title: '电池不限制',
              ok: _battery,
              desc: '被系统省电策略管住时，闹钟会被推迟甚至吞掉。选「不限制」后基本不影响续航——闹钟不常驻，只靠系统定时器唤醒。',
              action: '去设置',
              onTap: () => _jump('battery_request'),
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColor.glassCard,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColor.glassEdge),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('小米 / 红米用户还差两步',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 6),
                  Text(
                    '设置 → 应用设置 → 应用管理 → 晨序 → 权限管理 → 其他权限：\n'
                    '· 后台弹出界面：允许\n'
                    '· 锁屏显示：允许\n'
                    '另外在「应用设置 → 自启动」里允许晨序自启。',
                    style: TextStyle(fontSize: 12, height: 1.7, color: AppColor.sub),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () => _jump('app_details'),
                    child: const Text('打开应用详情页', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
      // 主按钮常驻底部：平板上这一页很长，放进列表里会被滚出视野
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          // 底部留 18：真机上「先跳过」原来紧贴手势条，手指点下去会被
          // 系统的上滑手势吃掉，看着有按钮却点不动。
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
          decoration: BoxDecoration(
            color: AppColor.bg,
            border: Border(top: BorderSide(color: AppColor.glassEdge)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: double.infinity,
                height: 50,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColor.ink,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: () => _allDone ? _finish(skipped: false) : _confirmSkip(),
                  child: Text(_allDone ? '四项已就绪，开始使用' : '先去设置（还差 ${4 - _doneCount} 项）'),
                ),
              ),
              TextButton(
                onPressed: _confirmSkip,
                child: Text('先跳过，稍后再说',
                    style: TextStyle(fontSize: 12, color: AppColor.sub)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row({
    required String title,
    required bool ok,
    required String desc,
    required String action,
    required VoidCallback onTap,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColor.glassCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ok ? AppColor.line : AppColor.accentSoft, width: ok ? 1 : 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                ok ? Icons.check_circle : Icons.radio_button_unchecked,
                size: 18,
                color: ok ? AppColor.ok : AppColor.accent,
              ),
              const SizedBox(width: 8),
              Text(title,
                  style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500)),
              const Spacer(),
              if (!ok)
                TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: onTap,
                  child: Text(action, style: const TextStyle(fontSize: 12.5)),
                )
              else
                Text('已开启',
                    style: TextStyle(fontSize: 12, color: AppColor.ok)),
            ],
          ),
          const SizedBox(height: 6),
          Text(desc,
              style: TextStyle(fontSize: 12, height: 1.6, color: AppColor.sub)),
        ],
      ),
    );
  }
}
