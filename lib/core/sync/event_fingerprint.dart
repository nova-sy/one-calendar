import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/models.dart';

/// Stable content hash of the fields that matter for change detection.
class EventFingerprint {
  static String make(NormalizedEvent e) {
    final parts = [
      e.title,
      e.start.toUtc().toIso8601String(),
      e.end.toUtc().toIso8601String(),
      e.isAllDay ? '1' : '0',
      e.location ?? '',
      e.notes ?? '',
    ].join('|');
    return sha256.convert(utf8.encode(parts)).toString();
  }
}
