import 'package:flutter/material.dart';

import 'core.dart';
import 'update.dart';

/// 启动时的静默检查：只有真有新版才弹窗，其余情况一声不响。
///
/// 调用方要自己保证「不是刚开机要进晨间流程」——早上七点弹更新提示
/// 比漏响还讨人厌。
Future<void> checkUpdateOnLaunch(BuildContext context) async {
  final r = await UpdateChecker.checkOnLaunch();
  if (r.status != UpdateStatus.hasUpdate || r.info == null) return;
  if (!context.mounted) return;
  await showUpdateDialog(context, r);
}

/// 「我的 → 版本」点进来的手动检查：必须有明确回话，不能点了没反应。
Future<void> checkUpdateManually(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(
    const SnackBar(content: Text('正在检查更新…'), duration: Duration(seconds: 2)),
  );
  final r = await UpdateChecker.checkNow();
  if (!context.mounted) return;
  messenger.hideCurrentSnackBar();

  switch (r.status) {
    case UpdateStatus.failed:
      messenger.showSnackBar(SnackBar(
        content: Text('查不到更新，可能是网络或 GitHub 访问不稳（当前 v${r.current}）'),
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: '打开发布页',
          onPressed: () => Bridge.openUrl(UpdateChecker.releasesPage),
        ),
      ));
    case UpdateStatus.upToDate:
      messenger.showSnackBar(SnackBar(
        content: Text('已是最新版本 v${r.current}'),
        duration: const Duration(seconds: 3),
      ));
    case UpdateStatus.hasUpdate:
      await showUpdateDialog(context, r, manual: true);
  }
}

/// 更新弹窗。返回 true 表示用户点了「去下载」。
Future<bool> showUpdateDialog(
  BuildContext context,
  UpdateResult r, {
  bool manual = false,
}) async {
  final info = r.info;
  if (info == null) return false;
  final notes = plainReleaseNotes(info.notes);

  final go = await showDialog<bool>(
    context: context,
    // 不让点外面关掉：误触关掉不会记「以后再说」，下次开屏又弹一次，
    // 反而更烦。要关就点「以后再说 / 知道了」，语义清楚。
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      // 真机踩过：用 glassPanel（半透明）会让说明文字和底下页面的字叠在一起，
      // 一片糊。更新说明是要被读的，这里改用不透明的卡片色。
      backgroundColor: AppColor.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: AppColor.glassEdge),
      ),
      title: Text(
        manual ? '有新版本 v${info.version}' : '晨序有新版了 · v${info.version}',
        style: TextStyle(
            fontSize: 17, fontWeight: FontWeight.w500, color: AppColor.ink),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '当前 v${r.current} · 覆盖安装，闹钟和记录都会保留',
            style: TextStyle(fontSize: 12.5, color: AppColor.sub),
          ),
          if (notes.isNotEmpty) ...[
            const SizedBox(height: 12),
            // 说明可能很长，放进一个浅色滚动框：既是「这段能滚」的视觉提示，
            // 也避免文字被硬切在半行上（真机上看着像渲染错误）。
            Container(
              constraints: const BoxConstraints(maxHeight: 200),
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                color: AppColor.bg.withOpacity(0.6),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColor.line),
              ),
              child: SingleChildScrollView(
                child: Text(
                  notes,
                  style: TextStyle(
                      fontSize: 12.5, height: 1.65, color: AppColor.sub),
                ),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Text(
            '点「去下载」→ 浏览器里下完点安装 → 系统问「是否允许安装」时选允许。'
            '不用卸载旧版，数据不会丢。',
            style: TextStyle(fontSize: 11.5, height: 1.6, color: AppColor.sub),
          ),
        ],
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(manual ? '知道了' : '以后再说',
              style: TextStyle(fontSize: 14, color: AppColor.sub)),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: FilledButton.styleFrom(
            // 跟 App 里其他主按钮一致：底色 ink、字色 bg（深浅主题自动反向）
            backgroundColor: AppColor.ink,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: Text('去下载',
              style: TextStyle(fontSize: 14, color: AppColor.bg)),
        ),
      ],
    ),
  );

  if (go == true) {
    final ok = await Bridge.openUrl(info.downloadUrl);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('打不开浏览器，请手动访问 ${UpdateChecker.releasesPage}'),
      ));
    }
    return true;
  }
  // 只有启动弹窗的「以后再说」才记账；手动查完点「知道了」不算拒绝
  if (go == false && !manual) UpdateChecker.skipVersion(info.version);
  return false;
}

/// Release 说明是 Markdown，弹窗里只留能读的部分：去标题井号、去加粗星号、
/// 去表格分隔行。不做完整渲染——为了一个更新提示引一个 Markdown 库不值得。
String plainReleaseNotes(String raw) {
  final out = <String>[];
  for (final line in raw.split('\n')) {
    var t = line.trimRight();
    if (t.trim().isEmpty) {
      if (out.isNotEmpty && out.last.isNotEmpty) out.add('');
      continue;
    }
    // 表格分隔行 |---|---|
    if (RegExp(r'^\s*\|[\s:\-|]+\|\s*$').hasMatch(t)) continue;
    t = t.replaceFirst(RegExp(r'^#{1,6}\s*'), '');
    t = t.replaceAll('**', '').replaceAll('`', '');
    t = t.replaceFirst(RegExp(r'^[-*]\s+'), '· ');
    out.add(t);
  }
  while (out.isNotEmpty && out.last.isEmpty) {
    out.removeLast();
  }
  return out.join('\n');
}
