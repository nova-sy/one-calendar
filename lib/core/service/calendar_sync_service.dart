import 'dart:async';

import 'package:flutter/foundation.dart';

import '../caldav/caldav_client.dart';
import '../caldav/caldav_transport.dart';
import '../feishu/feishu_api_client.dart';
import '../feishu/feishu_oauth.dart';
import '../feishu/feishu_token_manager.dart';
import '../models/models.dart';
import '../security/encrypted_secret_store.dart';
import '../storage/state_store.dart';
import '../sync/sync_engine.dart';

enum LogLevel { info, warning, error }

class RuntimeLog {
  final DateTime timestamp;
  final LogLevel level;
  final String message;
  const RuntimeLog(this.timestamp, this.level, this.message);
}

class SideResult {
  final bool ok;
  final String? message;
  const SideResult.okResult() : ok = true, message = null;
  const SideResult.failed(this.message) : ok = false;
}

class SourceTestResult {
  final SideResult caldav;
  final SideResult feishu;
  const SourceTestResult(this.caldav, this.feishu);
}

typedef CalDavFetcherFactory = CalendarEventFetcher Function(CalendarSourceKind);

class CalendarSyncService extends ChangeNotifier {
  final StateStore store;
  final EncryptedSecretStore secrets;
  final FeishuApiClient feishu;
  final FeishuTokenManager tokenManager;
  final CalDavFetcherFactory fetcherFor;
  final DateTime Function() now;

  CalendarSyncConfiguration configuration = const CalendarSyncConfiguration();
  CalendarSyncStatus status = const CalendarSyncStatus();
  SyncReport? lastReport;
  List<FeishuCalendar> availableCalendars = [];
  final Map<String, SourceTestResult> sourceTestResults = {}; // keyed by source id
  bool feishuAuthorized = false;
  DependencyCheck dependencyCheck = const DependencyCheck(
      status: DependencyStatus.missing, message: 'Feishu not checked');
  final List<RuntimeLog> recentLogs = [];

  final Map<String, SyncEngine> _runners = {}; // keyed by source id
  bool _running = false;
  Timer? _timer;

  CalendarSyncService({
    required this.store,
    required this.secrets,
    required this.feishu,
    required this.tokenManager,
    CalDavFetcherFactory? fetcherFor,
    DateTime Function()? now,
  })  : fetcherFor = fetcherFor ??
            ((kind) => makeCalDavClient(kind, transport: DioCalDavTransport())),
        now = now ?? DateTime.now;

  void _log(LogLevel level, String message) {
    final ts = now();
    recentLogs.insert(0, RuntimeLog(ts, level, message));
    if (recentLogs.length > 100) recentLogs.removeLast();
    store.appendLog(ts, level.name, message);
  }

  Future<void> loadSettings() async {
    recentLogs
      ..clear()
      ..addAll(store.loadRecentLogs(limit: 100).map((l) => RuntimeLog(
            l.ts,
            LogLevel.values.firstWhere((e) => e.name == l.level, orElse: () => LogLevel.info),
            l.message,
          )));
    final g = store.loadGlobalSettings();
    final sources = store.loadCalendarSources();
    configuration = CalendarSyncConfiguration(
      sources: sources,
      syncIntervalSeconds: g?.syncIntervalSeconds ?? 1800,
      syncWindowDays: g?.syncWindowDays ?? 30,
    );
    if (g?.lastSuccessfulSyncAt != null) {
      status = CalendarSyncStatus(state: status.state, lastSyncAt: g!.lastSuccessfulSyncAt);
    }
    feishuAuthorized = await tokenManager.isAuthorized();
    await _migrateLegacyPasswords();
    await _rebuildRunners();
    _restartTimerIfNeeded();
    notifyListeners();
  }

  /// Migrate pre-multi-account CalDAV passwords stored under `<kind>:<username>`
  /// to the new per-source key `caldav:<id>` (legacy source has id == kind.name).
  Future<void> _migrateLegacyPasswords() async {
    for (final s in configuration.sources) {
      if (s.id != s.kind.name) continue; // only legacy-shaped sources
      final hasNew = (await secrets.readPassword(s.credentialAccount())) ?? '';
      if (hasNew.isNotEmpty) continue;
      final old = (await secrets.readPassword('${s.kind.name}:${s.username}')) ?? '';
      if (old.isNotEmpty) {
        await secrets.savePassword(old, s.credentialAccount());
      }
    }
  }

