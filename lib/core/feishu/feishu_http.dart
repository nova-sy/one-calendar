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
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
      }
      try {
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
      } on DioException catch (e) {
        lastError = e;
        final msg = e.error?.toString() ?? e.message ?? '';
        final transient = e.type == DioExceptionType.connectionError ||
            e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.receiveTimeout ||
            msg.contains('HandshakeException') ||
            msg.contains('Connection terminated') ||
            msg.contains('Connection reset');
        if (!transient) rethrow;
      }
    }
    throw lastError ?? Exception('Feishu request failed');
  }
}
