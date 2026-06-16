# Neo Toolbox — Calendar Sync Configuration UI Design

Date: 2026-06-16
Status: Approved design, pending implementation plan

## Problem

The Calendar Sync tool ships with a working backend (`SQLiteStateStore`,
`KeychainCredentialStore`, `DingTalkCalDAVClient`, `FeishuCLIClient`,
`SyncEngine`) and a status-only UI. There is **no way to enter configuration**:

- `SetupWizardView` is read-only — it renders a static `setupSteps` checklist
  with no input fields.
- `CalendarSyncService` holds no configuration and exposes no save methods. Its
  `syncRunner` is `nil` by default, so "Sync Now" does nothing.
- The persistence layer already models every config field
  (`StoredToolSettings` in the `tool_settings` table, `CalendarSyncSettings`,
  Keychain credential storage), but nothing in the app writes to it.

This design adds the missing middle layer: a single-page settings form plus the
service methods that load, validate, persist, and apply configuration.

## Goals

- Let the user enter and save: DingTalk CalDAV username/password, Feishu target
  calendar, sync interval, sync window, delete-sync toggle, enable toggle.
- Persist non-secret fields to SQLite (`tool_settings`) and the CalDAV password
  to the Keychain.
- Validate credentials on demand via a Test Connection action.
- Apply saved settings: build a real sync runner and (re)start the timer.
- Derive the setup checklist completeness from actual configuration.

## Non-Goals

- LaunchAgent / login-item autostart (deferred, per product direction).
- Multi-account or multi-calendar sync.
- Editing the `feishu-cli` install itself (the app only detects and drives it).
- Free-text Feishu calendar entry (dropdown only; see Decisions).

## Decisions (from brainstorming)

| Topic | Decision |
|---|---|
| Form shape | Single-page settings form, reached from a new sidebar **Settings** item |
| Credential validation | Independent **Test Connection** button; Save persists anytime |
| Feishu calendar selection | Dropdown populated by `feishu-cli listCalendars` |
| Interval / window controls | Preset dropdowns (interval 10/30/60 min; window 7/30/90 days) |
| State ownership | Approach A — `CalendarSyncService` owns the config lifecycle |

## Architecture

Three modified units, one new view, and one new protocol. The backend stays
unchanged.

### 1. `CalendarSyncService` (NeoToolboxCore) — config layer

Inject real dependencies through `init`:

- `stateStore: any StateStore`
- `credentialStore: any CredentialStoring`
- `feishuClient: any FeishuCalendarProviding`
- `caldavClient: any DingTalkEventFetching`
- a runner factory that builds a `SyncEngine` from settings + dependencies

New published state:

- `@Published settings: CalendarSyncSettings` — current persisted settings
- `@Published availableCalendars: [FeishuCalendar]` — for the dropdown
- `@Published testResult: ConnectionTestResult?` — last Test result
- `@Published hasStoredPassword: Bool` — drives the SecureField hint

New methods:

- `loadSettings()` — read `StoredToolSettings` for `toolID` on launch, map to
  `CalendarSyncSettings`, set `hasStoredPassword`, rebuild the runner, recompute
  `setupSteps`. If enabled + configured, start the timer.
- `saveSettings(_ draft: CalendarSyncSettings, password: String?)` — persist a
  `StoredToolSettings` row; if `password` is non-empty, write it to the Keychain
  under `account = draft.dingTalkUsername`; rebuild the runner; restart or stop
  the timer based on `isEnabled`; recompute `setupSteps`.
- `testConnection(_ draft:, password:)` async → `ConnectionTestResult` — check
  the `feishu-cli` dependency and `listCalendars`, and attempt a small-window
  CalDAV fetch to validate the DingTalk login. Returns per-side status.
- `loadFeishuCalendars()` async — populate `availableCalendars`.

Behavior changes:

