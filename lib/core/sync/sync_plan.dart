import '../models/models.dart';
import 'event_fingerprint.dart';

class SyncPlan {
  final List<NormalizedEvent> toCreate;
  final List<({EventMapping mapping, NormalizedEvent event})> toUpdate;
  final List<EventMapping> toDelete;
  const SyncPlan(this.toCreate, this.toUpdate, this.toDelete);
}

/// Diffs fetched events against existing mappings to produce create/update/
/// delete actions. Deletes only mappings whose event vanished from the source.
class SyncPlanBuilder {
  static SyncPlan build({
    required List<NormalizedEvent> events,
    required List<EventMapping> mappings,
    required bool deleteSyncEnabled,
  }) {
    final byKey = {for (final m in mappings) m.mappingKey: m};
    final seen = <String>{};
    final toCreate = <NormalizedEvent>[];
    final toUpdate = <({EventMapping mapping, NormalizedEvent event})>[];

    for (final e in events) {
      final key = e.recurrenceId != null ? '${e.uid}#${e.recurrenceId}' : e.uid;
      seen.add(key);
      final existing = byKey[key];
      if (existing == null) {
        toCreate.add(e);
      } else if (existing.fingerprint != EventFingerprint.make(e)) {
        toUpdate.add((mapping: existing, event: e));
      }
    }

    final toDelete = deleteSyncEnabled
        ? mappings.where((m) => !seen.contains(m.mappingKey)).toList()
        : <EventMapping>[];

    return SyncPlan(toCreate, toUpdate, toDelete);
  }
}
