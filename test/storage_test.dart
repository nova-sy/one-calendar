import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:one_calendar/core/models/models.dart';
import 'package:one_calendar/core/storage/state_store.dart';

void main() {
  test('source kind tag and host', () {
    expect(CalendarSourceKind.dingtalk.mappingTag, 'neo-toolbox.dingtalk');
    expect(CalendarSourceKind.tencent.mappingTag, 'neo-toolbox.tencent');
    expect(CalendarSourceKind.dingtalk.host, 'calendar.dingtalk.com');
    expect(CalendarSourceKind.tencent.host, 'cal.meeting.tencent.com');
  });

  test('derived per-source settings', () {
    const source = CalendarSource(
        id: 'dingtalk',
        kind: CalendarSourceKind.dingtalk,
        username: 'alice',
        feishuCalendarId: 'cal-1',
        isEnabled: true);
    const config = CalendarSyncConfiguration(
        sources: [source], syncIntervalSeconds: 600, syncWindowDays: 14);
    final s = config.settingsFor(source);
    expect(s.dingTalkUsername, 'alice');
    expect(s.feishuCalendarId, 'cal-1');
    expect(s.syncIntervalSeconds, 600);
    expect(s.syncWindowDays, 14);
  });

  test('calendar source persistence round trip', () {
    final store = StateStore.inMemory();
    const source = CalendarSource(
        id: 'tencent',
        kind: CalendarSourceKind.tencent,
        username: 'Cal_x',
        feishuCalendarId: 'c9',
        isEnabled: true,
        resolvedCollectionUrl: 'https://h/col/');
    store.saveCalendarSource(source);
    expect(store.loadCalendarSources(), [source]);
    store.deleteCalendarSource('tencent');
    expect(store.loadCalendarSources(), isEmpty);
    store.dispose();
  });

  test('event mappings isolate by source', () {
    final store = StateStore.inMemory();
    EventMapping m(String uid, String source) => EventMapping(
          dingTalkUid: uid,
          feishuEventId: 'f-$uid',
          feishuCalendarId: 'shared',
          source: source,
          fingerprint: 'fp',
          lastStart: DateTime.fromMillisecondsSinceEpoch(0),
          lastEnd: DateTime.fromMillisecondsSinceEpoch(60000),
          lastSeenAt: DateTime.fromMillisecondsSinceEpoch(0),
        );
    store.upsertEventMapping(m('a', 'neo-toolbox.dingtalk'));
    store.upsertEventMapping(m('b', 'neo-toolbox.tencent'));
    final ding = store.loadEventMappings('shared', source: 'neo-toolbox.dingtalk');
    expect(ding.map((e) => e.dingTalkUid), ['a']);
    final all = store.loadEventMappings('shared');
    expect(all.map((e) => e.dingTalkUid).toSet(), {'a', 'b'});
    store.dispose();
  });

  test('secret round trip', () {
    final store = StateStore.inMemory();
    store.saveSecret('a', Uint8List.fromList([1, 2, 3]), Uint8List.fromList([9]));
    final got = store.loadSecret('a');
    expect(got!.ciphertext, Uint8List.fromList([1, 2, 3]));
    expect(got.nonce, Uint8List.fromList([9]));
    store.deleteSecret('a');
    expect(store.loadSecret('a'), isNull);
    store.dispose();
  });

  test('runtime logs persist and load recent', () {
    final store = StateStore.inMemory();
    store.appendLog(DateTime.fromMillisecondsSinceEpoch(1000), 'info', 'first');
    store.appendLog(DateTime.fromMillisecondsSinceEpoch(2000), 'error', 'second');
    final logs = store.loadRecentLogs(limit: 10);
    expect(logs.first.message, 'second');
    expect(logs.first.level, 'error');
    expect(logs.last.message, 'first');
    store.dispose();
  });

  test('global settings round trip', () {
    final store = StateStore.inMemory();
    store.saveGlobalSettings(const GlobalSettings(syncIntervalSeconds: 600, syncWindowDays: 7));
    final g = store.loadGlobalSettings();
    expect(g!.syncIntervalSeconds, 600);
    expect(g.syncWindowDays, 7);
    store.dispose();
  });
}
