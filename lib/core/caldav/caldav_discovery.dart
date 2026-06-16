import 'caldav_transport.dart';

class CalDavDiscoveryException implements Exception {
  final String message;
  CalDavDiscoveryException(this.message);
  @override
  String toString() => 'CalDavDiscoveryException: $message';
}

/// Walks the standard CalDAV discovery chain: PROPFIND the well-known root for
/// the principal + calendar-home-set, then PROPFIND the home (Depth 1) for the
/// first calendar collection. Ported from the Swift CalDAVDiscovery.
class CalDavDiscovery {
  final CalDavTransport transport;
  CalDavDiscovery(this.transport);

  Future<String> discoverCalendarCollection({
    required String host,
    required String username,
    required String password,
  }) async {
    final homeHref = await _propfindHome(host, username, password);
    final homeUrl = _absolute(host, homeHref);
    final collectionHref = await _propfindFirstCalendar(homeUrl, username, password);
    return _absolute(host, collectionHref);
  }

  Future<String> _propfindHome(String host, String username, String password) async {
    const body =
        '<?xml version="1.0"?><d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">'
        '<d:prop><d:current-user-principal/><c:calendar-home-set/></d:prop></d:propfind>';
    final res = await _send('PROPFIND', _absolute(host, '/caldav/'), '0', username, password, body);
    final home = _firstHrefAfter(res.body, 'calendar-home-set');
    if (home != null) return home;
    final principal = _firstHrefAfter(res.body, 'current-user-principal');
    if (principal != null) return principal;
    throw CalDavDiscoveryException('no calendar-home-set');
  }

  Future<String> _propfindFirstCalendar(String url, String username, String password) async {
    const body =
        '<?xml version="1.0"?><d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">'
        '<d:prop><d:resourcetype/><d:displayname/></d:prop></d:propfind>';
    final res = await _send('PROPFIND', url, '1', username, password, body);
    final href = _firstCalendarHref(res.body);
    if (href == null) throw CalDavDiscoveryException('no calendar collection');
    return href;
  }

  Future<CalDavResponse> _send(String method, String url, String depth, String username,
      String password, String body) {
    return transport.send(method, url, headers: {
      'Authorization': basicAuth(username, password),
      'Depth': depth,
      'Content-Type': 'application/xml; charset=utf-8',
    }, body: body);
  }

  String _absolute(String host, String path) {
    if (path.startsWith('http')) return path;
    return 'https://$host$path';
  }

  String? _firstHrefAfter(String xml, String tag) {
    final i = xml.indexOf(tag);
    if (i < 0) return null;
    return _firstHref(xml.substring(i));
  }

  String? _firstHref(String xml) {
    final open = xml.toLowerCase().indexOf('href>');
    if (open < 0) return null;
    final rest = xml.substring(open + 'href>'.length);
    final close = rest.indexOf('<');
    if (close < 0) return null;
    return rest.substring(0, close).trim();
  }

  String? _firstCalendarHref(String xml) {
    var start = 0;
    while (true) {
      final open = xml.indexOf('response>', start);
      if (open < 0) break;
      final close = xml.indexOf('response>', open + 'response>'.length);
      if (close < 0) break;
      final segment = xml.substring(open + 'response>'.length, close);
      final lower = segment.toLowerCase();
      if (lower.contains('href') &&
          (lower.contains(':calendar/') || lower.contains('<calendar'))) {
        final href = _firstHref(segment);
        if (href != null) return href;
      }
      start = close + 'response>'.length;
    }
    return null;
  }
}
