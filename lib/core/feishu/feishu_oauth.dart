import 'dart:convert';
import 'dart:io';

import 'feishu_http.dart';

class FeishuAuthException implements Exception {
  final String message;
  FeishuAuthException(this.message);
  @override
  String toString() => 'FeishuAuthException: $message';
}

class FeishuNeedsReauthorization implements Exception {}

class FeishuNotConfigured implements Exception {}

class FeishuTokenBundle {
  final String accessToken;
  final DateTime accessTokenExpiry;
  final String refreshToken;
  final DateTime refreshTokenExpiry;

  const FeishuTokenBundle({
    required this.accessToken,
    required this.accessTokenExpiry,
    required this.refreshToken,
    required this.refreshTokenExpiry,
  });

  Map<String, dynamic> toJson() => {
        'accessToken': accessToken,
        'accessTokenExpiry': accessTokenExpiry.millisecondsSinceEpoch,
        'refreshToken': refreshToken,
        'refreshTokenExpiry': refreshTokenExpiry.millisecondsSinceEpoch,
      };

  factory FeishuTokenBundle.fromJson(Map<String, dynamic> j) => FeishuTokenBundle(
        accessToken: j['accessToken'] as String,
        accessTokenExpiry:
            DateTime.fromMillisecondsSinceEpoch(j['accessTokenExpiry'] as int),
        refreshToken: j['refreshToken'] as String,
        refreshTokenExpiry:
            DateTime.fromMillisecondsSinceEpoch(j['refreshTokenExpiry'] as int),
      );
}

const feishuCalendarScopes = [
  'offline_access',
  'calendar:calendar',
  'calendar:calendar:read',
  'calendar:calendar.event:create',
  'calendar:calendar.event:update',
  'calendar:calendar.event:delete',
  'calendar:calendar.event:read',
];

class FeishuOAuth {
  final FeishuHttpClient http;
  final DateTime Function() now;
  static const _authorizeBase =
      'https://accounts.feishu.cn/open-apis/authen/v1/authorize';
  static const _tokenUrl = 'https://open.feishu.cn/open-apis/authen/v2/oauth/token';

  FeishuOAuth({FeishuHttpClient? http, DateTime Function()? now})
      : http = http ?? DioFeishuHttpClient(),
        now = now ?? DateTime.now;

  Uri authorizeUrl({
    required String appId,
    required String redirectUri,
    required String state,
    List<String> scopes = feishuCalendarScopes,
  }) =>
      Uri.parse(_authorizeBase).replace(queryParameters: {
        'client_id': appId,
        'redirect_uri': redirectUri,
        'response_type': 'code',
        'scope': scopes.join(' '),
        'state': state,
      });

  Future<FeishuTokenBundle> exchange({
    required String appId,
    required String appSecret,
    required String code,
    required String redirectUri,
  }) =>
      _token({
        'grant_type': 'authorization_code',
        'client_id': appId,
        'client_secret': appSecret,
        'code': code,
        'redirect_uri': redirectUri,
      });

  Future<FeishuTokenBundle> refresh({
    required String appId,
    required String appSecret,
    required String refreshToken,
  }) =>
      _token({
        'grant_type': 'refresh_token',
        'client_id': appId,
        'client_secret': appSecret,
        'refresh_token': refreshToken,
      });

  Future<FeishuTokenBundle> _token(Map<String, String> body) async {
    final res = await http.send('POST', _tokenUrl,
        headers: {'Content-Type': 'application/json; charset=utf-8'},
        body: jsonEncode(body));
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final code = j['code'] as int?;
    final msg = (j['msg'] as String?) ?? (j['error_description'] as String?) ?? (j['error'] as String?);
    if (code != null && code != 0) {
      final detail = msg ?? 'see Feishu app redirect URL config';
      throw FeishuAuthException('oauth error $code: $detail (redirect_uri must be '
          'http://127.0.0.1:17865/callback, registered in the Feishu app)');
    }
    final at = j['access_token'] as String?;
    final rt = j['refresh_token'] as String?;
    if (at == null || rt == null) {
      throw FeishuAuthException(msg ?? 'missing tokens in response: ${res.body}');
    }
    final t = now();
    return FeishuTokenBundle(
      accessToken: at,
      accessTokenExpiry: t.add(Duration(seconds: (j['expires_in'] as int?) ?? 7200)),
      refreshToken: rt,
      refreshTokenExpiry:
          t.add(Duration(seconds: (j['refresh_token_expires_in'] as int?) ?? 604800)),
    );
  }
}

/// Authorization-code grant with a one-shot loopback HTTP listener.
class FeishuLoopbackAuthorizer {
  final int port;
  FeishuLoopbackAuthorizer({this.port = 17865});

  String get redirectUri => 'http://127.0.0.1:$port/callback';

  Future<FeishuTokenBundle> authorize({
    required String appId,
    required String appSecret,
    required FeishuOAuth oauth,
    required Future<void> Function(Uri) openBrowser,
  }) async {
    final state = DateTime.now().microsecondsSinceEpoch.toString();
    final url = oauth.authorizeUrl(appId: appId, redirectUri: redirectUri, state: state);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    try {
      await openBrowser(url);
      await for (final request in server) {
        final code = request.uri.queryParameters['code'];
        final gotState = request.uri.queryParameters['state'];
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          ..write('<html><body>Authorization complete. You can close this window.</body></html>');
        await request.response.close();
        if (code != null && gotState == state) {
          return await oauth.exchange(
              appId: appId, appSecret: appSecret, code: code, redirectUri: redirectUri);
        }
        throw FeishuAuthException('authorization failed or state mismatch');
      }
      throw FeishuAuthException('no callback received');
    } finally {
      await server.close(force: true);
    }
  }
}
