import 'dart:convert';

import 'package:dio/dio.dart';

class CalDavResponse {
  final int status;
  final String body;
  final String? location;
  const CalDavResponse(this.status, this.body, {this.location});
}

abstract class CalDavTransport {
  Future<CalDavResponse> send(
    String method,
    String url, {
    Map<String, String> headers = const {},
    String? body,
  });
}

String basicAuth(String username, String password) =>
    'Basic ${base64.encode(utf8.encode('$username:$password'))}';

class DioCalDavTransport implements CalDavTransport {
  final Dio _dio;
  DioCalDavTransport([Dio? dio])
      : _dio = dio ??
            Dio(BaseOptions(
              followRedirects: false,
              validateStatus: (_) => true,
              responseType: ResponseType.plain,
            ));

  @override
  Future<CalDavResponse> send(
    String method,
    String url, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    Object? lastError;
    // Retry transient connection/TLS-handshake failures.
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
      }
      try {
        final response = await _dio.request<String>(
          url,
          data: body,
          options: Options(
            method: method,
            headers: {
              'User-Agent': 'NeoToolbox CalDAV',
              ...headers,
            },
            responseType: ResponseType.plain,
            validateStatus: (_) => true,
          ),
        );
        final loc = response.headers.value('location');
        return CalDavResponse(response.statusCode ?? 0, response.data ?? '', location: loc);
      } on DioException catch (e) {
        lastError = e;
        if (!_isTransient(e)) rethrow;
      }
    }
    throw lastError ?? Exception('CalDAV request failed');
  }

  bool _isTransient(DioException e) {
    if (e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return true;
    }
    final msg = e.error?.toString() ?? e.message ?? '';
    return msg.contains('HandshakeException') ||
        msg.contains('Connection terminated') ||
        msg.contains('Connection reset');
  }
}
