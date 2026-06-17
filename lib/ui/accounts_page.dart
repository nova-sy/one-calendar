import 'package:flutter/material.dart';

import '../core/i18n/locale_controller.dart';
import '../core/models/models.dart';
import '../core/service/calendar_sync_service.dart';
import 'revealable_secret_field.dart';

class AccountsPage extends StatefulWidget {
  final CalendarSyncService service;
  const AccountsPage({super.key, required this.service});

  @override
  State<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends State<AccountsPage> {
  CalendarSyncService get service => widget.service;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (service.feishuAuthorized) service.loadFeishuCalendars();
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final sources = service.configuration.sources;
        return Scaffold(
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _openEditor(null),
            icon: const Icon(Icons.add),
            label: Text(s.addAccount),
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(s.accountsTitle,
                      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
                ),
                if (sources.isEmpty)
                  Text(s.noAccounts, style: const TextStyle(color: Colors.grey))
                else
                  for (final src in sources) _accountCard(src, s),
                const SizedBox(height: 70),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _accountCard(CalendarSource src, dynamic s) {
    final result = service.sourceTestResults[src.id];
    return Container(
      width: 660,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.black.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          Icon(
            src.kind == CalendarSourceKind.dingtalk
                ? Icons.calendar_month_outlined
                : Icons.video_camera_front_outlined,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Text(src.displayLabel,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                  const SizedBox(width: 8),
                  Chip(
                    label: Text(s.sourceName(src.kind), style: const TextStyle(fontSize: 11)),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                  ),
                ]),
                const SizedBox(height: 2),
                Text(
                  '${src.username.isEmpty ? '—' : src.username}  ·  ${src.isEnabled ? s.accountEnabled : s.accountDisabled}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                if (result != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(children: [
                      _badge('CalDAV', result.caldav.ok),
                      const SizedBox(width: 10),
                      _badge('Feishu', result.feishu.ok),
                    ]),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: s.test,
            icon: const Icon(Icons.wifi_tethering, size: 20),
            onPressed: () => service.testSource(src, null),
          ),
          IconButton(
            tooltip: s.edit,
            icon: const Icon(Icons.edit, size: 20),
            onPressed: () => _openEditor(src),
          ),
          IconButton(
            tooltip: s.delete,
            icon: const Icon(Icons.delete_outline, size: 20),
            onPressed: () => _confirmDelete(src, s),
          ),
        ],
      ),
    );
  }

  Widget _badge(String label, bool ok) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(ok ? Icons.check_circle : Icons.cancel, size: 13, color: ok ? Colors.green : Colors.red),
        const SizedBox(width: 3),
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ]);

  Future<void> _confirmDelete(CalendarSource src, dynamic s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.deleteAccountTitle),
        content: Text(s.deleteAccountConfirm(src.displayLabel)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(s.delete)),
        ],
      ),
    );
    if (ok == true) await service.deleteSource(src.id);
  }

  Future<void> _openEditor(CalendarSource? existing) async {
    // Adding a new account requires Feishu to be authorized first.
    if (existing == null) {
      await service.refreshFeishuAuthState();
      if (!service.feishuAuthorized) {
        if (mounted) await _promptBindFeishu();
        return;
      }
    }
    if (service.feishuAuthorized) await service.loadFeishuCalendars();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AccountEditorDialog(service: service, existing: existing),
    );
  }

  Future<void> _promptBindFeishu() async {
    final s = context.strings;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.cloud_off_outlined),
        title: Text(s.feishuRequiredTitle),
        content: Text(s.feishuRequiredMessage),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(s.ok)),
        ],
      ),
    );
  }
}

class AccountEditorDialog extends StatefulWidget {
  final CalendarSyncService service;
  final CalendarSource? existing;
  const AccountEditorDialog({super.key, required this.service, this.existing});

  @override
  State<AccountEditorDialog> createState() => _AccountEditorDialogState();
}

class _AccountEditorDialogState extends State<AccountEditorDialog> {
  late CalendarSourceKind _kind;
  final _label = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  String _calendarId = '';
  bool _enabled = false;
  String? _error;
  bool _busy = false;

  bool get _isNew => widget.existing == null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _kind = e?.kind ?? CalendarSourceKind.dingtalk;
    _label.text = e?.label ?? '';
    _username.text = e?.username ?? '';
    _calendarId = e?.feishuCalendarId ?? '';
    _enabled = e?.isEnabled ?? false;
    if (e != null) {
      widget.service.storedPasswordFor(e).then((pw) {
        if (mounted) setState(() => _password.text = pw);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final cals = widget.service.availableCalendars;
    return AlertDialog(
      title: Text(_isNew ? s.newAccount : s.editAccount),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_isNew)
                DropdownButtonFormField<CalendarSourceKind>(
                  initialValue: _kind,
                  decoration: InputDecoration(
                      labelText: s.accountType, border: const OutlineInputBorder(), isDense: true),
                  items: CalendarSourceKind.values
                      .map((k) => DropdownMenuItem(value: k, child: Text(s.sourceName(k))))
                      .toList(),
                  onChanged: (v) => setState(() => _kind = v ?? CalendarSourceKind.dingtalk),
                ),
              const SizedBox(height: 10),
              TextField(
                controller: _label,
                decoration: InputDecoration(
                    labelText: s.accountLabel,
                    hintText: s.accountLabelHint,
                    border: const OutlineInputBorder(),
                    isDense: true),
              ),
              const SizedBox(height: 6),
              Text(s.sourceSetupHint(_kind),
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
              const SizedBox(height: 10),
              TextField(
                controller: _username,
                decoration: InputDecoration(
                    labelText: s.caldavUsername, border: const OutlineInputBorder(), isDense: true),
              ),
              const SizedBox(height: 10),
              RevealableSecretField(label: s.caldavPassword, controller: _password),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: _calendarId,
                decoration: InputDecoration(
                    labelText: s.targetCalendar, border: const OutlineInputBorder(), isDense: true),
                items: [
                  DropdownMenuItem(value: '', child: Text(s.notSelected)),
                  if (_calendarId.isNotEmpty && !cals.any((c) => c.id == _calendarId))
                    DropdownMenuItem(value: _calendarId, child: Text(_calendarId)),
                  ...cals.map((c) => DropdownMenuItem(value: c.id, child: Text(c.summary))),
                ],
                onChanged: (v) => setState(() => _calendarId = v ?? ''),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Switch(value: _enabled, onChanged: (v) => setState(() => _enabled = v)),
                Text(s.enabled),
              ]),
              if (_error != null)
                Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(s.cancel)),
        FilledButton(onPressed: _busy ? null : _save, child: Text(s.save)),
      ],
    );
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final base = widget.existing ??
        CalendarSource.create(kind: _kind);
    final source = base.copyWith(
      label: _label.text,
      username: _username.text,
      feishuCalendarId: _calendarId,
      isEnabled: _enabled,
    );
    try {
      await widget.service.saveSource(source,
          password: _password.text.isEmpty ? null : _password.text);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }
}
