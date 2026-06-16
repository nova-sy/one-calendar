import '../caldav/caldav_client.dart';
import '../feishu/feishu_api_client.dart';
import '../models/models.dart';
import '../storage/state_store.dart';
import 'event_fingerprint.dart';
import 'sync_plan.dart';

/// Runs one source's sync: fetch → plan → apply → persist mappings.
class SyncEngine {
  final CalendarSyncSettings settings;
  final CalendarEventFetcher fetcher;
  final FeishuCalendarWriter writer;
  final StateStore store;
  final Future<String> Function() password;
  final String sourceTag;
  final DateTime Function() now;

  SyncEngine({
    required this.settings,
    required this.fetcher,
    required this.writer,
    required this.store,
    required this.password,
    this.sourceTag = EventMapping.calendarSyncSource,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  Future<SyncReport> run(SyncTrigger trigger) async {
    final startedAt = now();
    final pw = await password();
    final events = await fetcher.fetchEvents(settings, pw);
    final mappings =
        store.loadEventMappings(settings.feishuCalendarId, source: sourceTag);
    final plan = SyncPlanBuilder.build(
      events: events,
      mappings: mappings,
      deleteSyncEnabled: settings.deleteSyncEnabled,
    );

    var created = 0, updated = 0, deleted = 0;

    for (final e in plan.toCreate) {
      final eventId = await writer.createEvent(e, settings.feishuCalendarId);
      store.upsertEventMapping(_mappingFor(e, eventId));
      created++;
    }
    for (final u in plan.toUpdate) {
      await writer.updateEvent(u.mapping, u.event);
      store.upsertEventMapping(_mappingFor(u.event, u.mapping.feishuEventId));
      updated++;
    }
    for (final m in plan.toDelete) {
      await writer.deleteEvent(m);
      store.archiveEventMapping(m.mappingKey);
      deleted++;
    }

    return SyncReport(
      createdCount: created,
      updatedCount: updated,
      deletedCount: deleted,
      startedAt: startedAt,
      finishedAt: now(),
      trigger: trigger,
    );
  }

  EventMapping _mappingFor(NormalizedEvent e, String feishuEventId) => EventMapping(
        dingTalkUid: e.uid,
        recurrenceId: e.recurrenceId,
        feishuEventId: feishuEventId,
        feishuCalendarId: settings.feishuCalendarId,
        source: sourceTag,
        fingerprint: EventFingerprint.make(e),
        lastStart: e.start,
        lastEnd: e.end,
        lastSeenAt: now(),
      );
}
