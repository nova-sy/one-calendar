import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/models/models.dart';
import '../core/service/calendar_sync_service.dart';
import 'revealable_secret_field.dart';

class SettingsPage extends StatefulWidget {
  final CalendarSyncService service;
  const SettingsPage({super.key, required this.service});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SourceControllers {
  final username = TextEditingController();
  final password = TextEditingController();
  String calendarId = '';
  bool enabled = false;
}

class _SettingsPageState extends State<SettingsPage> {
  final _appId = TextEditingController();
  final _appSecret = TextEditingController();
  final _sources = {
    for (final k in CalendarSourceKind.values) k: _SourceControllers()
  };
  int _interval = 1800;
  int _window = 30;
  bool _busy = false;
  String? _feishuStatus;
  String? _feishuError;

  CalendarSyncService get service => widget.service;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _appId.text = await service.feishuAppId();
    _appSecret.text = await service.feishuAppSecretValue();
    _interval = const [600, 1800, 3600].contains(service.configuration.syncIntervalSeconds)
        ? service.configuration.syncIntervalSeconds
        : 1800;
    _window = const [7, 30, 90].contains(service.configuration.syncWindowDays)
        ? service.configuration.syncWindowDays
        : 30;
    for (final k in CalendarSourceKind.values) {
      final s = service.configuration.sourceFor(k);
      final c = _sources[k]!;
      c.username.text = s?.username ?? '';
      c.calendarId = s?.feishuCalendarId ?? '';
      c.enabled = s?.isEnabled ?? false;
      c.password.text = s == null ? '' : await service.storedPasswordFor(s);
    }
    await service.refreshFeishuAuthState();
    if (service.feishuAuthorized) await service.loadFeishuCalendars();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) => SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _feishuSection(),
            const SizedBox(height: 20),
            for (final k in CalendarSourceKind.values) ...[
              _sourceSection(k),
              const SizedBox(height: 20),
            ],
            _rulesSection(),
          ],
        ),
      ),
    );
  }

  Widget _section(String title, List<Widget> children) => Container(
        width: 640,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      );

  Widget _feishuSection() => _section('Feishu', [
        TextField(
          controller: _appId,
          decoration: const InputDecoration(
              labelText: 'App ID (AK)', border: OutlineInputBorder(), isDense: true),
        ),
        const SizedBox(height: 10),
        RevealableSecretField(label: 'App Secret (SK)', controller: _appSecret),
        const SizedBox(height: 8),
        const SelectableText(
            'Register this redirect URI in your Feishu app:\nhttp://127.0.0.1:17865/callback',
            style: TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 10),
        Row(children: [
          OutlinedButton(onPressed: _saveFeishuApp, child: const Text('Save app')),
          const SizedBox(width: 10),
          FilledButton(onPressed: _busy ? null : _authorize, child: const Text('Authorize')),
          const SizedBox(width: 12),
          Icon(service.feishuAuthorized ? Icons.verified : Icons.gpp_maybe,
              size: 16, color: service.feishuAuthorized ? Colors.green : Colors.grey),
          const SizedBox(width: 4),
          Text(service.feishuAuthorized ? 'Authorized' : 'Not authorized',
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ]),
        if (_feishuStatus != null)
          Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_feishuStatus!, style: const TextStyle(color: Colors.green, fontSize: 12))),
        if (_feishuError != null)
          Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_feishuError!, style: const TextStyle(color: Colors.red, fontSize: 12))),
      ]);

  Widget _sourceSection(CalendarSourceKind kind) {
    final c = _sources[kind]!;
    final result = service.sourceTestResults[kind];
    final items = <DropdownMenuItem<String>>[
      const DropdownMenuItem(value: '', child: Text('Not selected')),
      if (c.calendarId.isNotEmpty &&
          !service.availableCalendars.any((cal) => cal.id == c.calendarId))
        DropdownMenuItem(value: c.calendarId, child: Text(c.calendarId)),
      ...service.availableCalendars
          .map((cal) => DropdownMenuItem(value: cal.id, child: Text(cal.summary))),
    ];
    return _section(kind.displayName, [
      TextField(
        controller: c.username,
        decoration: const InputDecoration(
            labelText: 'CalDAV username', border: OutlineInputBorder(), isDense: true),
      ),
      const SizedBox(height: 10),
      RevealableSecretField(label: 'CalDAV password', controller: c.password),
      const SizedBox(height: 10),
      DropdownButtonFormField<String>(
        initialValue: c.calendarId,
        decoration: const InputDecoration(
            labelText: 'Target calendar', border: OutlineInputBorder(), isDense: true),
        items: items,
        onChanged: (v) => setState(() => c.calendarId = v ?? ''),
      ),
      const SizedBox(height: 8),
      Row(children: [
        Switch(value: c.enabled, onChanged: (v) => setState(() => c.enabled = v)),
        const Text('Enabled'),
      ]),
      Row(children: [
        OutlinedButton(
            onPressed: _busy ? null : () => _testSource(kind), child: const Text('Test')),
        const SizedBox(width: 12),
        if (result != null) ...[
          _badge('CalDAV', result.caldav.ok),
          const SizedBox(width: 10),
          _badge('Feishu', result.feishu.ok),
        ],
      ]),
      const SizedBox(height: 8),
      FilledButton(
          onPressed: () => _saveSource(kind), child: Text('Save ${kind.displayName}')),
    ]);
  }

  Widget _badge(String label, bool ok) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(ok ? Icons.check_circle : Icons.cancel, size: 14, color: ok ? Colors.green : Colors.red),
        const SizedBox(width: 3),
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ]);

  Widget _rulesSection() => _section('Sync rules', [
        DropdownButtonFormField<int>(
          initialValue: _interval,
          decoration: const InputDecoration(
              labelText: 'Interval', border: OutlineInputBorder(), isDense: true),
          items: const [
            DropdownMenuItem(value: 600, child: Text('10 minutes')),
            DropdownMenuItem(value: 1800, child: Text('30 minutes')),
            DropdownMenuItem(value: 3600, child: Text('60 minutes')),
          ],
          onChanged: (v) => setState(() => _interval = v ?? 1800),
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<int>(
          initialValue: _window,
          decoration: const InputDecoration(
              labelText: 'Sync window', border: OutlineInputBorder(), isDense: true),
          items: const [
            DropdownMenuItem(value: 7, child: Text('7 days')),
            DropdownMenuItem(value: 30, child: Text('30 days')),
            DropdownMenuItem(value: 90, child: Text('90 days')),
          ],
          onChanged: (v) => setState(() => _window = v ?? 30),
        ),
      ]);

  CalendarSource _source(CalendarSourceKind kind) {
    final c = _sources[kind]!;
    return CalendarSource(
      kind: kind,
      username: c.username.text,
      feishuCalendarId: c.calendarId,
      isEnabled: c.enabled,
    );
  }

  Future<void> _saveFeishuApp() async {
    setState(() {
      _feishuError = null;
      _feishuStatus = null;
    });
    try {
      await service.saveFeishuApp(_appId.text, _appSecret.text);
      setState(() => _feishuStatus = 'App ID and Secret saved');
    } catch (e) {
      setState(() => _feishuError = '$e');
    }
  }

  Future<void> _authorize() async {
    setState(() {
      _busy = true;
      _feishuError = null;
      _feishuStatus = null;
    });
    final err = await service.authorizeFeishu((uri) async {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    });
    if (err == null) {
      _feishuStatus = 'Authorized successfully';
      await service.loadFeishuCalendars();
    } else {
      _feishuError = err;
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _testSource(CalendarSourceKind kind) async {
    setState(() => _busy = true);
    final c = _sources[kind]!;
    await service.testSource(_source(kind), c.password.text.isEmpty ? null : c.password.text);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _saveSource(CalendarSourceKind kind) async {
    final c = _sources[kind]!;
    await service.saveSource(_source(kind), c.password.text.isEmpty ? null : c.password.text,
        intervalSeconds: _interval, windowDays: _window);
  }
}
