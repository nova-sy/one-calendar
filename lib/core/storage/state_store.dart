import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../models/models.dart';

class GlobalSettings {
  final int syncIntervalSeconds;
  final int syncWindowDays;
  final DateTime? lastSuccessfulSyncAt;
  final int consecutiveFailureCount;

  const GlobalSettings({
    this.syncIntervalSeconds = 1800,
    this.syncWindowDays = 30,
    this.lastSuccessfulSyncAt,
    this.consecutiveFailureCount = 0,
  });
}

class SecretRow {
  final Uint8List ciphertext;
  final Uint8List nonce;
  const SecretRow(this.ciphertext, this.nonce);
}

/// SQLite-backed store. Mirrors the Swift SQLiteStateStore schema.
class StateStore {
  final Database _db;
  StateStore(this._db) {
    _migrate();
  }

  factory StateStore.open(String path) => StateStore(sqlite3.open(path));
  factory StateStore.inMemory() => StateStore(sqlite3.openInMemory());

  void dispose() => _db.dispose();

  void _migrate() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS tool_settings (
        tool_id TEXT PRIMARY KEY,
        sync_interval_seconds INTEGER NOT NULL,
        sync_window_days INTEGER NOT NULL,
        last_successful_sync_at REAL,
        consecutive_failure_count INTEGER NOT NULL
      )''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS calendar_sources (
        source_id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        label TEXT NOT NULL DEFAULT '',
        username TEXT NOT NULL,
        feishu_calendar_id TEXT NOT NULL,
        is_enabled INTEGER NOT NULL,
        resolved_collection_url TEXT
      )''');
    // Add `label` to pre-existing tables created before multi-account support.
    final cols = _db.select('PRAGMA table_info(calendar_sources)');
    if (!cols.any((r) => r['name'] == 'label')) {
      _db.execute("ALTER TABLE calendar_sources ADD COLUMN label TEXT NOT NULL DEFAULT ''");
    }
    _db.execute('''
      CREATE TABLE IF NOT EXISTS event_mappings (
        mapping_key TEXT PRIMARY KEY,
        dingtalk_uid TEXT NOT NULL,
        recurrence_id TEXT,
        feishu_event_id TEXT NOT NULL,
        feishu_calendar_id TEXT NOT NULL,
        source TEXT NOT NULL,
        fingerprint TEXT NOT NULL,
        last_start REAL NOT NULL,
        last_end REAL NOT NULL,
        last_seen_at REAL NOT NULL,
        archived INTEGER NOT NULL DEFAULT 0
      )''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS secrets (
        account TEXT PRIMARY KEY,
        ciphertext BLOB NOT NULL,
        nonce BLOB NOT NULL
      )''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS runtime_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ts REAL NOT NULL,
        level TEXT NOT NULL,
        message TEXT NOT NULL
      )''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS app_preferences (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )''');
  }

  // --- App preferences (generic key/value) ---

  String? getPreference(String key) {
    final r = _db.select('SELECT value FROM app_preferences WHERE key = ?', [key]);
    if (r.isEmpty) return null;
    return r.first['value'] as String;
  }

  void setPreference(String key, String value) {
    _db.execute(
      'INSERT INTO app_preferences (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [key, value],
    );
  }

  void appendLog(DateTime ts, String level, String message) {
    _db.execute('INSERT INTO runtime_logs (ts, level, message) VALUES (?, ?, ?)',
        [ts.millisecondsSinceEpoch / 1000.0, level, message]);
    // Keep only the most recent 200.
    _db.execute(
        'DELETE FROM runtime_logs WHERE id NOT IN (SELECT id FROM runtime_logs ORDER BY id DESC LIMIT 200)');
  }

  List<({DateTime ts, String level, String message})> loadRecentLogs({int limit = 100}) {
    final r = _db.select('SELECT * FROM runtime_logs ORDER BY id DESC LIMIT ?', [limit]);
    return r
        .map((row) => (
              ts: DateTime.fromMillisecondsSinceEpoch(((row['ts'] as double) * 1000).round()),
              level: row['level'] as String,
              message: row['message'] as String,
            ))
        .toList();
  }

  // --- Global settings ---

  void saveGlobalSettings(GlobalSettings s) {
    _db.execute(
      '''INSERT INTO tool_settings (tool_id, sync_interval_seconds, sync_window_days, last_successful_sync_at, consecutive_failure_count)
         VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(tool_id) DO UPDATE SET
           sync_interval_seconds = excluded.sync_interval_seconds,
           sync_window_days = excluded.sync_window_days,
           last_successful_sync_at = excluded.last_successful_sync_at,
           consecutive_failure_count = excluded.consecutive_failure_count''',
      [
        CalendarSyncSettings.defaultToolId,
        s.syncIntervalSeconds,
        s.syncWindowDays,
        s.lastSuccessfulSyncAt?.millisecondsSinceEpoch == null
            ? null
            : s.lastSuccessfulSyncAt!.millisecondsSinceEpoch / 1000.0,
        s.consecutiveFailureCount,
      ],
    );
  }

  GlobalSettings? loadGlobalSettings() {
    final r = _db.select(
        'SELECT * FROM tool_settings WHERE tool_id = ?', [CalendarSyncSettings.defaultToolId]);
    if (r.isEmpty) return null;
    final row = r.first;
    final last = row['last_successful_sync_at'] as double?;
    return GlobalSettings(
      syncIntervalSeconds: row['sync_interval_seconds'] as int,
      syncWindowDays: row['sync_window_days'] as int,
      lastSuccessfulSyncAt: last == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch((last * 1000).round()),
      consecutiveFailureCount: row['consecutive_failure_count'] as int,
    );
  }

  // --- Calendar sources ---

  void saveCalendarSource(CalendarSource s) {
    _db.execute(
      '''INSERT INTO calendar_sources (source_id, kind, label, username, feishu_calendar_id, is_enabled, resolved_collection_url)
         VALUES (?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(source_id) DO UPDATE SET
           kind = excluded.kind, label = excluded.label, username = excluded.username,
           feishu_calendar_id = excluded.feishu_calendar_id,
           is_enabled = excluded.is_enabled,
           resolved_collection_url = excluded.resolved_collection_url''',
      [s.id, s.kind.name, s.label, s.username, s.feishuCalendarId, s.isEnabled ? 1 : 0, s.resolvedCollectionUrl],
    );
  }

  List<CalendarSource> loadCalendarSources() {
    final r = _db.select('SELECT * FROM calendar_sources ORDER BY source_id');
    return r
        .map((row) => CalendarSource(
              id: row['source_id'] as String,
              kind: CalendarSourceKind.fromName(row['kind'] as String),
              label: (row['label'] as String?) ?? '',
              username: row['username'] as String,
              feishuCalendarId: row['feishu_calendar_id'] as String,
              isEnabled: (row['is_enabled'] as int) == 1,
              resolvedCollectionUrl: row['resolved_collection_url'] as String?,
            ))
        .toList();
  }

  void deleteCalendarSource(String id) =>
      _db.execute('DELETE FROM calendar_sources WHERE source_id = ?', [id]);

  // --- Event mappings ---

  void upsertEventMapping(EventMapping m) {
    _db.execute(
      '''INSERT INTO event_mappings
         (mapping_key, dingtalk_uid, recurrence_id, feishu_event_id, feishu_calendar_id, source, fingerprint, last_start, last_end, last_seen_at, archived)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
         ON CONFLICT(mapping_key) DO UPDATE SET
           feishu_event_id = excluded.feishu_event_id,
           feishu_calendar_id = excluded.feishu_calendar_id,
           source = excluded.source,
           fingerprint = excluded.fingerprint,
           last_start = excluded.last_start, last_end = excluded.last_end,
           last_seen_at = excluded.last_seen_at, archived = 0''',
      [
        m.mappingKey, m.dingTalkUid, m.recurrenceId, m.feishuEventId,
        m.feishuCalendarId, m.source, m.fingerprint,
        m.lastStart.millisecondsSinceEpoch / 1000.0,
        m.lastEnd.millisecondsSinceEpoch / 1000.0,
        m.lastSeenAt.millisecondsSinceEpoch / 1000.0,
      ],
    );
  }

  List<EventMapping> loadEventMappings(String calendarId, {String? source}) {
    final ResultSet r;
    if (source != null) {
      r = _db.select(
          'SELECT * FROM event_mappings WHERE feishu_calendar_id = ? AND source = ? AND archived = 0 ORDER BY mapping_key',
          [calendarId, source]);
    } else {
      r = _db.select(
          'SELECT * FROM event_mappings WHERE feishu_calendar_id = ? AND archived = 0 ORDER BY mapping_key',
          [calendarId]);
    }
    return r.map(_readMapping).toList();
  }

  void archiveEventMapping(String mappingKey) =>
      _db.execute('UPDATE event_mappings SET archived = 1 WHERE mapping_key = ?', [mappingKey]);

  EventMapping _readMapping(Row row) => EventMapping(
        dingTalkUid: row['dingtalk_uid'] as String,
        recurrenceId: row['recurrence_id'] as String?,
        feishuEventId: row['feishu_event_id'] as String,
        feishuCalendarId: row['feishu_calendar_id'] as String,
        source: row['source'] as String,
        fingerprint: row['fingerprint'] as String,
        lastStart: DateTime.fromMillisecondsSinceEpoch(((row['last_start'] as double) * 1000).round()),
        lastEnd: DateTime.fromMillisecondsSinceEpoch(((row['last_end'] as double) * 1000).round()),
        lastSeenAt: DateTime.fromMillisecondsSinceEpoch(((row['last_seen_at'] as double) * 1000).round()),
      );

  // --- Secrets ---

  void saveSecret(String account, Uint8List ciphertext, Uint8List nonce) {
    _db.execute(
      'INSERT INTO secrets (account, ciphertext, nonce) VALUES (?, ?, ?) ON CONFLICT(account) DO UPDATE SET ciphertext = excluded.ciphertext, nonce = excluded.nonce',
      [account, ciphertext, nonce],
    );
  }

  SecretRow? loadSecret(String account) {
    final r = _db.select('SELECT ciphertext, nonce FROM secrets WHERE account = ?', [account]);
    if (r.isEmpty) return null;
    return SecretRow(r.first['ciphertext'] as Uint8List, r.first['nonce'] as Uint8List);
  }

  void deleteSecret(String account) =>
      _db.execute('DELETE FROM secrets WHERE account = ?', [account]);
}
