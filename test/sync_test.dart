import 'package:flutter_test/flutter_test.dart';
import 'package:one_calendar/core/caldav/caldav_client.dart';
import 'package:one_calendar/core/feishu/feishu_api_client.dart';
import 'package:one_calendar/core/models/models.dart';
import 'package:one_calendar/core/storage/state_store.dart';
import 'package:one_calendar/core/sync/event_fingerprint.dart';
import 'package:one_calendar/core/sync/sync_engine.dart';
import 'package:one_calendar/core/sync/sync_plan.dart';

NormalizedEvent ev(String uid, {String title = 'T'}) => NormalizedEvent(
      uid: uid,
      title: title,
      start: DateTime.fromMillisecondsSinceEpoch(100000),
      end: DateTime.fromMillisecondsSinceEpoch(200000),
    );

class FakeFetcher implements CalendarEventFetcher {
  final List<NormalizedEvent> events;
  FakeFetcher(this.events);
  @override
  Future<List<NormalizedEvent>> fetchEvents(CalendarSyncSettings s, String p) async => events;
  @override
  Future<String> resolveCollectionUrl(String u, String p) async => 'x';
}

class RecordingWriter implements FeishuCalendarWriter {
  int created = 0, updated = 0, deleted = 0;
  @override
  Future<String> createEvent(NormalizedEvent e, String c) async {
    created++;
    return 'evt-${e.uid}';
  }

  @override
  Future<void> updateEvent(EventMapping m, NormalizedEvent e) async => updated++;
  @override
  Future<void> deleteEvent(EventMapping m) async => deleted++;
}

void main() {
  test('fingerprint stable + changes with content', () {
    final a = EventFingerprint.make(ev('u', title: 'A'));
    expect(a, EventFingerprint.make(ev('u', title: 'A')));
    expect(a == EventFingerprint.make(ev('u', title: 'B')), isFalse);
  });

  test('plan builder create/update/delete', () {
    final mappings = [
      EventMapping(
        dingTalkUid: 'keep',
        feishuEventId: 'f1',
        feishuCalendarId: 'c',
        source: 's',
        fingerprint: EventFingerprint.make(ev('keep', title: 'old')),
        lastStart: DateTime.fromMillisecondsSinceEpoch(0),
        lastEnd: DateTime.fromMillisecondsSinceEpoch(0),
        lastSeenAt: DateTime.fromMillisecondsSinceEpoch(0),
      ),
      EventMapping(
        dingTalkUid: 'gone',
        feishuEventId: 'f2',
        feishuCalendarId: 'c',
        source: 's',
        fingerprint: 'x',
        lastStart: DateTime.fromMillisecondsSinceEpoch(0),
        lastEnd: DateTime.fromMillisecondsSinceEpoch(0),
        lastSeenAt: DateTime.fromMillisecondsSinceEpoch(0),
      ),
    ];
    final plan = SyncPlanBuilder.build(
      events: [ev('keep', title: 'new'), ev('fresh')],
      mappings: mappings,
      deleteSyncEnabled: true,
    );
    expect(plan.toCreate.map((e) => e.uid), ['fresh']);
    expect(plan.toUpdate.map((u) => u.mapping.dingTalkUid), ['keep']);
    expect(plan.toDelete.map((m) => m.dingTalkUid), ['gone']);
  });

  test('engine creates and persists source-tagged mapping', () async {
    final store = StateStore.inMemory();
    final writer = RecordingWriter();
    final engine = SyncEngine(
      settings: const CalendarSyncSettings(
        toolId: 'calendar-sync',
        isEnabled: true,
        syncIntervalSeconds: 1800,
        syncWindowDays: 30,
        dingTalkUsername: 'u',
        feishuCalendarId: 'cal',
        deleteSyncEnabled: true,
      ),
      fetcher: FakeFetcher([ev('e1')]),
      writer: writer,
      store: store,
      password: () async => 'pw',
      sourceTag: 'neo-toolbox.tencent',
      now: () => DateTime.fromMillisecondsSinceEpoch(0),
    );
    final report = await engine.run(SyncTrigger.manual);
    expect(report.createdCount, 1);
    expect(writer.created, 1);
    final stored = store.loadEventMappings('cal', source: 'neo-toolbox.tencent');
    expect(stored.single.dingTalkUid, 'e1');
    store.dispose();
  });
}
