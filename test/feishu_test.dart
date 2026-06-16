import 'package:flutter_test/flutter_test.dart';
import 'package:neo_toolbox/core/feishu/feishu_api_client.dart';
import 'package:neo_toolbox/core/feishu/feishu_http.dart';
import 'package:neo_toolbox/core/feishu/feishu_oauth.dart';
import 'package:neo_toolbox/core/feishu/feishu_token_manager.dart';
import 'package:neo_toolbox/core/security/encrypted_secret_store.dart';
import 'package:neo_toolbox/core/security/master_key.dart';
import 'package:neo_toolbox/core/storage/state_store.dart';

class FakeHttp implements FeishuHttpClient {
  final List<FeishuHttpResponse> queue;
  final responses = <FeishuHttpResponse>[];
  final requests = <String>[];
  final authHeaders = <String?>[];
  FakeHttp(this.queue);
  @override
  Future<FeishuHttpResponse> send(String method, String url,
      {Map<String, String> headers = const {}, String? body}) async {
    requests.add('$method $url');
    authHeaders.add(headers['Authorization']);
    return queue.isEmpty ? const FeishuHttpResponse(200, '{}') : queue.removeAt(0);
  }
}

DateTime t0() => DateTime.fromMillisecondsSinceEpoch(0);

FeishuTokenManager freshManager(FakeHttp http) {
  final store = StateStore.inMemory();
  final secrets = EncryptedSecretStore(store, InMemoryMasterKeyProvider());
  return FeishuTokenManager(
      credentials: secrets, oauth: FeishuOAuth(http: http, now: t0), now: t0);
}

void main() {
  test('authorize url contains params', () {
    final oauth = FeishuOAuth(http: FakeHttp([]), now: t0);
    final url = oauth.authorizeUrl(
        appId: 'cli_x', redirectUri: 'http://127.0.0.1:17865/callback', state: 'st');
    final s = url.toString();
    expect(s.contains('client_id=cli_x'), isTrue);
    expect(s.contains('response_type=code'), isTrue);
    expect(s.contains('state=st'), isTrue);
    expect(s.contains('offline_access'), isTrue);
  });

  test('exchange parses tokens', () async {
    final http = FakeHttp([
      const FeishuHttpResponse(200,
          '{"code":0,"access_token":"at","expires_in":7200,"refresh_token":"rt","refresh_token_expires_in":604800}')
    ]);
    final oauth = FeishuOAuth(http: http, now: () => DateTime.fromMillisecondsSinceEpoch(1000000));
    final b = await oauth.exchange(appId: 'id', appSecret: 'sec', code: 'c', redirectUri: 'r');
    expect(b.accessToken, 'at');
    expect(b.refreshToken, 'rt');
  });

  test('token manager refreshes when expired', () async {
    final http = FakeHttp([
      const FeishuHttpResponse(200,
          '{"code":0,"access_token":"fresh","expires_in":7200,"refresh_token":"rt2","refresh_token_expires_in":604800}')
    ]);
    final mgr = freshManager(http);
    await mgr.saveAppCredentials('id', 'sec');
    await mgr.storeTokens(FeishuTokenBundle(
      accessToken: 'old',
      accessTokenExpiry: DateTime.fromMillisecondsSinceEpoch(0),
      refreshToken: 'rt',
      refreshTokenExpiry: DateTime.fromMillisecondsSinceEpoch(999999999),
    ));
    expect(await mgr.validAccessToken(), 'fresh');
  });

  test('token manager throws when refresh expired', () async {
    final mgr = freshManager(FakeHttp([]));
    await mgr.saveAppCredentials('id', 'sec');
    await mgr.storeTokens(FeishuTokenBundle(
      accessToken: 'old',
      accessTokenExpiry: DateTime.fromMillisecondsSinceEpoch(0),
      refreshToken: 'rt',
      refreshTokenExpiry: DateTime.fromMillisecondsSinceEpoch(0),
    ));
    expect(() => mgr.validAccessToken(), throwsA(isA<FeishuNeedsReauthorization>()));
  });

  test('api list calendars + bearer', () async {
    final http = FakeHttp([
      const FeishuHttpResponse(
          200, '{"code":0,"data":{"calendar_list":[{"calendar_id":"c1","summary":"Work"}]}}')
    ]);
    final mgr = freshManager(http);
    await mgr.saveAppCredentials('id', 'sec');
    await mgr.storeTokens(FeishuTokenBundle(
      accessToken: 'at',
      accessTokenExpiry: DateTime.fromMillisecondsSinceEpoch(99999999),
      refreshToken: 'rt',
      refreshTokenExpiry: DateTime.fromMillisecondsSinceEpoch(999999999),
    ));
    final client = FeishuApiClient(http: http, tokens: mgr);
    final cals = await client.listCalendars();
    expect(cals.map((c) => c.id), ['c1']);
    expect(http.authHeaders.first, 'Bearer at');
  });

  test('api business error throws', () async {
    final http = FakeHttp([
      const FeishuHttpResponse(200, '{"code":99991663,"msg":"permission denied"}')
    ]);
    final mgr = freshManager(http);
    await mgr.saveAppCredentials('id', 'sec');
    await mgr.storeTokens(FeishuTokenBundle(
      accessToken: 'at',
      accessTokenExpiry: DateTime.fromMillisecondsSinceEpoch(99999999),
      refreshToken: 'rt',
      refreshTokenExpiry: DateTime.fromMillisecondsSinceEpoch(999999999),
    ));
    final client = FeishuApiClient(http: http, tokens: mgr);
    expect(() => client.listCalendars(), throwsA(isA<FeishuAuthException>()));
  });
}
