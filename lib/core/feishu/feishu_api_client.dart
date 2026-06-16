import 'dart:convert';

import '../models/models.dart';
import 'feishu_http.dart';
import 'feishu_oauth.dart';
import 'feishu_token_manager.dart';

/// Interfaces the sync engine consumes for the Feishu (destination) side.
abstract class FeishuCalendarProvider {
  Future<DependencyCheck> checkDependency();
  Future<List<FeishuCalendar>> listCalendars();
}

abstract class FeishuCalendarWriter {
  Future<String> createEvent(NormalizedEvent event, String calendarId);
  Future<void> updateEvent(EventMapping mapping, NormalizedEvent event);
  Future<void> deleteEvent(EventMapping mapping);
}

/// Native Feishu Calendar v4 API client (user access token, 401 → refresh+retry).
class FeishuApiClient implements FeishuCalendarProvider, FeishuCalendarWriter {
  final FeishuHttpClient http;
  final FeishuTokenManager tokens;
  static const _base = 'https://open.feishu.cn/open-apis/calendar/v4';

  FeishuApiClient({FeishuHttpClient? http, required this.tokens})
      : http = http ?? DioFeishuHttpClient();

  @override
  Future<DependencyCheck> checkDependency() async {
    if (!await tokens.hasAppCredentials()) {
      return const DependencyCheck(
          status: DependencyStatus.missing,
          message: 'Enter Feishu App ID and Secret in Settings');
    }
    if (!await tokens.isAuthorized()) {
      return const DependencyCheck(
          status: DependencyStatus.missing, message: 'Authorize Feishu in Settings');
    }
    return const DependencyCheck(
        status: DependencyStatus.available, message: 'Feishu authorized');
  }

  @override
  Future<List<FeishuCalendar>> listCalendars() async {
    final j = await _call('GET', '/calendars');
    final list = (j['data']?['calendar_list'] as List?) ?? [];
    return list
        .map((e) => FeishuCalendar(
            id: e['calendar_id'] as String, summary: (e['summary'] as String?) ?? ''))
        .toList();
  }

  @override
  Future<String> createEvent(NormalizedEvent event, String calendarId) async {
    final j = await _call('POST', '/calendars/$calendarId/events', body: _eventBody(event));
    final id = j['data']?['event']?['event_id'] as String?;
    if (id == null) throw FeishuAuthException('missing event_id');
    return id;
  }

  @override
  Future<void> updateEvent(EventMapping mapping, NormalizedEvent event) async {
    await _call('PATCH',
        '/calendars/${mapping.feishuCalendarId}/events/${mapping.feishuEventId}',
        body: _eventBody(event));
  }

  @override
  Future<void> deleteEvent(EventMapping mapping) async {
    await _call('DELETE',
        '/calendars/${mapping.feishuCalendarId}/events/${mapping.feishuEventId}');
  }

  String _eventBody(NormalizedEvent event) => jsonEncode({
        'summary': event.title,
        'start_time': {'timestamp': (event.start.millisecondsSinceEpoch ~/ 1000).toString()},
        'end_time': {'timestamp': (event.end.millisecondsSinceEpoch ~/ 1000).toString()},
      });

  Future<Map<String, dynamic>> _call(String method, String path, {String? body}) async {
    Future<FeishuHttpResponse> once(String token) => http.send(method, '$_base$path',
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json; charset=utf-8',
        },
        body: body);

    var token = await tokens.validAccessToken();
    var res = await once(token);
    if (res.status == 401) {
      await tokens.clearAccessOnly();
      token = await tokens.validAccessToken();
      res = await once(token);
    }
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final code = j['code'] as int?;
    if (code != null && code != 0) {
      throw FeishuAuthException((j['msg'] as String?) ?? 'Feishu API error $code');
    }
    return j;
  }
}
