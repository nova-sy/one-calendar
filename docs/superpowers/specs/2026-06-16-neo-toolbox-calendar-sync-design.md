# Neo Toolbox macOS App Design

Date: 2026-06-16

## Summary

Neo Toolbox is a distributable native macOS toolbox app. The first tool is "DingTalk Calendar Sync to Feishu", but the product should be structured as a general toolbox from the start.

The app is a SwiftUI menu bar resident app with a dashboard window. The Dock icon should not remain visible during normal background operation. Users open the dashboard from the macOS menu bar item. Closing the dashboard window keeps the app process alive and background sync continues. Explicitly quitting Neo Toolbox from the menu bar stops all background sync.

The first version does not install a LaunchAgent. It also does not embed or automatically install `feishu-cli`. Users install and configure `feishu-cli` themselves; Neo Toolbox detects, validates, and diagnoses it.

## Goals

- Provide a native macOS app that can be distributed to other users.
- Use a toolbox architecture, where calendar sync is only the first tool.
- Keep Neo Toolbox resident in the macOS menu bar, not as a permanent Dock app.
- Sync DingTalk calendar events to a selected Feishu calendar.
- Support create, update, and delete sync semantics.
- Protect users from deleting Feishu events that were not created and tracked by this tool.
- Make setup and troubleshooting explicit enough for non-developer users who can follow instructions.

## Non-Goals

- No two-way sync.
- No team-wide DingTalk calendar sync.
- No Feishu OAuth productization in the first version.
- No embedded or automatic `feishu-cli` installer.
- No LaunchAgent background daemon in the first version.
- No App Store release workflow in the first version.
- No sync after the user explicitly quits Neo Toolbox.

## Product Shape

Neo Toolbox uses a split dashboard layout:

- Tools
  - Calendar Sync
  - Future tools
- Runtime
  - All tool status
  - Runtime logs
- Management
  - Dependency checks
  - Settings

The Calendar Sync tool detail page shows:

- Current sync status.
- Last sync time.
- Sync window.
- Last change summary.
- Manual "Sync Now" action.
- Tool configuration status.
- Recent logs and latest sync report.

The menu bar item shows compact status:

- Overall toolbox health.
- Calendar Sync last run status.
- "Open Dashboard".
- "Sync Now".
- "Quit Neo Toolbox".

## Runtime Model

Neo Toolbox is a menu bar resident SwiftUI macOS app.

Window and process behavior:

- Opening the app shows the dashboard window.
- Closing the dashboard window does not quit the app.
- The menu bar icon remains available after the window closes.
- Background timers continue while the app process is alive.
- Selecting "Quit Neo Toolbox" from the menu bar exits the process and stops sync.
- Optional "Launch at Login" starts the menu bar app at login, but does not install a separate sync daemon.

This model avoids a permanent Dock icon while still giving users a visible resident control point in the macOS status bar.

Implementation note:

- Use a menu bar app model such as `MenuBarExtra`.
- Configure the app so it behaves as an accessory/status-bar app rather than a normal Dock-resident app during background operation.
- Opening the dashboard should activate the app and show the window, but closing the window should return to menu-bar-only operation.

## Architecture

### Modules

`NeoToolboxApp`

- SwiftUI app entry.
- Menu bar item.
- Dashboard window management.
- Tool registration.
- Global settings.
- Launch-at-login setting.

`ToolRegistry`

- Defines available tools.
- Provides common tool metadata, status, and navigation.
- Keeps the app extensible beyond the first calendar sync tool.

`CalendarSyncTool`

- Owns Calendar Sync UI, setup flow, tool settings, status, and reports.
- Coordinates sync runs through `SyncEngine`.

`SyncEngine`

- Fetches DingTalk CalDAV events.
- Normalizes event data.
- Computes fingerprints.
- Builds sync plans.
- Executes create, update, and delete actions.
- Updates local state only after successful external operations.

`DingTalkCalDAVClient`

