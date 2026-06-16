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
  }
}
