import 'package:flutter_test/flutter_test.dart';
import 'package:one_calendar/core/feishu/feishu_api_client.dart';
import 'package:one_calendar/core/feishu/feishu_token_manager.dart';
import 'package:one_calendar/core/security/encrypted_secret_store.dart';
import 'package:one_calendar/core/models/models.dart';
import 'package:one_calendar/core/security/master_key.dart';
import 'package:one_calendar/core/service/calendar_sync_service.dart';
import 'package:one_calendar/core/storage/state_store.dart';

CalendarSyncService buildService(StateStore store) {
  final secrets = EncryptedSecretStore(store, InMemoryMasterKeyProvider());
  final tokenManager = FeishuTokenManager(credentials: secrets);
  return CalendarSyncService(
    store: store,
    secrets: secrets,
    feishu: FeishuApiClient(tokens: tokenManager),
    tokenManager: tokenManager,
  );
}

void main() {
  test('multiple accounts of same kind add/delete by id', () async {
    final store = StateStore.inMemory();
    final service = buildService(store);
    await service.loadSettings();

    final a = CalendarSource.create(kind: CalendarSourceKind.dingtalk, label: 'Work', username: 'u1');
    final b = CalendarSource.create(kind: CalendarSourceKind.dingtalk, label: 'Personal', username: 'u2');
    await service.saveSource(a, password: 'p1');
    await service.saveSource(b, password: 'p2');

    expect(service.configuration.sources.length, 2);
    expect(service.configuration.sources.where((s) => s.kind == CalendarSourceKind.dingtalk).length, 2);
    // distinct mapping tags -> isolation
    expect(a.mappingTag == b.mappingTag, isFalse);

    await service.deleteSource(a.id);
    expect(service.configuration.sources.length, 1);
    expect(service.configuration.sources.single.id, b.id);
    // persisted
    expect(store.loadCalendarSources().single.id, b.id);
    service.dispose();
    store.dispose();
  });

  test('setSyncRules persists immediately and updates config', () async {
    final store = StateStore.inMemory();
    final service = buildService(store);
    await service.loadSettings();

    await service.setSyncRules(intervalSeconds: 3600, windowDays: 7);

    expect(store.loadGlobalSettings()!.syncIntervalSeconds, 3600);
    expect(store.loadGlobalSettings()!.syncWindowDays, 7);
    expect(service.configuration.syncIntervalSeconds, 3600);
    expect(service.configuration.syncWindowDays, 7);

    // Survives a reload (new service instance reading the same store).
    final reloaded = buildService(store);
    await reloaded.loadSettings();
    expect(reloaded.configuration.syncIntervalSeconds, 3600);
    expect(reloaded.configuration.syncWindowDays, 7);

    service.dispose();
    reloaded.dispose();
    store.dispose();
  });
}