- Connects to `https://calendar.dingtalk.com`.
- Authenticates with user-provided CalDAV username and password.
- Reads future events within the configured sync window.
- Handles date, datetime, timezone, and all-day event normalization.

`FeishuCLIClient`

- Detects `feishu-cli` on common shell paths.
- Does not rely only on the GUI app's inherited `PATH`, because macOS GUI apps launched from Finder often do not inherit the user's shell path.
- Checks common Homebrew and user paths such as `/opt/homebrew/bin/feishu-cli`, `/usr/local/bin/feishu-cli`, and user-configured custom paths.
- Validates `~/.feishu-cli/config.yaml`.
- Runs `feishu-cli calendar list`.
- Creates, updates, and deletes Feishu calendar events.
- Captures stdout, stderr, exit code, and parsed JSON.
- Classifies errors for UI diagnostics.

`StateStore`

- Uses SQLite for durable local state.
- Stores tool configuration, selected calendar id, event mappings, sync reports, and action logs.
- Does not store sensitive CalDAV passwords.

`CredentialStore`

- Uses macOS Keychain.
- Stores DingTalk CalDAV password.
- References credentials by account identifier from SQLite settings.

## Data Model

### Tool Settings

- Tool enabled flag.
- Sync interval, default 15 minutes.
- Sync window, default 30 future days.
- DingTalk CalDAV username.
- Feishu calendar id.
- Delete sync enabled flag.
- Last successful sync timestamp.
- Consecutive failure count.

### Event Mapping

Each DingTalk event tracked by Neo Toolbox has a mapping record:

- DingTalk event uid.
- Recurrence instance id when present.
- Feishu event id.
- Feishu calendar id.
- Source marker: `neo-toolbox.calendar-sync`.
- Last fingerprint.
- Last normalized start timestamp.
- Last normalized end timestamp.
- Last seen timestamp.
- Created timestamp.
- Updated timestamp.

### Sync Report

Each sync run stores:

- Started and finished timestamps.
- Trigger source: timer, manual, setup dry run.
- Overall result.
- Counts for created, updated, deleted, skipped, and failed actions.
- Error summary.
- Path to detailed command output or persisted text payload.

### Action Log

Each sync action stores:

- Action type: create, update, delete.
- DingTalk uid.
- Feishu event id if known.
- Summary.
- Result.
- Error category.
- Captured command output.

## Sync Flow

1. Load tool settings and credentials.
2. Check that `feishu-cli` is available and configured.
3. Fetch DingTalk CalDAV events for the configured future window.
4. Normalize events into an internal event model.
5. Compute fingerprints for each normalized event.
6. Load current event mappings from SQLite.
7. Build a `SyncPlan`.
8. Execute Feishu operations through `FeishuCLIClient`.
9. Update SQLite only for actions that succeeded.
10. Save a sync report and publish status to the UI.

## Sync Plan Rules

Create:

- DingTalk event exists.
- No mapping exists for its uid.

Update:

- DingTalk event exists.
- Mapping exists.
- Fingerprint changed.

Delete:

- Mapping exists.
- DingTalk event is no longer present in the active sync window.
- Mapping's last known event time still belongs to the active tracked window.
- Mapping source marker is `neo-toolbox.calendar-sync`.
- Mapping belongs to the currently selected Feishu calendar.

Skip:

- DingTalk event exists and fingerprint is unchanged.
- Event is outside the configured sync window.
- Event cannot be normalized safely.

## Delete Protection

Delete sync is enabled in the first version, but it must be bounded.

Neo Toolbox may delete a Feishu event only when all conditions are true:

- The event id is present in Neo Toolbox's local mapping table.
- The mapping source marker identifies Calendar Sync.
- The mapping belongs to the selected Feishu calendar id.
- The DingTalk uid is absent from the current fetched DingTalk result set.
- The mapping's last known start/end time is still within the active tracked window.

