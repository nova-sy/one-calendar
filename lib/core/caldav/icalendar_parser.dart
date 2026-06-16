import '../models/models.dart';

/// Minimal iCalendar (RFC 5545) parser for VEVENTs, ported from the Swift
/// ICalendarParser. Handles UTC, TZID, and all-day DATE values.
class ICalendarParser {
  List<NormalizedEvent> parse(String calendar) {
    final lines = _unfold(calendar);
    final events = <NormalizedEvent>[];
    Map<String, _Prop>? current;
    for (final line in lines) {
      if (line == 'BEGIN:VEVENT') {
        current = {};
        continue;
      }
      if (line == 'END:VEVENT') {
        if (current != null) {
          final ev = _build(current);
          if (ev != null) events.add(ev);
        }
        current = null;
        continue;
      }
      if (current == null) continue;
      final colon = line.indexOf(':');
      if (colon < 0) continue;
      final namePart = line.substring(0, colon);
      final value = line.substring(colon + 1);
      final semi = namePart.indexOf(';');
      final name = (semi < 0 ? namePart : namePart.substring(0, semi)).toUpperCase();
      final params = semi < 0 ? '' : namePart.substring(semi + 1);
      current[name] = _Prop(value, params);
    }
    return events;
  }

  NormalizedEvent? _build(Map<String, _Prop> p) {
    final uid = p['UID']?.value;
    final start = p['DTSTART'];
    final end = p['DTEND'];
    if (uid == null || start == null) return null;
    final startDate = _parseDate(start);
    if (startDate == null) return null;
    final isAllDay = start.params.toUpperCase().contains('VALUE=DATE') &&
        !start.value.contains('T');
    final endDate = end != null ? _parseDate(end) : null;
    return NormalizedEvent(
      uid: uid,
      recurrenceId: p['RECURRENCE-ID']?.value,
      title: _unescape(p['SUMMARY']?.value ?? ''),
      start: startDate,
      end: endDate ?? startDate.add(const Duration(hours: 1)),
      isAllDay: isAllDay,
      location: p['LOCATION'] != null ? _unescape(p['LOCATION']!.value) : null,
      notes: p['DESCRIPTION'] != null ? _unescape(p['DESCRIPTION']!.value) : null,
    );
  }

  DateTime? _parseDate(_Prop prop) {
    final v = prop.value.trim();
    // All-day: yyyyMMdd
    if (!v.contains('T') && v.length == 8) {
      final y = int.tryParse(v.substring(0, 4));
      final mo = int.tryParse(v.substring(4, 6));
      final d = int.tryParse(v.substring(6, 8));
      if (y == null || mo == null || d == null) return null;
      return DateTime(y, mo, d);
    }
    // yyyyMMddТHHmmss(Z)
    final isUtc = v.endsWith('Z');
    final s = isUtc ? v.substring(0, v.length - 1) : v;
    if (s.length < 15) return null;
    final y = int.tryParse(s.substring(0, 4));
    final mo = int.tryParse(s.substring(4, 6));
    final d = int.tryParse(s.substring(6, 8));
    final h = int.tryParse(s.substring(9, 11));
    final mi = int.tryParse(s.substring(11, 13));
    final se = int.tryParse(s.substring(13, 15));
    if ([y, mo, d, h, mi, se].contains(null)) return null;
    if (isUtc) {
      return DateTime.utc(y!, mo!, d!, h!, mi!, se!).toLocal();
    }
    // TZID handling is best-effort: treat as local wall time.
    return DateTime(y!, mo!, d!, h!, mi!, se!);
  }

  /// Unfold RFC 5545 folded lines (continuation lines start with space/tab).
  List<String> _unfold(String text) {
    final raw = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    final out = <String>[];
    for (final line in raw) {
      if (line.isEmpty) continue;
      if ((line.startsWith(' ') || line.startsWith('\t')) && out.isNotEmpty) {
        out[out.length - 1] = out.last + line.substring(1);
      } else {
        out.add(line);
      }
    }
    return out;
  }

  String _unescape(String v) => v
      .replaceAll('\\n', '\n')
      .replaceAll('\\,', ',')
      .replaceAll('\\;', ';')
      .replaceAll('\\\\', '\\');
}

class _Prop {
  final String value;
  final String params;
  const _Prop(this.value, this.params);
}
