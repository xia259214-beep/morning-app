// ============================================================================
// 数据导入 / 导出页（v1.15.0）
//
// 用户要的是一个「口子」：数据能拿出去、能带回来，换手机不丢。
//
// 这一页只做三件事，别的一概不掺：
//   1. 把本机数据写成一个 JSON 文件（存本地、存网盘、发给自己，都行）；
//   2. 从文件读回来（合并或覆盖，覆盖前自动留一份底）；
//   3. 点错了能撤销。
//
// 「云端」这件事没有服务器参与：系统的文件选择器里本来就列着网盘，
// 用户存到自己的网盘、再从另一台手机打开，路径是通的。App 不上传任何东西，
// 也就不需要账号、不需要联网、不需要存储权限。
// ============================================================================

import 'package:flutter/material.dart';

import 'core.dart';
import 'journal.dart';
import 'portable.dart';
import 'profile.dart';
import 'score.dart';

class DataPortPage extends StatefulWidget {
  const DataPortPage({super.key});

  @override
  State<DataPortPage> createState() => _DataPortPageState();
}

class _DataPortPageState extends State<DataPortPage> {
  bool _busy = false;
  String _status = '';
  bool _statusBad = false;
  bool _hasAutoBackup = false;

  @override
  void initState() {
    super.initState();
    _checkAuto();
  }

  Future<void> _checkAuto() async {
    final b = await Portable.readAutoBackup();
    if (!mounted) return;
    setState(() => _hasAutoBackup = b != null);
  }

  void _say(String text, {bool bad = false}) {
    if (!mounted) return;
    setState(() {
      _status = text;
      _statusBad = bad;
    });
  }