If a mapped event naturally ages out of the sync window, Neo Toolbox must not delete it from Feishu. It should mark the mapping as archived or out-of-window so the local table does not grow without bound.

Neo Toolbox must never scan a Feishu calendar and delete unmatched events. User-created Feishu events and events outside the mapping table are out of scope.

## Setup Flow

The first-run setup wizard has five steps.

1. Check `feishu-cli`
   - Detect executable path.
   - Detect config file.
   - Run a basic calendar command.
   - Show install and configuration instructions when missing.

2. Connect DingTalk CalDAV
   - User manually enters CalDAV username and password.
   - App tests connection and calendar listing.
   - Password is stored in Keychain after a successful test.

3. Select Feishu calendar
   - App calls `feishu-cli calendar list`.
   - User chooses the target calendar for synced DingTalk events.

4. Configure sync rules
   - Sync interval.
   - Sync window.
   - Delete sync confirmation.

5. Trial run
   - Build a sync plan.
   - Show expected create, update, and delete counts.
   - Execute only after user confirmation.

## Error Handling

Error categories:

- Missing `feishu-cli`.
- `feishu-cli` config missing.
- Feishu calendar permission missing.
- Feishu command failed.
- DingTalk CalDAV authentication failed.
- DingTalk CalDAV connection failed.
- DingTalk calendar returned unsupported event data.
- SQLite persistence failed.
- Keychain read/write failed.

Behavior:

- Single action failures do not corrupt the whole sync run.
- State updates happen only after the corresponding Feishu operation succeeds.
- Failed actions are logged individually.
- Consecutive full-run failures pause the tool and surface a fix-required status.
- Logs expose enough stdout/stderr detail for troubleshooting without exposing stored credentials.

## UI Requirements

Dashboard:

- Split navigation with Tools, Runtime, and Management groups.
- Tool detail page for Calendar Sync.
- Dependency check view.
- Runtime log view.
- Settings view.

Menu bar:

- Overall status indicator.
- Last Calendar Sync status.
- Open Dashboard.
- Sync Now.
- Quit.

Setup wizard:

- Clear completion status per step.
- Copyable commands for installing and configuring `feishu-cli`.
- Inline validation results.
- Trial sync plan before the first write.

## Testing Strategy

Unit tests:

- Event fingerprinting.
- DingTalk date/datetime/all-day normalization.
- Sync plan generation.
- Delete protection rules.
- Feishu CLI output parsing.
- Error classification.

Integration tests:

- `FeishuCLIClient` with fake command runner.
- `DingTalkCalDAVClient` with fixture ICS data.
- SQLite migration and persistence.
- Keychain adapter behind a protocol with test implementation.

Manual verification:

- Fresh setup with missing `feishu-cli`.
- Existing `feishu-cli` but missing Feishu calendar scope.
- Valid CalDAV credentials.
- Invalid CalDAV credentials.
- First sync creates events.
- Changed DingTalk event updates Feishu event.
- Removed DingTalk event deletes only the mapped Feishu event.
- Closing the dashboard keeps menu bar app alive.
- Quitting from the menu bar stops background sync.

## Open Questions

- Exact Swift package choices for CalDAV and ICS parsing.
- Whether SQLite should use GRDB, SQLite.swift, or a small direct wrapper.
- Exact `feishu-cli` JSON output paths for create, update, delete, and calendar list.
- Whether the first release should include a signed DMG or only a developer build.

## First Implementation Slice

The first build should prove the app shell and one full sync path:

1. SwiftUI menu bar app with dashboard window and split navigation.
2. Calendar Sync setup screens with mocked validation.
3. SQLite state store and Keychain credential store interfaces.
4. `feishu-cli` detection and command runner.
5. DingTalk event normalization from fixtures.
6. Sync plan generation with create/update/delete.
7. Manual sync button using fixture input and fake Feishu runner.
8. Replace fake DingTalk and Feishu adapters with real implementations.
9. Add background timer and status publishing.
