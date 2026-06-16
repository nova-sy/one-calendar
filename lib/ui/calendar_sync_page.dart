import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/models/models.dart';
import '../core/service/calendar_sync_service.dart';

class CalendarSyncPage extends StatelessWidget {
  final CalendarSyncService service;
  const CalendarSyncPage({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Calendar Sync to Feishu',
                            style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600)),
                        SizedBox(height: 4),
                        Text('Single-direction create, update, and delete sync.',
                            style: TextStyle(color: Colors.grey)),
                      ],
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: service.syncNow,
                    icon: const Icon(Icons.sync),
                    label: const Text('Sync Now'),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _card('Status', _statusText, Icons.check_circle_outline)),
                  const SizedBox(width: 12),
                  Expanded(child: _card('Last Sync', _lastSync, Icons.schedule)),
                  const SizedBox(width: 12),
                  Expanded(
                      child: _card('Sync Window', '${service.configuration.syncWindowDays} days',
                          Icons.calendar_today)),
                  const SizedBox(width: 12),
                  Expanded(child: _card('Last Changes', _changes, Icons.swap_horiz)),
                ],
              ),
              const SizedBox(height: 24),
              const Text('Runtime Log',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              _logList(),
            ],
          ),
        );
      },
    );
  }

  String get _statusText {
    switch (service.status.state) {
      case SyncRunState.idle:
        return 'Idle';
      case SyncRunState.running:
        return 'Running';
      case SyncRunState.failed:
        return 'Failed: ${service.status.failureMessage ?? ''}';
    }
  }

  String get _lastSync {
    final d = service.status.lastSyncAt;
    if (d == null) return 'Never';
    return DateFormat.yMd().add_jm().format(d);
  }

  String get _changes {
    final r = service.lastReport;
    if (r == null) return '0 / 0 / 0';
    return '${r.createdCount} / ${r.updatedCount} / ${r.deletedCount}';
  }

  Widget _card(String title, String value, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, size: 14, color: Colors.grey),
            const SizedBox(width: 6),
            Text(title, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ]),
          const SizedBox(height: 10),
          Text(value,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }

  Widget _logList() {
    final logs = service.recentLogs;
    if (logs.isEmpty) {
      return const Text('No activity yet.', style: TextStyle(color: Colors.grey));
    }
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: logs.take(40).map((l) {
          final color = switch (l.level) {
            LogLevel.error => Colors.red,
            LogLevel.warning => Colors.orange,
            LogLevel.info => Colors.grey,
          };
          return ListTile(
            dense: true,
            leading: Icon(Icons.circle, size: 8, color: color),
            title: Text(l.message, style: const TextStyle(fontSize: 13)),
            trailing: Text(DateFormat.Hms().format(l.timestamp),
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
          );
        }).toList(),
      ),
    );
  }
}
