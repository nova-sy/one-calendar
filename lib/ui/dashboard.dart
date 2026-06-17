import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/i18n/locale_controller.dart';
import '../core/service/calendar_sync_service.dart';
import '../core/update/update_checker.dart';
import 'accounts_page.dart';
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
    final s = context.strings;
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
                  destinations: [
                    NavigationRailDestination(
                        icon: const Icon(Icons.sync), label: Text(s.navCalendarSync)),
                    NavigationRailDestination(
                        icon: const Icon(Icons.people_outline), label: Text(s.navAccounts)),
                    NavigationRailDestination(
                        icon: const Icon(Icons.settings), label: Text(s.navSettings)),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: switch (_index) {
                    0 => CalendarSyncPage(service: widget.service),
                    1 => AccountsPage(service: widget.service),
                    _ => SettingsPage(service: widget.service),
                  },
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
        final s = context.strings;
        return MaterialBanner(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          leading: const Icon(Icons.system_update),
          content: Text(s.updateAvailableBanner(info.version)),
          actions: [
            TextButton(
              onPressed: () => setState(() => _dismissed = true),
              child: Text(s.later),
            ),
            FilledButton(
              onPressed: () =>
                  launchUrl(Uri.parse(info.url), mode: LaunchMode.externalApplication),
              child: Text(s.update),
            ),
          ],
        );
      },
    );
  }
}
