# Multi-Source CalDAV (DingTalk + Tencent Meeting) Design

Date: 2026-06-16
Status: Approved design, pending implementation plan

## Problem

The Calendar Sync tool fetches from a single hard-coded source (DingTalk) and
syncs into one Feishu calendar. The user wants Tencent Meeting added as a
**second, parallel source**: both DingTalk and Tencent events sync into Feishu,
each source choosing its own Feishu target calendar (which may be the same or
different).

## Verified protocol facts

Both providers run standard CalDAV (calendar-query REPORT with a required
`time-range` filter). Discovery and collection layout differ:

| | DingTalk | Tencent Meeting |
|---|---|---|
| Host | `calendar.dingtalk.com` | `cal.meeting.tencent.com` |
| Auth username | the CalDAV username (e.g. `u_xxx`) | full `Cal_xxx@cal.meeting.tencent.com` |
| `.well-known/caldav` | redirects into `/dav/` | redirects to `/caldav/` |
| Principal | `/dav/users/{user}` | `/caldav/{localpart}/` (local part before `@`) |
| Calendar-home | `/dav/{user}` | `/caldav/{localpart}/calendar` |
| Target collection | fixed `…/{user}/primary/` | **dynamic id**, e.g. `…/calendar/g5v03kO7l4lGD`, must be discovered |
| REPORT result | 207 + VEVENTs (verified) | 207 + VEVENTs (verified, 68 events) |

Key consequence: DingTalk's collection path is fixed and already verified;
Tencent's collection id is generated and must be discovered via PROPFIND.

## Goals

- Add Tencent Meeting as a second CalDAV source alongside DingTalk.
- Each source has independent config: username, password, target Feishu
  calendar, enable toggle. Either source can be enabled/disabled on its own.
- Both sources can target the same Feishu calendar or different ones.
- Per-source sync isolation: a source's run must never delete another source's
  events, even when both write into the same Feishu calendar.
- Preserve the existing, verified DingTalk behavior.

## Non-Goals

- Adding sources beyond DingTalk and Tencent (the model is extensible, but no
  third provider is built now).
- Two-way sync, or syncing Feishu back to the sources.
- Per-source sync interval/window (interval and window stay global).

## Decisions (from brainstorming)

- Tencent is a **second parallel source**; both sync into Feishu.
- **Per-source target calendar** — each source selects its own Feishu calendar,
  same or different.
- CalDAV collection resolution is **per-source strategy**: DingTalk keeps its
  fixed `/dav/{user}/primary/` path; Tencent uses **discovery** (well-known →
  principal → calendar-home-set → first calendar collection).

## Architecture

### 1. Source model — `CalendarSource` (NeoToolboxCore)

```
public enum CalendarSourceKind: String, Codable, Sendable {
    case dingtalk
    case tencent
}

public struct CalendarSource: Equatable, Sendable, Identifiable {
    public var id: String                 // == kind.rawValue (one row per kind)
    public var kind: CalendarSourceKind
    public var username: String
    public var feishuCalendarID: String
    public var isEnabled: Bool
}
```

Password is stored in the Keychain, keyed by `account = "\(kind.rawValue):\(username)"`.

`CalendarSyncSettings` is generalized: it keeps the global `syncIntervalSeconds`
and `syncWindowDays`, and gains `sources: [CalendarSource]`. The legacy
single-source fields (`dingTalkUsername`, `feishuCalendarID`, `isEnabled`) are
removed from the public sync path; a migration (below) converts an existing row.

### 2. Persistence — new `calendar_sources` table

`SQLiteStateStore` gains a table:

```
CREATE TABLE calendar_sources (
    source_id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    username TEXT NOT NULL,
    feishu_calendar_id TEXT NOT NULL,
    is_enabled INTEGER NOT NULL,
    resolved_collection_url TEXT     -- cached discovery result, nullable
);
```

New `StateStoring` methods: `saveCalendarSource(_:)`, `loadCalendarSources()`,
`deleteCalendarSource(id:)`. The existing `tool_settings` row keeps the global
interval/window (and `lastSuccessfulSyncAt`/`failureCount`).

`resolved_collection_url` caches Tencent's discovered collection so discovery
runs once, not every sync. DingTalk leaves it null (path is fixed).

**Migration:** on first load, if `calendar_sources` is empty but a legacy
`tool_settings` row has a non-empty `dingTalkUsername`, insert a `dingtalk`
source from it (username + feishuCalendarID + isEnabled). Idempotent.

### 3. CalDAV generalization — `CalDAVCalendarClient`

Rename/generalize `DingTalkCalDAVClient` into a provider-agnostic
`CalDAVCalendarClient` conforming to `DingTalkEventFetching`
(`fetchEvents(settings:password:)` becomes `fetchEvents(source:password:window:)`).

It is parameterized by a host and a **collection-resolution strategy**:

