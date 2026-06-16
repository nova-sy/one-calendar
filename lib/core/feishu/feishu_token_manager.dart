import 'dart:convert';

import '../security/encrypted_secret_store.dart';
import 'feishu_oauth.dart';

/// Owns Feishu app credentials (AK/SK) and user token lifecycle. Secrets are
/// persisted through the encrypted store.
class FeishuTokenManager {
  final EncryptedSecretStore credentials;
  final FeishuOAuth oauth;
  final DateTime Function() now;
  static const _refreshSkew = Duration(seconds: 120);

  static const _appIdAccount = 'feishu:app_id';
  static const _appSecretAccount = 'feishu:app_secret';
  static const _tokensAccount = 'feishu:tokens';

  FeishuTokenManager({
    required this.credentials,
    FeishuOAuth? oauth,
    DateTime Function()? now,
  })  : oauth = oauth ?? FeishuOAuth(),
        now = now ?? DateTime.now;

  Future<void> saveAppCredentials(String appId, String appSecret) async {
    await credentials.savePassword(appId, _appIdAccount);
    if (appSecret.isNotEmpty) {
      await credentials.savePassword(appSecret, _appSecretAccount);
    }
  }

  Future<String?> appId() => credentials.readPassword(_appIdAccount);
  Future<String?> appSecret() => credentials.readPassword(_appSecretAccount);

  Future<bool> hasAppCredentials() async {
    final id = await appId();
    final secret = await appSecret();
    return (id?.isNotEmpty ?? false) && (secret?.isNotEmpty ?? false);
  }

  Future<bool> hasSecret() async => (await appSecret())?.isNotEmpty ?? false;

  Future<bool> isAuthorized() async => (await loadTokens()) != null;

  Future<void> storeTokens(FeishuTokenBundle bundle) =>
      credentials.savePassword(jsonEncode(bundle.toJson()), _tokensAccount);

  Future<FeishuTokenBundle?> loadTokens() async {
    final s = await credentials.readPassword(_tokensAccount);
    if (s == null) return null;
    return FeishuTokenBundle.fromJson(jsonDecode(s) as Map<String, dynamic>);
  }

  void clearTokens() => credentials.deletePassword(_tokensAccount);

  Future<void> clearAccessOnly() async {
    final b = await loadTokens();
    if (b == null) return;
    await storeTokens(FeishuTokenBundle(
      accessToken: b.accessToken,
      accessTokenExpiry: DateTime.fromMillisecondsSinceEpoch(0),
      refreshToken: b.refreshToken,
      refreshTokenExpiry: b.refreshTokenExpiry,
    ));
  }

  Future<String> validAccessToken() async {
    final id = await appId();
    final secret = await appSecret();
    if (id == null || secret == null || id.isEmpty || secret.isEmpty) {
      throw FeishuNotConfigured();
    }
    final tokens = await loadTokens();
    if (tokens == null) throw FeishuNeedsReauthorization();
    if (now().isBefore(tokens.accessTokenExpiry.subtract(_refreshSkew))) {
      return tokens.accessToken;
    }
    if (!now().isBefore(tokens.refreshTokenExpiry)) {
      throw FeishuNeedsReauthorization();
    }
    final refreshed =
        await oauth.refresh(appId: id, appSecret: secret, refreshToken: tokens.refreshToken);
    await storeTokens(refreshed);
    return refreshed.accessToken;
  }
}
