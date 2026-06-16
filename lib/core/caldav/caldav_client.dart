import 'package:intl/intl.dart';

import '../models/models.dart';
import 'caldav_discovery.dart';
import 'caldav_transport.dart';
import 'icalendar_parser.dart';

/// Abstraction the sync engine consumes for fetching source events.
abstract class CalendarEventFetcher {
  Future<List<NormalizedEvent>> fetchEvents(
      CalendarSyncSettings settings, String password);
  Future<String> resolveCollectionUrl(String username, String password);
}

enum CollectionStrategyKind { fixedPath, discover }

class CollectionStrategy {
  final CollectionStrategyKind kind;
  final String? template; // for fixedPath, contains {user}
  const CollectionStrategy.fixedPath(this.template)
      : kind = CollectionStrategyKind.fixedPath;
  const CollectionStrategy.discover()
      : kind = CollectionStrategyKind.discover,
        template = null;
}

/// Provider-agnostic CalDAV client. Resolves the collection from a fixed path
/// (DingTalk) or via discovery (Tencent), then REPORTs a time-ranged query.
class CalDavCalendarClient implements CalendarEventFetcher {
  final String host;
  final CollectionStrategy strategy;
  final CalDavTransport transport;
  final ICalendarParser parser;
  final DateTime Function() now;

  CalDavCalendarClient({
    required this.host,
    required this.strategy,
    required this.transport,
    ICalendarParser? parser,
    DateTime Function()? now,
  })  : parser = parser ?? ICalendarParser(),
        now = now ?? DateTime.now;

  @override
  Future<String> resolveCollectionUrl(String username, String password) async {
    switch (strategy.kind) {
      case CollectionStrategyKind.fixedPath:
        final path = strategy.template!.replaceAll('{user}', username);
        return 'https://$host$path';
      case CollectionStrategyKind.discover:
        return CalDavDiscovery(transport).discoverCalendarCollection(
            host: host, username: username, password: password);
    }
  }

  @override
  Future<List<NormalizedEvent>> fetchEvents(
      CalendarSyncSettings settings, String password) async {
    final url = await resolveCollectionUrl(settings.dingTalkUsername, password);
    final res = await transport.send('REPORT', url, headers: {
      'Authorization': basicAuth(settings.dingTalkUsername, password),
      'Depth': '1',
      'Content-Type': 'application/xml; charset=utf-8',
    }, body: _reportBody(settings.syncWindowDays));
    final data = extractCalendarData(res.body);
    return data.expand(parser.parse).toList();
  }

  String _reportBody(int windowDays) {
    final start = now().toUtc().subtract(const Duration(days: 1));
    final end = now().toUtc().add(Duration(days: windowDays));
    final fmt = DateFormat("yyyyMMdd'T'HHmmss'Z'");
    return '''<?xml version="1.0" encoding="utf-8"?>
<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop><d:getetag /><c:calendar-data /></d:prop>
  <c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT">
    <c:time-range start="${fmt.format(start)}" end="${fmt.format(end)}" />
  </c:comp-filter></c:comp-filter></c:filter>
</c:calendar-query>''';
  }
}

/// Extracts and entity-decodes <calendar-data> payloads from a multistatus body.
List<String> extractCalendarData(String body) {
  final pattern = RegExp(
    r'<[^>]*calendar-data[^>]*>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</[^>]*calendar-data>',
    dotAll: true,
  );
  return pattern
      .allMatches(body)
      .map((m) => decodeXml(m.group(1) ?? '').trim())
      .toList();
}

String decodeXml(String value) => value
    .replaceAll('&#13;', '\r')
    .replaceAll('&#10;', '\n')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

CalDavCalendarClient makeCalDavClient(
  CalendarSourceKind kind, {
  required CalDavTransport transport,
  DateTime Function()? now,
}) {
  switch (kind) {
    case CalendarSourceKind.dingtalk:
      return CalDavCalendarClient(
        host: kind.host,
        strategy: const CollectionStrategy.fixedPath('/dav/{user}/primary/'),
        transport: transport,
        now: now,
      );
    case CalendarSourceKind.tencent:
      return CalDavCalendarClient(
        host: kind.host,
        strategy: const CollectionStrategy.discover(),
        transport: transport,
        now: now,
      );
  }
}
