// Core value types ported from the Swift NeoToolboxCore models.

enum CalendarSourceKind {
  dingtalk,
  tencent;

  String get host => switch (this) {
        CalendarSourceKind.dingtalk => 'calendar.dingtalk.com',
        CalendarSourceKind.tencent => 'cal.meeting.tencent.com',
      };

  String get mappingTag => 'neo-toolbox.$name';

  String get displayName => switch (this) {
        CalendarSourceKind.dingtalk => 'DingTalk',
        CalendarSourceKind.tencent => 'Tencent Meeting',
      };

  /// Official help page explaining how to obtain CalDAV credentials.
  String get docUrl => switch (this) {
        CalendarSourceKind.dingtalk =>
          'https://alidocs.dingtalk.com/i/p/Y7kmbokZp3pgGLq2/docs/qXomz1wAyjKVXzxK6OdE83Y9pRBx5OrE?dontjump=true',
        CalendarSourceKind.tencent =>
          'https://meeting.tencent.com/support/topic/1654/index.html',
      };

  String get setupHint => switch (this) {
        CalendarSourceKind.dingtalk =>
          'In DingTalk: Calendar → Settings → enable CalDAV, then copy the username and password.',
        CalendarSourceKind.tencent =>
          'In Tencent Meeting: Calendar → CalDAV subscription, then copy the account and password.',
      };

  static CalendarSourceKind fromName(String raw) =>
      CalendarSourceKind.values.firstWhere((k) => k.name == raw,
          orElse: () => CalendarSourceKind.dingtalk);
}

class CalendarSource {
  final CalendarSourceKind kind;
  final String username;
  final String feishuCalendarId;
  final bool isEnabled;
  final String? resolvedCollectionUrl;

  const CalendarSource({
    required this.kind,
    required this.username,
    required this.feishuCalendarId,
    required this.isEnabled,
    this.resolvedCollectionUrl,
  });

  String get id => kind.name;
  bool get isConfigured => username.isNotEmpty && feishuCalendarId.isNotEmpty;
  String credentialAccount() => '${kind.name}:$username';

  CalendarSource copyWith({
    String? username,
    String? feishuCalendarId,
    bool? isEnabled,
    String? resolvedCollectionUrl,
  }) =>
      CalendarSource(
        kind: kind,
        username: username ?? this.username,
        feishuCalendarId: feishuCalendarId ?? this.feishuCalendarId,
        isEnabled: isEnabled ?? this.isEnabled,
        resolvedCollectionUrl: resolvedCollectionUrl ?? this.resolvedCollectionUrl,
      );

  @override
  bool operator ==(Object other) =>
      other is CalendarSource &&
      other.kind == kind &&
      other.username == username &&
      other.feishuCalendarId == feishuCalendarId &&
      other.isEnabled == isEnabled &&
      other.resolvedCollectionUrl == resolvedCollectionUrl;

  @override
  int get hashCode =>
      Object.hash(kind, username, feishuCalendarId, isEnabled, resolvedCollectionUrl);
}

class CalendarSyncSettings {
  final String toolId;
  final bool isEnabled;
  final int syncIntervalSeconds;
  final int syncWindowDays;
  final String dingTalkUsername;
  final String feishuCalendarId;
  final bool deleteSyncEnabled;

  const CalendarSyncSettings({
    required this.toolId,
    required this.isEnabled,
    required this.syncIntervalSeconds,
    required this.syncWindowDays,
    required this.dingTalkUsername,
    required this.feishuCalendarId,
    required this.deleteSyncEnabled,
  });

  static const defaultToolId = 'calendar-sync';
}

class CalendarSyncConfiguration {
  final List<CalendarSource> sources;
  final int syncIntervalSeconds;
  final int syncWindowDays;

  const CalendarSyncConfiguration({
    this.sources = const [],
    this.syncIntervalSeconds = 1800,
    this.syncWindowDays = 30,
  });

  CalendarSource? sourceFor(CalendarSourceKind kind) {
    for (final s in sources) {
      if (s.kind == kind) return s;
    }
    return null;
  }

  CalendarSyncSettings settingsFor(CalendarSource source) => CalendarSyncSettings(
        toolId: CalendarSyncSettings.defaultToolId,
        isEnabled: source.isEnabled,
        syncIntervalSeconds: syncIntervalSeconds,
        syncWindowDays: syncWindowDays,
        dingTalkUsername: source.username,
        feishuCalendarId: source.feishuCalendarId,
        deleteSyncEnabled: true,
      );
}

class NormalizedEvent {
  final String uid;
  final String? recurrenceId;
  final String title;
  final DateTime start;
  final DateTime end;
  final bool isAllDay;
  final String? location;
  final String? notes;

  const NormalizedEvent({
    required this.uid,
    this.recurrenceId,
    required this.title,
    required this.start,
    required this.end,
    this.isAllDay = false,
    this.location,
    this.notes,
  });
}

class EventMapping {
  static const calendarSyncSource = 'neo-toolbox.calendar-sync';

  final String dingTalkUid;
  final String? recurrenceId;
  final String feishuEventId;
  final String feishuCalendarId;
  final String source;
  final String fingerprint;
  final DateTime lastStart;
  final DateTime lastEnd;
  final DateTime lastSeenAt;

  const EventMapping({
    required this.dingTalkUid,
    this.recurrenceId,
    required this.feishuEventId,
    required this.feishuCalendarId,
    required this.source,
    required this.fingerprint,
    required this.lastStart,
    required this.lastEnd,
    required this.lastSeenAt,
  });

  String get mappingKey =>
      recurrenceId != null ? '$dingTalkUid#$recurrenceId' : dingTalkUid;
}

enum SyncTrigger { manual, timer }

enum DependencyStatus { available, missing }

class DependencyCheck {
  final DependencyStatus status;
  final String? executablePath;
  final String message;
  const DependencyCheck({
    required this.status,
    this.executablePath,
    required this.message,
  });
}

class SyncReport {
  final int createdCount;
  final int updatedCount;
  final int deletedCount;
  final DateTime startedAt;
  final DateTime finishedAt;
  final SyncTrigger trigger;

  const SyncReport({
    this.createdCount = 0,
    this.updatedCount = 0,
    this.deletedCount = 0,
    required this.startedAt,
    required this.finishedAt,
    required this.trigger,
  });
}

class FeishuCalendar {
  final String id;
  final String summary;
  const FeishuCalendar({required this.id, required this.summary});
}

enum SyncRunState { idle, running, failed }

class CalendarSyncStatus {
  final SyncRunState state;
  final String? failureMessage;
  final DateTime? lastSyncAt;
  const CalendarSyncStatus({
    this.state = SyncRunState.idle,
    this.failureMessage,
    this.lastSyncAt,
  });
}
