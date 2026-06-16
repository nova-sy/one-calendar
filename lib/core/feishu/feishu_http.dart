import 'dart:convert';

import 'package:dio/dio.dart';

class FeishuHttpResponse {
  final int status;
  final String body;
  const FeishuHttpResponse(this.status, this.body);
  dynamic get json => jsonDecode(body);
}

abstract class FeishuHttpClient {
  Future<FeishuHttpResponse> send(
    String method,
    String url, {
    Map<String, String> headers = const {},
    String? body,
  });
}

class DioFeishuHttpClient implements FeishuHttpClient {
  final Dio _dio;
  DioFeishuHttpClient([Dio? dio])
      : _dio = dio ??
            Dio(BaseOptions(
              validateStatus: (_) => true,
              responseType: ResponseType.plain,
            ));

  @override
  Future<FeishuHttpResponse> send(
    String method,
    String url, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    final res = await _dio.request<String>(
      url,
      data: body,
      options: Options(
        method: method,
        headers: headers,
        responseType: ResponseType.plain,
        validateStatus: (_) => true,
      ),
    );
    return FeishuHttpResponse(res.statusCode ?? 0, res.data ?? '');
  }
}
