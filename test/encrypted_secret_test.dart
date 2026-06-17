import 'package:flutter_test/flutter_test.dart';
import 'package:one_calendar/core/security/encrypted_secret_store.dart';
import 'package:one_calendar/core/security/master_key.dart';
import 'package:one_calendar/core/storage/state_store.dart';

void main() {
  test('encrypt round trip; ciphertext not plaintext', () async {
    final store = StateStore.inMemory();
    final secrets = EncryptedSecretStore(store, InMemoryMasterKeyProvider());
    await secrets.savePassword('hunter2', 'dingtalk:alice');
    expect(await secrets.readPassword('dingtalk:alice'), 'hunter2');
    final raw = store.loadSecret('dingtalk:alice');
    expect(raw, isNotNull);
    expect(String.fromCharCodes(raw!.ciphertext) == 'hunter2', isFalse);
    secrets.deletePassword('dingtalk:alice');
    expect(await secrets.readPassword('dingtalk:alice'), isNull);
    store.dispose();
  });

  test('wrong key fails to decrypt', () async {
    final store = StateStore.inMemory();
    await EncryptedSecretStore(store, InMemoryMasterKeyProvider())
        .savePassword('x', 'a');
    final other = EncryptedSecretStore(store, InMemoryMasterKeyProvider());
    expect(() => other.readPassword('a'), throwsA(isA<SecretDecryptException>()));
    store.dispose();
  });
}
