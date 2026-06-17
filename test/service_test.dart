import 'package:flutter_test/flutter_test.dart';
import 'package:one_calendar/core/feishu/feishu_api_client.dart';
import 'package:one_calendar/core/feishu/feishu_token_manager.dart';
import 'package:one_calendar/core/security/encrypted_secret_store.dart';
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