- `setupSteps` becomes **derived** from `settings` + `dependencyCheck` (each
  step's `isComplete` computed) instead of the static `defaultSteps`.
- The runner is constructed from settings rather than injected as `nil`.

### 2. `FeishuCalendarProviding` protocol (NeoToolboxCore) — test seam

`FeishuCLIClient` is a concrete struct. Extract a protocol so the service can be
tested with a fake:

```
public protocol FeishuCalendarProviding: Sendable {
    func checkDependency() async -> DependencyCheck
    func listCalendars() async throws -> [FeishuCalendar]
}
```

`FeishuCLIClient` conforms. The sync engine continues to use the concrete client
for create/update/delete; only calendar listing + dependency check go through
the protocol for the config flow.

### 3. `SettingsView` (NeoToolboxApp) — `Dashboard/Settings/SettingsView.swift`

Single-page `Form` bound to a local `@State` draft initialized from
`service.settings`:

- **DingTalk** section: `TextField` username; `SecureField` password. When
  `service.hasStoredPassword` is true and the field is empty, show
  "Password saved in Keychain"; leaving it empty on Save keeps the stored
  password. Typing a new value overwrites it.
- **Feishu** section: a "Load Calendars" button calling
  `service.loadFeishuCalendars()`, then a `Picker` over
  `service.availableCalendars` bound to `feishuCalendarID`.
- **Rules** section: interval `Picker` (10/30/60 min), window `Picker`
  (7/30/90 days), delete-sync `Toggle`, enable `Toggle`.
- **Actions**: a Test Connection button (shows the DingTalk and Feishu results
  inline, red/green) and a Save button calling
  `service.saveSettings(draft, password:)`.

### 4. Navigation

Add a **Settings** destination to `SidebarView` and route it in
`DashboardView` to `SettingsView`.

### 5. `AppDelegate` wiring

Instantiate the real stack at launch:

- `SQLiteStateStore` at an Application Support database path
  (e.g. `~/Library/Application Support/NeoToolbox/state.sqlite3`)
- `KeychainCredentialStore`
- `FeishuCLIClient`
- `DingTalkCalDAVClient`

Build `CalendarSyncService` with these and call `loadSettings()` on launch.

## Data Flow

```
Launch
  AppDelegate builds stores + clients
    → CalendarSyncService(init with deps)
    → loadSettings()
        → if configured && enabled: build runner + startTimer

Configure
  User edits SettingsView draft
    → Test Connection → service.testConnection() → inline status
    → Save → service.saveSettings(draft, password)
        → StateStore.saveToolSettings(...)
        → CredentialStore.savePassword(...) (only if password entered)
        → rebuild runner
        → start/stop timer by isEnabled
        → recompute setupSteps
  CalendarSyncView "Sync Now" now drives the real runner
```

## Persistence

- `toolID` constant: `"calendar-sync"`.
- Map `CalendarSyncSettings` ↔ `StoredToolSettings` (the stored type also carries
  `lastSuccessfulSyncAt` and `consecutiveFailureCount`, preserved across saves).
- Password stored in the Keychain via `KeychainCredentialStore`, keyed by
  `account = dingTalkUsername`. Changing the username writes the password under
  the new account on the next Save.

## Error Handling

- `testConnection` returns a structured `ConnectionTestResult`:
  `{ dingTalk: .ok | .failed(String), feishu: .ok | .failed(String) }`,
  rendered inline with red/green indicators.
- `saveSettings` surfaces persistence or Keychain failures as an alert; settings
  are not considered saved if the write throws.
- `loadFeishuCalendars` failure (e.g. `feishu-cli` missing or unconfigured)
  shows an inline message prompting the user to install/configure the CLI; the
  dropdown stays empty.
- A failed sync continues to flow through the existing
  `status = .failed(message)` + `recentLogs` path.

## Testing

Unit tests on `CalendarSyncService` using the existing `MemoryCredentialStore`,
an in-memory/`StateStore` fake, and fakes for the CalDAV and Feishu protocols:

- `saveSettings` persists to the state store and writes the password to the
  credential store; empty password leaves the stored password untouched.
- `loadSettings` round-trips persisted settings and sets `hasStoredPassword`.
- `setupSteps` completeness derivation for representative configured/unconfigured
  states.
- `testConnection` maps client success/failure to per-side `ConnectionTestResult`.
- After `saveSettings`, `syncNow` drives a runner built from the new settings.

`SettingsView` stays thin; logic lives in the service, so view-level tests are
not required.

## Files

New:
- `Sources/NeoToolboxApp/Dashboard/Settings/SettingsView.swift`
- `Sources/NeoToolboxCore/Feishu/FeishuCalendarProviding.swift` (protocol)
- Test additions in `Tests/NeoToolboxCoreTests/`

Modified:
- `Sources/NeoToolboxCore/CalendarSync/CalendarSyncService.swift`
- `Sources/NeoToolboxApp/Dashboard/SidebarView.swift`
- `Sources/NeoToolboxApp/Dashboard/DashboardView.swift`
- `Sources/NeoToolboxApp/AppDelegate.swift`
