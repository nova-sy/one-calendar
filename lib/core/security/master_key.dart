import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

abstract class MasterKeyProvider {
  /// Returns a stable 32-byte key.
  Future<Uint8List> masterKey();
}

class InMemoryMasterKeyProvider implements MasterKeyProvider {
  final Uint8List _key;
  InMemoryMasterKeyProvider([Uint8List? key]) : _key = key ?? _random32();
  @override
  Future<Uint8List> masterKey() async => _key;
}

/// Stores a 256-bit key in a local file (0600 on POSIX). No OS keychain.
class FileMasterKeyProvider implements MasterKeyProvider {
  final String path;
  FileMasterKeyProvider(this.path);

  @override
  Future<Uint8List> masterKey() async {
    final file = File(path);
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      if (bytes.length == 32) return Uint8List.fromList(bytes);
    }
    final key = _random32();
    await file.parent.create(recursive: true);
    await file.writeAsBytes(key, flush: true);
    if (!Platform.isWindows) {
      try {
        await Process.run('chmod', ['600', path]);
      } catch (_) {}
    }
    return key;
  }
}

Uint8List _random32() {
  final rng = Random.secure();
  return Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
}
