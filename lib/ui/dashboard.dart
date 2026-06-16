import 'package:flutter/material.dart';

import '../core/service/calendar_sync_service.dart';
import 'calendar_sync_page.dart';
import 'settings_page.dart';

class Dashboard extends StatefulWidget {
  final CalendarSyncService service;
  const Dashboard({super.key, required this.service});

  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
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
    );
  }
}
