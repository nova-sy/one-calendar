import 'package:flutter_test/flutter_test.dart';
import 'package:one_calendar/core/caldav/caldav_client.dart';
import 'package:one_calendar/core/caldav/caldav_discovery.dart';
import 'package:one_calendar/core/caldav/caldav_transport.dart';
import 'package:one_calendar/core/caldav/icalendar_parser.dart';
import 'package:one_calendar/core/models/models.dart';

class RecordingTransport implements CalDavTransport {
  final String Function(String path) handler;
  String? lastUrl;
  String? lastMethod;
  RecordingTransport(this.handler);
  @override
  Future<CalDavResponse> send(String method, String url,
      {Map<String, String> headers = const {}, String? body}) async {
    lastUrl = url;
    lastMethod = method;
    final path = Uri.parse(url).path;
    return CalDavResponse(207, handler(path));
  }
}

void main() {
  test('parses entity-encoded calendar-data with & and CR', () {
    const body = '''
<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
<d:response><d:propstat><d:prop>
<c:calendar-data>BEGIN:VCALENDAR&#13;
BEGIN:VEVENT&#13;
UID:enc-1&#13;
SUMMARY:Design &amp; Review&#13;
DTSTART:20260616T020000Z&#13;
DTEND:20260616T030000Z&#13;
END:VEVENT&#13;
END:VCALENDAR&#13;
</c:calendar-data>
</d:prop></d:propstat></d:response></d:multistatus>''';
    final data = extractCalendarData(body);
    final events = data.expand(ICalendarParser().parse).toList();
    expect(events.map((e) => e.uid), ['enc-1']);
    expect(events.first.title, 'Design & Review');
  });

  test('fixed-path client targets primary collection', () async {
    final transport = RecordingTransport((_) =>
        '<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"></d:multistatus>');
    final client = makeCalDavClient(CalendarSourceKind.dingtalk, transport: transport);
    const settings = CalendarSyncSettings(
        toolId: 'calendar-sync',
        isEnabled: true,
        syncIntervalSeconds: 900,
        syncWindowDays: 30,
        dingTalkUsername: 'ding-user',
        feishuCalendarId: 'c',
        deleteSyncEnabled: true);
    await client.fetchEvents(settings, 'secret');
    expect(transport.lastUrl, 'https://calendar.dingtalk.com/dav/ding-user/primary/');
    expect(transport.lastMethod, 'REPORT');
  });

  test('discovery walks the chain to the collection', () async {
    const principal =
        '<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:response><d:href>/caldav</d:href><d:propstat><d:prop>'
        '<d:current-user-principal><d:href>/caldav/me/</d:href></d:current-user-principal>'
        '<c:calendar-home-set><d:href>/caldav/me/calendar</d:href></c:calendar-home-set>'
        '</d:prop></d:propstat></d:response></d:multistatus>';
    const home =
        '<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">'
        '<d:response><d:href>/caldav/me/calendar/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>'
        '<d:response><d:href>/caldav/me/calendar/abc123/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/><c:calendar/></d:resourcetype></d:prop></d:propstat></d:response>'
        '</d:multistatus>';
    final transport = RecordingTransport((path) =>
        path.endsWith('/calendar') ? home : principal);
    final url = await CalDavDiscovery(transport).discoverCalendarCollection(
        host: 'cal.meeting.tencent.com', username: 'Cal_x@cal.meeting.tencent.com', password: 'p');
    expect(url.endsWith('/caldav/me/calendar/abc123/'), isTrue);
  });
}