  // ---------------------------------------------------------------- 导出
  Future<void> _export() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final json = await Portable.exportJson();
      final name = Portable.fileName();
      final r = await Bridge.exportData(json, name);
      if (!mounted) return;
      if (r['ok'] == true) {
        _say('已导出「${r['name'] ?? name}」');
      } else if (r['reason'] == 'cancel') {
        _say('已取消');
      } else {
        _say('这台手机没有可用的文件选择器，可以试试「发送到…」', bad: true);
      }
    } catch (e) {
      _say('导出失败：$e', bad: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final json = await Portable.exportJson();
      final r = await Bridge.shareData(json, Portable.fileName());
      if (!mounted) return;
      _say(r['ok'] == true ? '已打开分享，选一个能存文件的地方' : '分享失败，可以改用「导出到文件」',
          bad: r['ok'] != true);
    } catch (e) {
      _say('分享失败：$e', bad: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------------------------------------------------------- 导入
  Future<void> _import() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = await Bridge.importData();
      if (!mounted) return;
      if (r['ok'] != true) {
        if (r['reason'] == 'cancel') {
          _say('已取消');
        } else {
          _say('打不开这台手机的文件选择器，导入需要它的配合', bad: true);
        }
        return;
      }

      final raw = (r['json'] as String?) ?? '';
      BackupBundle bundle;
      try {
        bundle = Portable.parse(raw);
      } on BackupError catch (e) {
        // 坏文件在这里就挡住，一个字节都不写盘
        _say('这份文件用不了：${e.message}', bad: true);
        return;
      }

      final facts = Portable.factsOf(bundle);
      final mode = await _askMode(facts);
      if (mode == null) {
        _say('已取消导入');
        return;
      }

      setState(() => _busy = true);
      final report = await Portable.apply(bundle, replace: mode == 'replace');
      if (!mounted) return;
      setState(() => _hasAutoBackup = report.autoBackupSaved);
      await _showReport(report, facts);
      // 让「我的」页重新读一遍：闹钟数、画像、分数都变了
      if (mounted) setState(() {});
    } catch (e) {
      _say('导入失败：$e', bad: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askMode(BackupFacts f) {
    final when = f.exportedAt == null
        ? '时间未知'
        : '${f.exportedAt!.year}-${f.exportedAt!.month.toString().padLeft(2, '0')}-'
            '${f.exportedAt!.day.toString().padLeft(2, '0')} '
            '${f.exportedAt!.hour.toString().padLeft(2, '0')}:'
            '${f.exportedAt!.minute.toString().padLeft(2, '0')}';
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColor.card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('这份备份里有什么',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
              const SizedBox(height: 6),
              Text('$when 导出 · ${f.version.isEmpty ? '版本未知' : 'v${f.version}'}',
                  style: TextStyle(fontSize: 11, color: AppColor.sub)),
              const SizedBox(height: 14),
              _factRow('闹钟', '${f.alarms} 只'),
              _factRow('打卡记录', '${f.records} 天'),
              _factRow('流水', '${f.journal} 条'),
              _factRow('答过的题', '${f.answered} 道'),
              _factRow('总分', '${f.score}'),
              const SizedBox(height: 16),
              const Text('怎么导？',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
              const SizedBox(height: 6),
              Text(
                '合并：把备份里有、这台手机上还没有的补进来，两边都有的保留手机上的。'
                '换手机第一次导入，选这个。\n'
                '覆盖：用备份整份替换现在的数据。导入前会自动留一份底，能撤销。',
                style: TextStyle(fontSize: 11, height: 1.7, color: AppColor.sub),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColor.ink,
                    foregroundColor: AppColor.onInk,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: () => Navigator.of(ctx).pop('merge'),
                  child: const Text('合并导入'),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColor.sub,
                    side: BorderSide(color: AppColor.line),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: () => Navigator.of(ctx).pop('replace'),
                  child: const Text('覆盖导入'),
                ),
              ),
              Center(
                child: TextButton(
                  onPressed: () => Navigator.of(ctx).pop(null),
                  child: Text('先不导', style: TextStyle(color: AppColor.sub)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showReport(ImportReport r, BackupFacts f) async {
    final lines = <String>[];
    if (r.replaced) {
      lines.add('已用备份覆盖本机数据。');
      lines.add('闹钟 ${f.alarms} 只 · 打卡 ${f.records} 天 · 流水 ${f.journal} 条');
    } else {
      lines.add('合并完成，补进来的是这台手机上原本没有的：');
      lines.add('闹钟 ${r.alarmsAdded} 只 · 打卡 ${r.recordsAdded} 天 · 流水 ${r.journalAdded} 条');
      if (r.cumulativeFromBackup) {
        lines.add('画像、战力和总分整体切到了备份那份（答得更多的一份）。');
      } else {
        lines.add('画像、战力和总分保留本机这份——它们是连着答出来的，不能两边相加。');
      }
    }
    if (r.autoBackupSaved) {
      lines.add('导入前的数据已自动存了一份，点错了可以在这页撤销。');
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColor.card,
        title: const Text('导入完成', style: TextStyle(fontSize: 16)),
        content: Text(lines.join('\n\n'),
            style: const TextStyle(fontSize: 13, height: 1.7)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('好'),
          ),
        ],
      ),
    );
    _say('导入完成');
  }

  Future<void> _undo() async {
    final b = await Portable.readAutoBackup();
    if (b == null) {
      _say('没有找到导入前的备份', bad: true);
      setState(() => _hasAutoBackup = false);
      return;
    }
    final facts = Portable.factsOf(b);
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColor.card,
        title: const Text('撤销到导入前？', style: TextStyle(fontSize: 16)),
        content: Text(
          '会把现在这份数据整份换回导入前的那一份：'
          '闹钟 ${facts.alarms} 只、打卡 ${facts.records} 天、流水 ${facts.journal} 条。',
          style: const TextStyle(fontSize: 13, height: 1.7),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('算了', style: TextStyle(color: AppColor.sub))),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true), child: const Text('撤销')),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _busy = true);
    try {
      await Portable.apply(b, replace: true);
      if (!mounted) return;
      setState(() {});
      _say('已撤销到导入前的数据');
    } catch (e) {
      _say('撤销失败：$e', bad: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------------------------------------------------------- 界面
  @override
  Widget build(BuildContext context) {
    final profile = Profile.load();
    final score = ScoreBook.instance;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text('数据备份与迁移',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 6, 20, 30),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColor.glassCard,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: AppColor.glassEdge),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('现在这台手机上有', style: TextStyle(fontSize: 12.5)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 18,
                  runSpacing: 8,
                  children: [
                    _chip('闹钟', '${Store.alarms.length} 只'),
                    _chip('打卡', '${Store.records.length} 天'),
                    _chip('流水', '${Journal.events.length} 条'),
                    _chip('答过的题', '${profile.answered.length} 道'),
                    _chip('总分', '${score.total}'),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _section('导出'),
          Text(
            '导出就是把上面这些写成一个 JSON 文件。存进「下载」是本地，存进网盘就是云端——'
            '选择器里有的地方都能存，App 不会替你选，也不会上传。',
            style: TextStyle(fontSize: 11, height: 1.7, color: AppColor.sub),
          ),
          const SizedBox(height: 12),
          _action('导出到文件', '自己选存哪儿：本机、网盘、U 盘都行', _export, primary: true),
          _action('发送到…', '直接发到微信 / 网盘 / 邮箱，另一台手机收下即可导入', _share),
          const SizedBox(height: 18),
          _section('导入'),
          Text(
            '选一份之前导出的备份。文件可以存在本机，也可以先在网盘里——'
            '系统的文件选择器会把你登录过的网盘一起列出来。',
            style: TextStyle(fontSize: 11, height: 1.7, color: AppColor.sub),
          ),
          const SizedBox(height: 12),
          _action('从文件导入', '合并到现有数据，或整份覆盖', _import, primary: true),
          if (_hasAutoBackup) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
              decoration: BoxDecoration(
                color: AppColor.glassPanel,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text('上一次导入前的数据还留着，点错了可以换回去。',
                        style: TextStyle(
                            fontSize: 11, height: 1.6, color: AppColor.sub)),
                  ),
                  TextButton(onPressed: _undo, child: const Text('撤销导入')),
                ],
              ),
            ),
          ],
          if (_status.isNotEmpty) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColor.glassPanel,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                    color: _statusBad ? AppColor.line : Colors.transparent),
              ),
              child: Text(_status,
                  style: TextStyle(
                      fontSize: 12,
                      height: 1.6,
                      color: _statusBad ? Colors.redAccent : AppColor.sub)),
            ),
          ],
          if (_busy) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.6),
                ),
                const SizedBox(width: 10),
                Text('正在处理…', style: TextStyle(fontSize: 11.5, color: AppColor.sub)),
              ],
            ),
          ],
          const SizedBox(height: 22),
          Text(
            '说明：照片（打卡那张）不跟着备份走——它是几 MB 的图片，放进 JSON 会把文件撑得没法传。'
            '导入后照片位置会空着，记录本身还在。',
            style: TextStyle(fontSize: 10.5, height: 1.7, color: AppColor.sub),
          ),
        ],
      ),
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text(t,
            style: TextStyle(fontSize: 11.5, color: AppColor.sub, letterSpacing: 1)),
      );

  Widget _chip(String label, String value) => Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(value,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w400)),
          const SizedBox(width: 3),
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(label,
                style: TextStyle(fontSize: 10, color: AppColor.sub)),
          ),
        ],
      );

  Widget _factRow(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          children: [
            Text(label, style: TextStyle(fontSize: 12.5, color: AppColor.sub)),
            const Spacer(),
            Text(value, style: const TextStyle(fontSize: 13)),
          ],
        ),
      );

  Widget _action(String title, String sub, VoidCallback onTap,
      {bool primary = false}) {
    return GestureDetector(
      onTap: _busy ? null : onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: primary ? AppColor.accentSoft : AppColor.glassCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: primary ? Colors.transparent : AppColor.glassEdge),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: primary ? FontWeight.w500 : FontWeight.w400)),
                  const SizedBox(height: 4),
                  Text(sub,
                      style: TextStyle(fontSize: 11, color: AppColor.sub)),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 16, color: AppColor.sub),
          ],
        ),
      ),
    );
  }
}
