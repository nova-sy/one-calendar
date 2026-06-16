import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../storage/state_store.dart';
import 'master_key.dart';

class SecretDecryptException implements Exception {
  @override
  String toString() => 'SecretDecryptException: decryption failed';
}

/// Stores secret values as AES-GCM ciphertext in the SQLite `secrets` table.
/// The encryption key comes from a [MasterKeyProvider] (a local file).
class EncryptedSecretStore {
  final StateStore _store;
  final MasterKeyProvider _masterKey;
  final _algorithm = AesGcm.with256bits();

  EncryptedSecretStore(this._store, this._masterKey);

  Future<void> savePassword(String password, String account) async {
    final key = SecretKey(await _masterKey.masterKey());
    final box = await _algorithm.encrypt(utf8.encode(password), secretKey: key);
    // Store cipherText + mac(tag) combined, nonce separate (mirrors Swift).
    final combined = Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
    _store.saveSecret(account, combined, Uint8List.fromList(box.nonce));
  }

  Future<String?> readPassword(String account) async {
    final row = _store.loadSecret(account);
    if (row == null) return null;
    if (row.ciphertext.length < 16) throw SecretDecryptException();
    final key = SecretKey(await _masterKey.masterKey());
    final cipher = row.ciphertext.sublist(0, row.ciphertext.length - 16);
    final tag = row.ciphertext.sublist(row.ciphertext.length - 16);
    try {
      final clear = await _algorithm.decrypt(
        SecretBox(cipher, nonce: row.nonce, mac: Mac(tag)),
        secretKey: key,
      );
      return utf8.decode(clear);
    } catch (_) {
      throw SecretDecryptException();
    }
  }

  void deletePassword(String account) => _store.deleteSecret(account);
}
