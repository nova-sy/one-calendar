import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'core/feishu/feishu_api_client.dart';
import 'core/feishu/feishu_token_manager.dart';
import 'core/security/encrypted_secret_store.dart';
import 'core/security/master_key.dart';
import 'core/service/calendar_sync_service.dart';
import 'core/storage/state_store.dart';
import 'ui/dashboard.dart';

Future<CalendarSyncService> _buildService() async {
  final base = await getApplicationSupportDirectory();
  final dir = Directory(p.join(base.path, 'NeoToolbox'));
  await dir.create(recursive: true);
  final store = StateStore.open(p.join(dir.path, 'state.sqlite3'));
  final secrets =
      EncryptedSecretStore(store, FileMasterKeyProvider(p.join(dir.path, 'master.key')));
  final tokenManager = FeishuTokenManager(credentials: secrets);
  final feishu = FeishuApiClient(tokens: tokenManager);
  final service = CalendarSyncService(
      store: store, secrets: secrets, feishu: feishu, tokenManager: tokenManager);
  await service.loadSettings();
  return service;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(1120, 720),
      minimumSize: Size(960, 600),
      center: true,
      title: 'Neo Toolbox',
    ),
    () async {
      await windowManager.show();
    },
  );
  await windowManager.setPreventClose(true);

  final service = await _buildService();
  runApp(NeoToolboxApp(service: service));
}

class NeoToolboxApp extends StatefulWidget {
  final CalendarSyncService service;
  const NeoToolboxApp({super.key, required this.service});

  @override
  State<NeoToolboxApp> createState() => _NeoToolboxAppState();
}

class _NeoToolboxAppState extends State<NeoToolboxApp> with TrayListener, WindowListener {
  @override
  void initState() {
    super.initState();
    trayManager.addListener(this);
    windowManager.addListener(this);
    _initTray();
  }

  Future<void> _initTray() async {
    await trayManager.setIcon('assets/tray_icon.png');
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'open', label: 'Open Dashboard'),
      MenuItem(key: 'sync', label: 'Sync Now'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Quit Neo Toolbox'),
    ]));
  }

  @override
  void onTrayIconMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem item) async {
    switch (item.key) {
      case 'open':
        await windowManager.show();
        await windowManager.focus();
      case 'sync':
        widget.service.syncNow();
      case 'quit':
        await windowManager.setPreventClose(false);
        await windowManager.destroy();
    }
  }

  @override
  void onWindowClose() async {
    // Keep running in the tray instead of quitting.
    await windowManager.hide();
  }

  @override
  void dispose() {
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Neo Toolbox',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF2E7CF6),
        useMaterial3: true,
      ),
      home: Dashboard(service: widget.service),
    );
  }
}
