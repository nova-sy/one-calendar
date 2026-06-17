import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/service/calendar_sync_service.dart';
import '../core/update/update_checker.dart';
import 'calendar_sync_page.dart';
import 'settings_page.dart';

class Dashboard extends StatefulWidget {
  final CalendarSyncService service;
  final ValueNotifier<UpdateInfo?> update;
  const Dashboard({super.key, required this.service, required this.update});

  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  int _index = 0;
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          _updateBanner(),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                NavigationRail(
                  selectedIndex: _index,
                  onDestinationSelected: (i) => setState(() => _index = i),
                  labelType: NavigationRailLabelType.all,
                  leading: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Image.asset('assets/logo.png', width: 34, height: 34),
                  ),
                  destinations: const [
                    NavigationRailDestination(
                        icon: Icon(Icons.sync), label: Text('Calendar Sync')),
                    NavigationRailDestination(
                        icon: Icon(Icons.settings), label: Text('Settings')),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: _index == 0
                      ? CalendarSyncPage(service: widget.service)
                      : SettingsPage(service: widget.service),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _updateBanner() {
    return ValueListenableBuilder<UpdateInfo?>(
      valueListenable: widget.update,
      builder: (context, info, _) {
        if (info == null || _dismissed) return const SizedBox.shrink();
        return MaterialBanner(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          leading: const Icon(Icons.system_update),
          content: Text('A new version (${info.version}) is available.'),
          actions: [
            TextButton(
              onPressed: () => setState(() => _dismissed = true),
              child: const Text('Later'),
            ),
            FilledButton(
              onPressed: () =>
                  launchUrl(Uri.parse(info.url), mode: LaunchMode.externalApplication),
              child: const Text('Update'),
            ),
          ],
        );
      },
    );
  }
}
