import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/i18n/app_strings.dart';
import '../core/i18n/locale_controller.dart';
import '../core/models/models.dart';
import '../core/service/calendar_sync_service.dart';

class CalendarSyncPage extends StatelessWidget {
  final CalendarSyncService service;
  const CalendarSyncPage({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
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
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(s.syncPageTitle,
                            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        Text(s.syncPageSubtitle,
                            style: const TextStyle(color: Colors.grey)),
                      ],
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: service.syncNow,
                    icon: const Icon(Icons.sync),
                    label: Text(s.syncNow),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                  Expanded(child: _card(s.cardStatus, _statusText(s), Icons.check_circle_outline)),
                  const SizedBox(width: 12),
                  Expanded(child: _card(s.cardLastSync, _lastSync(s), Icons.schedule)),
                  const SizedBox(width: 12),
                  Expanded(
                      child: _card(s.cardSyncWindow, s.days(service.configuration.syncWindowDays),
                          Icons.calendar_today)),
                  const SizedBox(width: 12),
                  Expanded(child: _card(s.cardLastChanges, _changes, Icons.swap_horiz)),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Text(s.runtimeLog,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              _logList(s),
            ],
          ),
        );
      },
    );
  }

  String _statusText(AppStrings s) {
    switch (service.status.state) {
      case SyncRunState.idle:
        return s.statusIdle;
      case SyncRunState.running:
        return s.statusRunning;
      case SyncRunState.failed:
        return s.statusFailed(service.status.failureMessage ?? '');
    }
  }

  String _lastSync(AppStrings s) {
    final d = service.status.lastSyncAt;
    if (d == null) return s.neverSynced;
    return DateFormat.yMd(s.language.localeCode).add_jm().format(d);
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
        color: Colors.black.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
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

  Widget _logList(AppStrings s) {
    final logs = service.recentLogs;
    if (logs.isEmpty) {
      return Text(s.noActivityYet, style: const TextStyle(color: Colors.grey));
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
            trailing: Text(DateFormat.Hms(s.language.localeCode).format(l.timestamp),
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
          );
        }).toList(),
      ),
    );
  }
}
