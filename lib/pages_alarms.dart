import 'package:flutter/material.dart';

import 'core.dart';

class AlarmsPage extends StatefulWidget {
  const AlarmsPage({super.key});

  @override
  State<AlarmsPage> createState() => _AlarmsPageState();
}

class _AlarmsPageState extends State<AlarmsPage> {
  Future<void> _add() async {
    final next = Store.alarms.isEmpty
        ? 1
        : Store.alarms.map((e) => e.id).reduce((a, b) => a > b ? a : b) + 1;
    final alarm = Alarm(id: next, hour: 6, minute: 30, label: '晨间唤醒', days: [1, 2, 3, 4, 5]);
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => AlarmEditPage(alarm: alarm)));
    if (mounted) setState(() {});
  }

  Future<void> _edit(Alarm a) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => AlarmEditPage(alarm: a)));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 28),
        children: [
          Row(
            children: [
              Text('闹钟',
                  style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w300,
                      color: AppColor.bgInk)),
              const Spacer(),
              IconButton(
                onPressed: _add,
                icon: const Icon(Icons.add, size: 26),
                tooltip: '新建闹钟',
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '响铃在本机运行，断网、锁屏、重启后依然有效',
            style: TextStyle(fontSize: 12, color: AppColor.sub),
          ),
          const SizedBox(height: 18),
          for (final a in Store.alarms) ...[
            _AlarmCard(
              alarm: a,
              onTap: () => _edit(a),
              onToggle: (v) async {
                setState(() => a.enabled = v);
                await Store.saveAlarms();
              },
            ),
            const SizedBox(height: 12),
          ],
          if (Store.alarms.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text('还没有闹钟，点右上角 + 新建', style: TextStyle(color: AppColor.sub)),
              ),
            ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColor.accentSoft.withOpacity(0.5),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              '提示：部分国产系统（如 MIUI / EMUI / ColorOS）需要手动允许「自启动」「后台运行」并关闭电池优化，否则可能延迟响铃。可在「我的 → 权限诊断」查看系统设置入口。',
              style: TextStyle(
                  fontSize: 11.5,
                  height: 1.6,
                  color: AppColor.softInk),
            ),
          ),
        ],
      ),
    );
  }
}

class _AlarmCard extends StatelessWidget {
  final Alarm alarm;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggle;

  const _AlarmCard({required this.alarm, required this.onTap, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final on = alarm.enabled;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 14, 10, 14),
        decoration: BoxDecoration(
          color: on ? AppColor.card : const Color(0xFFF6F2EA),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColor.glassEdge),
        ),
        child: Row(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  alarm.timeText,
                  style: TextStyle(
                    fontSize: 34,
                    height: 1.1,
                    fontWeight: FontWeight.w300,
                    letterSpacing: -1,
                    color: on ? AppColor.ink : AppColor.sub,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${alarm.label} · ${alarm.repeatText}',
                  style: TextStyle(fontSize: 12, color: AppColor.sub),
                ),
                const SizedBox(height: 3),
                Text(
                  '贪睡 ${alarm.snoozeMinutes} 分钟 · 答题 ${alarm.quizCount} 道',
                  style: TextStyle(fontSize: 11, color: AppColor.sub),
                ),
              ],
            ),
            const Spacer(),
            Switch(
              value: on,
              activeColor: AppColor.accent,
              onChanged: onToggle,
            ),
          ],
        ),
      ),
    );
  }
}

class AlarmEditPage extends StatefulWidget {
  final Alarm alarm;

  const AlarmEditPage({super.key, required this.alarm});

  @override
  State<AlarmEditPage> createState() => _AlarmEditPageState();
}

class _AlarmEditPageState extends State<AlarmEditPage> {
  late int _hour = widget.alarm.hour;
  late int _minute = widget.alarm.minute;
  late List<int> _days = [...widget.alarm.days];
  late int _snooze = widget.alarm.snoozeMinutes;
  late int _quiz = widget.alarm.quizCount;
  late TextEditingController _label = TextEditingController(text: widget.alarm.label);
  bool _isNew = false;

  @override
  void initState() {
    super.initState();
    _isNew = !Store.alarms.any((e) => e.id == widget.alarm.id);
  }

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _hour, minute: _minute),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: Theme.of(ctx).colorScheme.copyWith(primary: AppColor.accent),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      setState(() {
        _hour = picked.hour;
        _minute = picked.minute;
      });
    }
  }

  Future<void> _save() async {
    widget.alarm
      ..hour = _hour
      ..minute = _minute
      ..days = _days
      ..label = _label.text.trim().isEmpty ? '晨间唤醒' : _label.text.trim()
      ..snoozeMinutes = _snooze
      ..quizCount = _quiz
      ..enabled = true;

    if (_isNew) Store.alarms.add(widget.alarm);
    await Store.saveAlarms();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    Store.alarms.removeWhere((e) => e.id == widget.alarm.id);
    await Store.saveAlarms();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    const days = ['一', '二', '三', '四', '五', '六', '日'];
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(_isNew ? '新建闹钟' : '编辑闹钟',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
        actions: [
          if (!_isNew)
            TextButton(
              onPressed: _delete,
              child: const Text('删除', style: TextStyle(color: Color(0xFFB4543F))),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(22, 8, 22, 28),
        children: [
          // 时间选择
          GestureDetector(
            onTap: _pickTime,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 26),
              decoration: BoxDecoration(
                color: AppColor.glassCard,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColor.glassEdge),
              ),
              child: Center(
                child: Text(
                  '${two(_hour)}:${two(_minute)}',
                  style: const TextStyle(
                    fontSize: 64,
                    fontWeight: FontWeight.w200,
                    letterSpacing: -2,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text('点击时间可修改', style: TextStyle(fontSize: 11, color: AppColor.sub)),
          ),
          const SizedBox(height: 22),

          const _Label('重复'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _chip('仅一次', _days.isEmpty, () => setState(() => _days = [])),
              for (var i = 1; i <= 7; i++)
                _chip('周${days[i - 1]}', _days.contains(i), () {
                  setState(() {
                    if (_days.contains(i)) {
                      _days.remove(i);
                    } else {
                      _days.add(i);
                    }
                  });
                }),
            ],
          ),
          const SizedBox(height: 22),

          const _Label('标签'),
          const SizedBox(height: 8),
          TextField(
            controller: _label,
            decoration: InputDecoration(
              filled: true,
              fillColor: AppColor.card,
              hintText: '例如：晨间启动',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: AppColor.line),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: AppColor.line),
              ),
            ),
          ),
          const SizedBox(height: 22),

          const _Label('贪睡时长'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              for (final m in [3, 5, 10, 15])
                _chip('$m 分钟', _snooze == m, () => setState(() => _snooze = m)),
            ],
          ),
          const SizedBox(height: 22),

          const _Label('晨间答题数量'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              for (final q in [1, 3, 5])
                _chip('$q 道', _quiz == q, () => setState(() => _quiz = q)),
            ],
          ),

          const SizedBox(height: 34),
          SizedBox(
            height: 52,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColor.ink,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              onPressed: _save,
              child: const Text('保存'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String text, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? AppColor.ink : AppColor.card,
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: selected ? AppColor.ink : AppColor.line),
        ),
        child: Text(
          text,
          style: TextStyle(fontSize: 12.5, color: selected ? Colors.white : AppColor.ink),
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(text, style: TextStyle(fontSize: 12, color: AppColor.sub, letterSpacing: 1));
  }
}