```
enum CollectionStrategy: Sendable {
    case fixedPath(String)   // template "/dav/{user}/primary/"
    case discover            // well-known → principal → home → first calendar
}
```

- DingTalk: `host = calendar.dingtalk.com`, `.fixedPath("/dav/{user}/primary/")`.
- Tencent: `host = cal.meeting.tencent.com`, `.discover`.

The discovery routine (PROPFIND chain) returns the collection URL and is cached
via `resolved_collection_url`. Both paths then issue the same calendar-query
REPORT with a `time-range` derived from the global window, and reuse the
existing `ICalendarParser` + entity decoding.

A small factory builds the right client per `CalendarSourceKind`.

### 4. Sync engine — run per source, isolate by source

`SyncEngine` already carries an `EventMapping.source` field. Changes:

- `StateStoring.loadActiveMappings(calendarID:)` gains a `source:` parameter and
  filters `WHERE feishu_calendar_id = ? AND source = ? AND archived = 0`. This is
  the isolation fix: a source only reconciles its own mappings, so two sources
  sharing a calendar never delete each other's events.
- Each run is scoped to one source: `mapping.source = "neo-toolbox.\(kind)"`.
- `CalendarSyncService` iterates enabled sources, runs a per-source sync, and
  aggregates the reports. The runner factory builds one engine per source with
  that source's CalDAV client, target calendar, and Feishu writer.

### 5. UI — per-source sections in `SettingsView`

`SettingsView` is reorganized:

- A **DingTalk** section and a **Tencent Meeting** section, each with: username
  `TextField`, password `SecureField` (Keychain-backed, "saved" hint), a
  target-calendar `Picker` (shared "Load calendars" populates the Feishu list),
  enable `Toggle`, and a per-source **Test connection** result.
- A global **Sync rules** section: interval + window presets.
- One global **Save**.

`testConnection` runs per source against that source's CalDAV endpoint and the
shared Feishu side. `ConnectionTestResult` generalizes to report Feishu plus a
per-source CalDAV result.

### 6. Setup steps

`setupSteps` derivation generalizes: a source is "ready" when it has username +
stored password + target calendar; the tool is configured when at least one
enabled source is ready and `feishu-cli` is available.

## Data flow

```
Launch → load global settings + calendar_sources (+ legacy migration)
       → for each enabled, configured source: build engine, schedule

Configure (per source) → Test → Save
       → persist source row + Keychain password
       → rebuild that source's runner

Sync (manual or timer) → for each enabled source:
       resolve collection (cached or discover)
       → fetch events (time-range = global window)
       → loadActiveMappings(calendarID: source.feishuCalendarID, source: "neo-toolbox.<kind>")
       → SyncPlanBuilder → create/update/delete on the source's Feishu calendar
       → persist mappings tagged with the source
       aggregate reports
```

## Error handling

- Discovery failure (Tencent) → that source's CalDAV test/sync fails with a
  clear message; other source unaffected.
- A failing source does not abort the other; each source's result is reported
  independently and surfaced in the runtime log.
- Save persistence / Keychain errors surface as before (alert + not-saved).

## Testing

Unit tests (Memory stores + fakes), following the existing pattern:

- `CalendarSource` ↔ persisted row round-trip; legacy migration inserts a
  dingtalk source from a legacy `tool_settings` row exactly once.
- `loadActiveMappings(calendarID:source:)` isolates by source: two sources in
  the same calendar each see only their own mappings.
- CalDAV `.fixedPath` builds the DingTalk URL (unchanged); `.discover` walks a
  faked PROPFIND chain to the collection URL and caches it.
- Per-source sync: enabling both sources produces two reconciliations; disabling
  one skips it; a delete in source A leaves source B's events intact.
- `SettingsView` stays thin; logic lives in the service.

Live verification (manual, like DingTalk): enter Tencent credentials, Test →
green, Load calendars, pick a target, Save, Sync, confirm events appear in the
chosen Feishu calendar.

## Files

New:
- `Sources/NeoToolboxCore/CalendarSync/CalendarSource.swift`
- `Sources/NeoToolboxCore/DingTalk/CalDAVCalendarClient.swift` (generalized; replaces `DingTalkCalDAVClient`)
- `Sources/NeoToolboxCore/DingTalk/CalDAVDiscovery.swift`
- Test additions in `Tests/NeoToolboxCoreTests/`

Modified:
- `Sources/NeoToolboxCore/CalendarSync/CalendarSyncSettings.swift` (+ `sources`)
- `Sources/NeoToolboxCore/Storage/StateStore.swift` / `SQLiteStateStore.swift` (table + source-scoped mappings)
- `Sources/NeoToolboxCore/Sync/SyncEngine.swift` (source-scoped mapping load)
- `Sources/NeoToolboxCore/CalendarSync/CalendarSyncService.swift` (multi-source orchestration)
- `Sources/NeoToolboxApp/Dashboard/Settings/SettingsView.swift` (per-source sections)
