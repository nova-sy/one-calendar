import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'core/feishu/feishu_api_client.dart';
import 'core/feishu/feishu_token_manager.dart';
import 'core/i18n/locale_controller.dart';
import 'core/security/encrypted_secret_store.dart';
import 'core/security/master_key.dart';
import 'core/service/calendar_sync_service.dart';
import 'core/storage/state_store.dart';
import 'core/update/update_checker.dart';
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
  await initializeDateFormatting();
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(1120, 720),
      minimumSize: Size(960, 600),
      center: true,
      title: 'ONE CALENDAR',
    ),
    () async {
      await windowManager.show();
    },
  );
  await windowManager.setPreventClose(true);

  final service = await _buildService();
  final locale = LocaleController(service.store);
  runApp(NeoToolboxApp(service: service, locale: locale));
}

class NeoToolboxApp extends StatefulWidget {
  final CalendarSyncService service;
  final LocaleController locale;
  const NeoToolboxApp({super.key, required this.service, required this.locale});

  @override
  State<NeoToolboxApp> createState() => _NeoToolboxAppState();
}

class _NeoToolboxAppState extends State<NeoToolboxApp> with TrayListener, WindowListener {
  final ValueNotifier<UpdateInfo?> _update = ValueNotifier(null);
  Timer? _updateTimer;

  @override
  void initState() {
    super.initState();
    trayManager.addListener(this);
    windowManager.addListener(this);
    widget.locale.addListener(_onLocaleChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await _initTray();
    });
    _startUpdateChecks();
  }

  void _onLocaleChanged() {
    // Rebuild the native tray menu in the newly selected language.
    _initTray();
  }

  Future<void> _startUpdateChecks() async {
    final info = await PackageInfo.fromPlatform();
    final checker = UpdateChecker(currentVersion: info.version);
    Future<void> run() async {
      try {
        _update.value = await checker.check();
      } catch (_) {}
    }
    await run();
    _updateTimer = Timer.periodic(const Duration(hours: 24), (_) => run());
  }

  Future<void> _initTray() async {
    try {
      final s = widget.locale.strings;
      await trayManager.setIcon(
        'assets/tray_icon.png',
        isTemplate: Platform.isMacOS,
      );
      await trayManager.setToolTip('ONE CALENDAR');
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'open', label: s.trayOpenDashboard),
        MenuItem(key: 'sync', label: s.traySyncNow),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: s.trayQuit),
      ]));
    } catch (e) {
      debugPrint('tray init failed: $e');
    }
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
    _updateTimer?.cancel();
    widget.locale.removeListener(_onLocaleChanged);
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.locale,
      builder: (context, _) => LocaleScope(
        controller: widget.locale,
        child: MaterialApp(
          title: 'ONE CALENDAR',
          debugShowCheckedModeBanner: false,
          locale: widget.locale.locale,
          supportedLocales: const [Locale('zh'), Locale('en')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: ThemeData(
            colorSchemeSeed: const Color(0xFF2E7CF6),
            useMaterial3: true,
          ),
          home: Dashboard(service: widget.service, update: _update),
        ),
      ),
    );
  }
}