  Future<bool> _hasStoredPassword(CalendarSource s) async {
    try {
      final pw = await secrets.readPassword(s.credentialAccount());
      return pw != null && pw.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<bool> hasStoredPasswordFor(CalendarSource s) => _hasStoredPassword(s);

  Future<void> _rebuildRunners() async {
    _runners.clear();
    for (final s in configuration.sources) {
      if (!(s.isEnabled && s.isConfigured && await _hasStoredPassword(s))) continue;
      _runners[s.id] = SyncEngine(
        settings: configuration.settingsFor(s),
        fetcher: fetcherFor(s.kind),
        writer: feishu,
        store: store,
        password: () async => (await secrets.readPassword(s.credentialAccount())) ?? '',
        sourceTag: s.mappingTag,
        now: now,
      );
    }
  }

  bool get _hasEnabledConfiguredSource => _runners.isNotEmpty;

  /// Add or update one account (by id). Does not touch global sync rules.
  Future<void> saveSource(CalendarSource source, {String? password}) async {
    if (password != null && password.isNotEmpty) {
      await secrets.savePassword(password, source.credentialAccount());
    }
    store.saveCalendarSource(source);

    final others = configuration.sources.where((s) => s.id != source.id).toList()
      ..add(source);
    others.sort((a, b) => a.id.compareTo(b.id));
    configuration = CalendarSyncConfiguration(
        sources: others,
        syncIntervalSeconds: configuration.syncIntervalSeconds,
        syncWindowDays: configuration.syncWindowDays);

    await _rebuildRunners();
    _restartTimerIfNeeded();
    notifyListeners();
  }

  /// Delete an account. Strategy A: stop syncing it; already-synced Feishu
  /// events are left untouched (its event mappings are simply orphaned).
  Future<void> deleteSource(String id) async {
    final matches = configuration.sources.where((s) => s.id == id).toList();
    final source = matches.isEmpty ? null : matches.first;
    store.deleteCalendarSource(id);
    if (source != null) {
      secrets.deletePassword(source.credentialAccount());
    }
    configuration = CalendarSyncConfiguration(
        sources: configuration.sources.where((s) => s.id != id).toList(),
        syncIntervalSeconds: configuration.syncIntervalSeconds,
        syncWindowDays: configuration.syncWindowDays);
    sourceTestResults.remove(id);
    await _rebuildRunners();
    _restartTimerIfNeeded();
    notifyListeners();
  }

  Future<SourceTestResult> testSource(CalendarSource source, String? password) async {
    final feishuSide = await _testFeishuSide();
    final caldavSide = await _testCalDavSide(source, password);
    final result = SourceTestResult(caldavSide, feishuSide);
    sourceTestResults[source.id] = result;
    notifyListeners();
    return result;
  }

  Future<SideResult> _testFeishuSide() async {
    dependencyCheck = await feishu.checkDependency();
    if (dependencyCheck.status != DependencyStatus.available) {
      return SideResult.failed(dependencyCheck.message);
    }
    try {
      availableCalendars = await feishu.listCalendars();
      return const SideResult.okResult();
    } catch (e) {
      return SideResult.failed('$e');
    }
  }

  Future<SideResult> _testCalDavSide(CalendarSource source, String? password) async {
    final pw = (password != null && password.isNotEmpty)
        ? password
        : (await secrets.readPassword(source.credentialAccount())) ?? '';
    try {
      await fetcherFor(source.kind).fetchEvents(configuration.settingsFor(source), pw);
      return const SideResult.okResult();
    } catch (e) {
      return SideResult.failed('$e');
    }
  }

  Future<void> loadFeishuCalendars() async {
    dependencyCheck = await feishu.checkDependency();
    if (dependencyCheck.status != DependencyStatus.available) {
      availableCalendars = [];
      _log(LogLevel.warning, dependencyCheck.message);
      notifyListeners();
      return;
    }
    try {
      availableCalendars = await feishu.listCalendars();
    } catch (e) {
      _log(LogLevel.error, 'Failed to list calendars: $e');
    }
    notifyListeners();
  }

  /// Persist global sync rules (interval/window) immediately and reschedule.
  Future<void> setSyncRules({required int intervalSeconds, required int windowDays}) async {
    final prior = store.loadGlobalSettings();
    store.saveGlobalSettings(GlobalSettings(
      syncIntervalSeconds: intervalSeconds,
      syncWindowDays: windowDays,
      lastSuccessfulSyncAt: prior?.lastSuccessfulSyncAt,
      consecutiveFailureCount: prior?.consecutiveFailureCount ?? 0,
    ));
    configuration = CalendarSyncConfiguration(
      sources: configuration.sources,
      syncIntervalSeconds: intervalSeconds,
      syncWindowDays: windowDays,
    );
    await _rebuildRunners(); // window change affects each engine's fetch window
    _restartTimerIfNeeded(); // interval change reschedules the timer
    notifyListeners();
  }

  // --- Feishu app ---

  Future<String> feishuAppId() async => (await tokenManager.appId()) ?? '';
  Future<String> feishuAppSecretValue() async => (await tokenManager.appSecret()) ?? '';
  Future<bool> feishuHasSecret() => tokenManager.hasSecret();

  Future<void> saveFeishuApp(String appId, String appSecret) =>
      tokenManager.saveAppCredentials(appId, appSecret);

  Future<void> refreshFeishuAuthState() async {
    feishuAuthorized = await tokenManager.isAuthorized();
    notifyListeners();
  }

  Future<String?> authorizeFeishu(Future<void> Function(Uri) openBrowser) async {
    final appId = await tokenManager.appId();
    final appSecret = await tokenManager.appSecret();
    if (appId == null || appId.isEmpty || appSecret == null || appSecret.isEmpty) {
      return 'Feishu app id/secret not configured';
    }
    try {
      final bundle = await FeishuLoopbackAuthorizer().authorize(
        appId: appId,
        appSecret: appSecret,
        oauth: FeishuOAuth(),
        openBrowser: openBrowser,
      );
      await tokenManager.storeTokens(bundle);
      feishuAuthorized = true;
      notifyListeners();
      return null;
    } catch (e) {
      return '$e';
    }
  }

  Future<String> storedPasswordFor(CalendarSource s) async {
    try {
      return (await secrets.readPassword(s.credentialAccount())) ?? '';
    } catch (_) {
      return '';
    }
  }

  // --- Sync ---

  void syncNow() => triggerSync(SyncTrigger.manual);

  Future<void> triggerSync(SyncTrigger trigger) async {
    if (_running) return;
    if (_runners.isEmpty) {
      _log(LogLevel.info, 'No enabled, configured source');
      return;
    }
    _running = true;
    status = CalendarSyncStatus(state: SyncRunState.running, lastSyncAt: status.lastSyncAt);
    notifyListeners();

    var anyFailure = false;
    SyncReport? latest;
    String labelOf(String id) {
      final m = configuration.sources.where((s) => s.id == id).toList();
      return m.isEmpty ? id : m.first.displayLabel;
    }
    for (final entry in _runners.entries) {
      try {
        final report = await entry.value.run(trigger);
        latest = report;
        _log(LogLevel.info, '${labelOf(entry.key)}: ${report.createdCount}/${report.updatedCount}/${report.deletedCount}');
      } catch (e) {
        anyFailure = true;
        _log(LogLevel.error, '${labelOf(entry.key)}: $e');
      }
    }
    if (latest != null) lastReport = latest;
    final syncedAt = now();
    status = CalendarSyncStatus(
      state: anyFailure ? SyncRunState.failed : SyncRunState.idle,
      failureMessage: anyFailure ? 'One or more sources failed' : null,
      lastSyncAt: syncedAt,
    );
    store.saveGlobalSettings(GlobalSettings(
      syncIntervalSeconds: configuration.syncIntervalSeconds,
      syncWindowDays: configuration.syncWindowDays,
      lastSuccessfulSyncAt: syncedAt,
    ));
    _running = false;
    notifyListeners();
  }

  void _restartTimerIfNeeded() {
    _timer?.cancel();
    if (_hasEnabledConfiguredSource) {
      _timer = Timer.periodic(
          Duration(seconds: configuration.syncIntervalSeconds),
          (_) => triggerSync(SyncTrigger.timer));
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
