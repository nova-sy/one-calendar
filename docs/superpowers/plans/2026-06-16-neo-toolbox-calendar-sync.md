# Neo Toolbox Calendar Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first working Neo Toolbox macOS app slice: a menu-bar-resident SwiftUI toolbox with a Calendar Sync tool that can plan DingTalk-to-Feishu create/update/delete operations safely.

**Architecture:** Start with a Swift Package that contains testable core modules, then add a SwiftUI executable target for the menu bar app and dashboard. Keep external systems behind protocols so sync planning, Feishu CLI calls, CalDAV parsing, SQLite state, and Keychain credentials can be tested independently.

**Tech Stack:** Swift 6.2.3, Swift Package Manager, SwiftUI, AppKit activation policy, Foundation URLSession, CryptoKit, SQLite3 C API, Security.framework Keychain APIs, XCTest.

---

## Source Spec

Read this first:

- `docs/superpowers/specs/2026-06-16-neo-toolbox-calendar-sync-design.md`

Current environment checked during planning:

- `xcodebuild -version`: Xcode 26.2, Build version 17C52
- `swift --version`: Apple Swift 6.2.3

Repository note:

- `钉钉日程同步飞书方案.md` is an existing untracked handoff document. Do not stage it unless the user explicitly asks.

## File Structure

Create this structure:

```text
Package.swift
Sources/
  NeoToolboxApp/
    NeoToolboxApp.swift
    AppDelegate.swift
    DashboardWindowController.swift
    MenuBar/
      MenuBarView.swift
    Dashboard/
      DashboardView.swift
      SidebarView.swift
      CalendarSync/
        CalendarSyncView.swift
        SetupWizardView.swift
        RuntimeLogView.swift
  NeoToolboxCore/
    Tools/
      ToolStatus.swift
      ToolRegistry.swift
    CalendarSync/
      CalendarSyncSettings.swift
      CalendarSyncStatus.swift
      CalendarSyncService.swift
    Sync/
      NormalizedEvent.swift
      EventFingerprint.swift
      EventMapping.swift
      SyncPlan.swift
      SyncPlanBuilder.swift
      SyncEngine.swift
      SyncReport.swift
    DingTalk/
      DingTalkCalDAVClient.swift
      ICalendarParser.swift
    Feishu/
      CommandRunner.swift
      FeishuCLIClient.swift
      FeishuCalendar.swift
    Storage/
      StateStore.swift
      SQLiteStateStore.swift
    Security/
      CredentialStore.swift
      KeychainCredentialStore.swift
    Diagnostics/
      DependencyCheck.swift
      ErrorCategory.swift
      RuntimeLog.swift
Tests/
  NeoToolboxCoreTests/
    Fixtures/
      dingtalk-events.ics
    EventFingerprintTests.swift
    SyncPlanBuilderTests.swift
    FeishuCLIClientTests.swift
    ICalendarParserTests.swift
    SQLiteStateStoreTests.swift
    CredentialStoreTests.swift
    SyncEngineTests.swift
```

Responsibility boundaries:

- `NeoToolboxApp`: UI shell only. It should not contain sync logic.
- `NeoToolboxCore/Sync`: pure planning and orchestration logic.
- `NeoToolboxCore/Feishu`: all `feishu-cli` path detection and command execution.
- `NeoToolboxCore/DingTalk`: CalDAV fetch and iCalendar parsing.
- `NeoToolboxCore/Storage`: durable SQLite state.
- `NeoToolboxCore/Security`: Keychain adapter behind a protocol.

## Task 1: Bootstrap Swift Package

**Files:**
- Create: `Package.swift`
- Create: `Sources/NeoToolboxCore/Tools/ToolStatus.swift`
- Create: `Tests/NeoToolboxCoreTests/SmokeTests.swift`

- [ ] **Step 1: Create package manifest**

Create `Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NeoToolbox",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NeoToolboxCore", targets: ["NeoToolboxCore"]),
        .executable(name: "NeoToolboxApp", targets: ["NeoToolboxApp"])
    ],
    targets: [
        .target(
            name: "NeoToolboxCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "NeoToolboxApp",
            dependencies: ["NeoToolboxCore"]
        ),
        .testTarget(
            name: "NeoToolboxCoreTests",
            dependencies: ["NeoToolboxCore"],
            resources: [.process("Fixtures")]
        )
    ]
)
```

- [ ] **Step 2: Add a tiny core type**

Create `Sources/NeoToolboxCore/Tools/ToolStatus.swift`:

```swift
public enum ToolHealth: Equatable, Sendable {
    case notConfigured
    case healthy
    case warning(String)
    case failed(String)
}

public struct ToolStatus: Equatable, Sendable {
    public var id: String
    public var title: String
    public var health: ToolHealth

    public init(id: String, title: String, health: ToolHealth) {
        self.id = id
        self.title = title
        self.health = health
    }
}
```

- [ ] **Step 3: Add smoke test**

Create `Tests/NeoToolboxCoreTests/SmokeTests.swift`:

```swift
import XCTest
@testable import NeoToolboxCore

final class SmokeTests: XCTestCase {
    func testToolStatusCanBeConstructed() {
        let status = ToolStatus(id: "calendar-sync", title: "Calendar Sync", health: .notConfigured)
        XCTAssertEqual(status.id, "calendar-sync")
        XCTAssertEqual(status.health, .notConfigured)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/NeoToolboxCore/Tools/ToolStatus.swift Tests/NeoToolboxCoreTests/SmokeTests.swift
git commit -m "chore: bootstrap Swift package"
```

## Task 2: Event Model And Fingerprinting

**Files:**
- Create: `Sources/NeoToolboxCore/Sync/NormalizedEvent.swift`
- Create: `Sources/NeoToolboxCore/Sync/EventFingerprint.swift`
- Test: `Tests/NeoToolboxCoreTests/EventFingerprintTests.swift`

- [ ] **Step 1: Write failing fingerprint tests**

Create `Tests/NeoToolboxCoreTests/EventFingerprintTests.swift`:

```swift
import XCTest
@testable import NeoToolboxCore

final class EventFingerprintTests: XCTestCase {
    func testFingerprintChangesWhenTitleChanges() {
        let base = NormalizedEvent(
            uid: "ding-1",
            recurrenceID: nil,
            title: "Weekly Meeting",
            start: Date(timeIntervalSince1970: 1_800_000_000),
            end: Date(timeIntervalSince1970: 1_800_003_600),
            isAllDay: false,
            location: "Room A",
            notes: "Discuss roadmap"
        )
        var changed = base
        changed.title = "Weekly Meeting Updated"

        XCTAssertNotEqual(EventFingerprint.make(for: base), EventFingerprint.make(for: changed))
    }

    func testFingerprintIsStableForSameEvent() {
        let event = NormalizedEvent(
            uid: "ding-1",
            recurrenceID: "20260616T100000",
            title: "All Hands",
            start: Date(timeIntervalSince1970: 1_800_000_000),
            end: Date(timeIntervalSince1970: 1_800_003_600),
            isAllDay: false,
            location: nil,
            notes: nil
        )

        XCTAssertEqual(EventFingerprint.make(for: event), EventFingerprint.make(for: event))
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter EventFingerprintTests`

Expected: FAIL because `NormalizedEvent` and `EventFingerprint` do not exist.

- [ ] **Step 3: Implement model and fingerprint**

Create `Sources/NeoToolboxCore/Sync/NormalizedEvent.swift`:

```swift
import Foundation

public struct NormalizedEvent: Equatable, Sendable {
    public var uid: String
    public var recurrenceID: String?
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?

    public init(
        uid: String,
        recurrenceID: String?,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool,
        location: String?,
        notes: String?
    ) {
        self.uid = uid
        self.recurrenceID = recurrenceID
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
    }

    public var mappingKey: String {
        if let recurrenceID {
            return "\(uid)#\(recurrenceID)"
        }
        return uid
    }
}
```

Create `Sources/NeoToolboxCore/Sync/EventFingerprint.swift`:

```swift
import Foundation
import CryptoKit

public enum EventFingerprint {
    public static func make(for event: NormalizedEvent) -> String {
        let payload = [
            event.uid,
            event.recurrenceID ?? "",
            event.title,
            String(Int(event.start.timeIntervalSince1970)),
            String(Int(event.end.timeIntervalSince1970)),
            String(event.isAllDay),
            event.location ?? "",
            event.notes ?? ""
        ].joined(separator: "\u{1F}")

        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter EventFingerprintTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/NeoToolboxCore/Sync Tests/NeoToolboxCoreTests/EventFingerprintTests.swift
git commit -m "feat: add normalized calendar event fingerprinting"
```

## Task 3: Sync Plan Builder With Delete Protection

**Files:**
- Create: `Sources/NeoToolboxCore/Sync/EventMapping.swift`
- Create: `Sources/NeoToolboxCore/Sync/SyncPlan.swift`
- Create: `Sources/NeoToolboxCore/Sync/SyncPlanBuilder.swift`
- Test: `Tests/NeoToolboxCoreTests/SyncPlanBuilderTests.swift`

- [ ] **Step 1: Write failing sync plan tests**

Create `Tests/NeoToolboxCoreTests/SyncPlanBuilderTests.swift` with tests for create, update, delete, unchanged skip, wrong source skip, wrong calendar skip, and out-of-window archive:

```swift
import XCTest
@testable import NeoToolboxCore

final class SyncPlanBuilderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCreateWhenNoMappingExists() {
        let event = sampleEvent(uid: "ding-1")
        let plan = SyncPlanBuilder.build(
            events: [event],
            mappings: [],
            selectedFeishuCalendarID: "cal-1",
            windowStart: now,
            windowEnd: now.addingTimeInterval(30 * 24 * 3600)
        )

        XCTAssertEqual(plan.creates.map(\.event.uid), ["ding-1"])
        XCTAssertTrue(plan.updates.isEmpty)
        XCTAssertTrue(plan.deletes.isEmpty)
    }

    func testUpdateWhenFingerprintChanges() {
        let event = sampleEvent(uid: "ding-1", title: "New")
        let mapping = sampleMapping(uid: "ding-1", fingerprint: "old")

        let plan = SyncPlanBuilder.build(
            events: [event],
            mappings: [mapping],
            selectedFeishuCalendarID: "cal-1",
            windowStart: now,
            windowEnd: now.addingTimeInterval(30 * 24 * 3600)
        )

        XCTAssertEqual(plan.updates.map(\.mapping.feishuEventID), ["fei-1"])
    }

    func testDeleteOnlyMappedEventStillInsideTrackedWindow() {
        let mapping = sampleMapping(uid: "ding-1", lastStart: now.addingTimeInterval(3600))

        let plan = SyncPlanBuilder.build(
            events: [],
            mappings: [mapping],
            selectedFeishuCalendarID: "cal-1",
            windowStart: now,
            windowEnd: now.addingTimeInterval(30 * 24 * 3600)
        )

        XCTAssertEqual(plan.deletes.map(\.mapping.feishuEventID), ["fei-1"])
    }

    func testDoesNotDeleteEventThatAgedOutOfWindow() {
        let mapping = sampleMapping(uid: "ding-1", lastStart: now.addingTimeInterval(-3600))

        let plan = SyncPlanBuilder.build(
            events: [],
            mappings: [mapping],
            selectedFeishuCalendarID: "cal-1",
            windowStart: now,
            windowEnd: now.addingTimeInterval(30 * 24 * 3600)
        )

        XCTAssertTrue(plan.deletes.isEmpty)
        XCTAssertEqual(plan.archives.map(\.mapping.dingTalkUID), ["ding-1"])
    }

    func testDoesNotDeleteDifferentSourceOrDifferentCalendar() {
        let otherSource = sampleMapping(uid: "ding-1", source: "other")
        let otherCalendar = sampleMapping(uid: "ding-2", feishuCalendarID: "cal-2")

        let plan = SyncPlanBuilder.build(
            events: [],
            mappings: [otherSource, otherCalendar],
            selectedFeishuCalendarID: "cal-1",
            windowStart: now,
            windowEnd: now.addingTimeInterval(30 * 24 * 3600)
        )

        XCTAssertTrue(plan.deletes.isEmpty)
    }

    private func sampleEvent(uid: String, title: String = "Meeting") -> NormalizedEvent {
        NormalizedEvent(
            uid: uid,
            recurrenceID: nil,
            title: title,
            start: now.addingTimeInterval(3600),
            end: now.addingTimeInterval(7200),
            isAllDay: false,
            location: nil,
            notes: nil
        )
    }

    private func sampleMapping(
        uid: String,
        fingerprint: String = "old",
        source: String = EventMapping.calendarSyncSource,
        feishuCalendarID: String = "cal-1",
        lastStart: Date? = nil
    ) -> EventMapping {
        EventMapping(
            dingTalkUID: uid,
            recurrenceID: nil,
            feishuEventID: "fei-1",
            feishuCalendarID: feishuCalendarID,
            source: source,
            fingerprint: fingerprint,
            lastStart: lastStart ?? now.addingTimeInterval(3600),
            lastEnd: now.addingTimeInterval(7200),
            lastSeenAt: now
        )
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter SyncPlanBuilderTests`

Expected: FAIL because plan types do not exist.

- [ ] **Step 3: Implement plan types and builder**

Create `EventMapping`, `SyncPlan`, and `SyncPlanBuilder`. The builder must:

- Index mappings by `mappingKey`.
- Generate creates for events without mappings.
- Generate updates when fingerprint differs.
- Generate deletes only for mappings with correct source, selected calendar, missing current event, and last event time inside the active window.
- Generate archives for mappings that aged out of the active window.

- [ ] **Step 4: Run tests**

Run: `swift test --filter SyncPlanBuilderTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/NeoToolboxCore/Sync Tests/NeoToolboxCoreTests/SyncPlanBuilderTests.swift
git commit -m "feat: build safe calendar sync plans"
```

## Task 4: Feishu CLI Detection And Command Runner

**Files:**
- Create: `Sources/NeoToolboxCore/Feishu/CommandRunner.swift`
- Create: `Sources/NeoToolboxCore/Feishu/FeishuCLIClient.swift`
- Create: `Sources/NeoToolboxCore/Feishu/FeishuCalendar.swift`
- Create: `Sources/NeoToolboxCore/Diagnostics/DependencyCheck.swift`
- Create: `Sources/NeoToolboxCore/Diagnostics/ErrorCategory.swift`
- Test: `Tests/NeoToolboxCoreTests/FeishuCLIClientTests.swift`

- [ ] **Step 1: Write failing tests**

Tests must cover:

- Finds executable from explicit user path.
- Checks `/opt/homebrew/bin/feishu-cli` and `/usr/local/bin/feishu-cli` before relying on inherited `PATH`.
- Parses `calendar list -o json`.
- Captures non-zero exit status as a typed error.

Use a fake `CommandRunner` and fake file existence closure.

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter FeishuCLIClientTests`

Expected: FAIL because client types do not exist.

- [ ] **Step 3: Implement command abstractions**

`CommandRunner` should return:

```swift
public struct CommandResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
}

public protocol CommandRunning: Sendable {
    func run(executable: String, arguments: [String]) async throws -> CommandResult
}
```

`FeishuCLIClient` should expose:

```swift
public struct FeishuCLIClient: Sendable {
    public func checkDependency() async -> DependencyCheck
    public func listCalendars() async throws -> [FeishuCalendar]
    public func createEvent(_ event: NormalizedEvent, calendarID: String) async throws -> String
    public func updateEvent(_ mapping: EventMapping, with event: NormalizedEvent) async throws
    public func deleteEvent(_ mapping: EventMapping) async throws
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter FeishuCLIClientTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/NeoToolboxCore/Feishu Sources/NeoToolboxCore/Diagnostics Tests/NeoToolboxCoreTests/FeishuCLIClientTests.swift
git commit -m "feat: add Feishu CLI client diagnostics"
```

## Task 5: SQLite State Store

**Files:**
- Create: `Sources/NeoToolboxCore/Storage/StateStore.swift`
- Create: `Sources/NeoToolboxCore/Storage/SQLiteStateStore.swift`
- Test: `Tests/NeoToolboxCoreTests/SQLiteStateStoreTests.swift`

- [ ] **Step 1: Write failing persistence tests**

Tests must use a temporary database path and cover:

- Migration creates tables.
- Insert and fetch tool settings.
- Upsert and fetch event mapping.
- Save sync report and action log.
- Archive mapping instead of deleting it physically.

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter SQLiteStateStoreTests`

Expected: FAIL because storage types do not exist.

- [ ] **Step 3: Implement direct SQLite3 wrapper**

Use SQLite3 C API through `import SQLite3`.

Minimum tables:

- `tool_settings`
- `event_mappings`
- `sync_reports`
- `action_logs`

Keep SQL small and explicit. Do not introduce a database dependency unless direct SQLite import fails in this environment.

- [ ] **Step 4: Run tests**

Run: `swift test --filter SQLiteStateStoreTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/NeoToolboxCore/Storage Tests/NeoToolboxCoreTests/SQLiteStateStoreTests.swift
git commit -m "feat: persist calendar sync state in SQLite"
```

## Task 6: Credential Store

**Files:**
- Create: `Sources/NeoToolboxCore/Security/CredentialStore.swift`
- Create: `Sources/NeoToolboxCore/Security/KeychainCredentialStore.swift`
- Test: `Tests/NeoToolboxCoreTests/CredentialStoreTests.swift`

- [ ] **Step 1: Write failing tests against memory implementation**

Test through the `CredentialStoring` protocol:

- Save password.
- Read password.
- Delete password.
- Missing password returns nil.

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter CredentialStoreTests`

Expected: FAIL because credential types do not exist.

- [ ] **Step 3: Implement protocol, memory store, and Keychain adapter**

Protocol:

```swift
public protocol CredentialStoring: Sendable {
    func savePassword(_ password: String, account: String) throws
    func readPassword(account: String) throws -> String?
    func deletePassword(account: String) throws
}
```

Keychain service name: `com.neo-toolbox.calendar-sync.dingtalk-caldav`.

- [ ] **Step 4: Run tests**

Run: `swift test --filter CredentialStoreTests`

Expected: PASS using memory store only.

- [ ] **Step 5: Commit**

```bash
git add Sources/NeoToolboxCore/Security Tests/NeoToolboxCoreTests/CredentialStoreTests.swift
git commit -m "feat: add credential store abstraction"
```

## Task 7: iCalendar Parsing Fixtures

**Files:**
- Create: `Sources/NeoToolboxCore/DingTalk/ICalendarParser.swift`
- Create: `Tests/NeoToolboxCoreTests/Fixtures/dingtalk-events.ics`
- Test: `Tests/NeoToolboxCoreTests/ICalendarParserTests.swift`

- [ ] **Step 1: Add fixture**

Create an ICS fixture containing:

- Timed event.
- All-day event using `VALUE=DATE`.
- Event with `LOCATION`.
- Event with `DESCRIPTION`.

- [ ] **Step 2: Write failing parser tests**

Tests must assert:

- Timed event becomes `isAllDay == false`.
- All-day event becomes `isAllDay == true`.
- UID, title, start, end, location, and notes are parsed.

- [ ] **Step 3: Run tests to verify failure**

Run: `swift test --filter ICalendarParserTests`

Expected: FAIL because parser does not exist.

- [ ] **Step 4: Implement minimal parser**

Implement enough RFC5545 parsing for current fixtures and DingTalk output:

- Unfold folded lines.
- Parse `BEGIN:VEVENT` / `END:VEVENT`.
- Parse `UID`, `SUMMARY`, `DTSTART`, `DTEND`, `RECURRENCE-ID`, `LOCATION`, `DESCRIPTION`.
- Parse UTC datetime, local datetime, and `VALUE=DATE`.

- [ ] **Step 5: Run tests**

Run: `swift test --filter ICalendarParserTests`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/NeoToolboxCore/DingTalk Tests/NeoToolboxCoreTests/Fixtures Tests/NeoToolboxCoreTests/ICalendarParserTests.swift
git commit -m "feat: parse DingTalk calendar fixtures"
```

## Task 8: Sync Engine Orchestration

**Files:**
- Create: `Sources/NeoToolboxCore/CalendarSync/CalendarSyncSettings.swift`
- Create: `Sources/NeoToolboxCore/CalendarSync/CalendarSyncStatus.swift`
- Create: `Sources/NeoToolboxCore/Sync/SyncEngine.swift`
- Create: `Sources/NeoToolboxCore/Sync/SyncReport.swift`
- Test: `Tests/NeoToolboxCoreTests/SyncEngineTests.swift`

- [ ] **Step 1: Write failing orchestration tests**

Use fake DingTalk source, fake Feishu client, memory state store, and memory credential store.

Tests must cover:

- Create action calls Feishu then writes mapping.
- Update action calls Feishu then updates fingerprint.
- Delete action calls Feishu then archives mapping.
- Failed Feishu action does not update local state.
- Report includes counts and failures.

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter SyncEngineTests`

Expected: FAIL because sync engine does not exist.

- [ ] **Step 3: Implement protocols and engine**

Introduce small protocols:

```swift
public protocol DingTalkEventFetching: Sendable {
    func fetchEvents(settings: CalendarSyncSettings, password: String) async throws -> [NormalizedEvent]
}

public protocol FeishuCalendarWriting: Sendable {
    func createEvent(_ event: NormalizedEvent, calendarID: String) async throws -> String
    func updateEvent(_ mapping: EventMapping, with event: NormalizedEvent) async throws
    func deleteEvent(_ mapping: EventMapping) async throws
}
```

`SyncEngine.run(trigger:)` should return `SyncReport`.

- [ ] **Step 4: Run tests**

Run: `swift test --filter SyncEngineTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/NeoToolboxCore/CalendarSync Sources/NeoToolboxCore/Sync Tests/NeoToolboxCoreTests/SyncEngineTests.swift
git commit -m "feat: orchestrate calendar sync runs"
```

## Task 9: SwiftUI Menu Bar App Shell

**Files:**
- Create: `Sources/NeoToolboxApp/NeoToolboxApp.swift`
- Create: `Sources/NeoToolboxApp/AppDelegate.swift`
- Create: `Sources/NeoToolboxApp/DashboardWindowController.swift`
- Create: `Sources/NeoToolboxApp/MenuBar/MenuBarView.swift`
- Create: `Sources/NeoToolboxApp/Dashboard/DashboardView.swift`
- Create: `Sources/NeoToolboxApp/Dashboard/SidebarView.swift`
- Create: `Sources/NeoToolboxCore/Tools/ToolRegistry.swift`

- [ ] **Step 1: Add app shell**

Implement:

- `MenuBarExtra("Neo Toolbox", systemImage: "wrench.and.screwdriver")`.
- Menu item showing overall status.
- `Open Dashboard`.
- `Sync Now` placeholder.
- `Quit Neo Toolbox`.
- `NSApp.setActivationPolicy(.accessory)` for no normal Dock presence.
- Dashboard window opened on demand.

- [ ] **Step 2: Add split dashboard**

Sidebar groups:

- Tools: Calendar Sync, Future tools disabled.
- Runtime: All tool status, Runtime logs.
- Management: Dependency checks, Settings.

- [ ] **Step 3: Build**

Run: `swift build`

Expected: PASS.

- [ ] **Step 4: Manual smoke run**

Run: `swift run NeoToolboxApp`

Expected:

- Menu bar item appears.
- Dashboard can be opened.
- Closing dashboard leaves menu bar item active.
- Quit exits process.

- [ ] **Step 5: Commit**

```bash
git add Sources/NeoToolboxApp Sources/NeoToolboxCore/Tools/ToolRegistry.swift
git commit -m "feat: add Neo Toolbox menu bar app shell"
```

## Task 10: Calendar Sync UI And Setup View Models

**Files:**
- Create: `Sources/NeoToolboxCore/CalendarSync/CalendarSyncService.swift`
- Create: `Sources/NeoToolboxApp/Dashboard/CalendarSync/CalendarSyncView.swift`
- Create: `Sources/NeoToolboxApp/Dashboard/CalendarSync/SetupWizardView.swift`
- Create: `Sources/NeoToolboxApp/Dashboard/CalendarSync/RuntimeLogView.swift`

- [ ] **Step 1: Add service state**

`CalendarSyncService` publishes:

- Current status.
- Last sync time.
- Last report.
- Dependency check result.
- Setup completion state.

- [ ] **Step 2: Add Calendar Sync detail page**

Show:

- Status cards.
- Last sync time.
- Sync window.
- Last create/update/delete counts.
- `Sync Now`.
- Tool configuration status.
- Recent logs.

- [ ] **Step 3: Add setup wizard UI**

Wizard steps:

1. Check `feishu-cli`.
2. Connect DingTalk CalDAV.
3. Select Feishu calendar.
4. Configure sync rules.
5. Trial run.

- [ ] **Step 4: Build**

Run: `swift build`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/NeoToolboxCore/CalendarSync/CalendarSyncService.swift Sources/NeoToolboxApp/Dashboard/CalendarSync
git commit -m "feat: add calendar sync dashboard UI"
```

## Task 11: Real DingTalk CalDAV Client

**Files:**
- Create: `Sources/NeoToolboxCore/DingTalk/DingTalkCalDAVClient.swift`
- Test: extend `Tests/NeoToolboxCoreTests/ICalendarParserTests.swift` or add `DingTalkCalDAVClientTests.swift`

- [ ] **Step 1: Write tests around request construction**

Use a fake HTTP transport protocol. Assert:

- URL is `https://calendar.dingtalk.com`.
- Basic auth header is present.
- CalDAV `REPORT` request is generated for configured window.
- Response calendar data is passed to `ICalendarParser`.

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter DingTalkCalDAVClientTests`

Expected: FAIL because client does not exist.

- [ ] **Step 3: Implement client**

Implement minimal CalDAV calendar-query:

- Discover or use configured DingTalk calendar endpoint if needed.
- Send authenticated `REPORT`.
- Extract `calendar-data` from XML response.
- Parse ICS into `[NormalizedEvent]`.

If DingTalk requires principal/calendar discovery in real testing, add a follow-up task rather than expanding this task beyond a minimal client.

- [ ] **Step 4: Run tests**

Run: `swift test --filter DingTalkCalDAVClientTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/NeoToolboxCore/DingTalk Tests/NeoToolboxCoreTests
git commit -m "feat: fetch DingTalk events over CalDAV"
```

## Task 12: Background Scheduling And Final Verification

**Files:**
- Modify: `Sources/NeoToolboxCore/CalendarSync/CalendarSyncService.swift`
- Modify: `Sources/NeoToolboxApp/MenuBar/MenuBarView.swift`
- Modify: `Sources/NeoToolboxApp/Dashboard/CalendarSync/CalendarSyncView.swift`

- [ ] **Step 1: Add scheduler tests if service is testable**

Test that:

- Manual trigger runs immediately.
- Timer trigger is ignored while a sync is already running.
- Consecutive full-run failures mark tool as failed or paused.

- [ ] **Step 2: Implement background scheduler**

`CalendarSyncService` should:

- Start timer only when tool is enabled and configured.
- Keep running while app process is alive.
- Stop when app quits.
- Publish status changes to menu bar and dashboard.

- [ ] **Step 3: Run full tests**

Run: `swift test`

Expected: PASS.

- [ ] **Step 4: Build app**

Run: `swift build`

Expected: PASS.

- [ ] **Step 5: Manual lifecycle verification**

Run: `swift run NeoToolboxApp`

Expected:

- Menu bar item appears.
- Dashboard opens from menu bar.
- Closing dashboard does not stop the app.
- Menu bar status remains visible.
- Quit exits process.

- [ ] **Step 6: Commit**

```bash
git add Sources/NeoToolboxCore/CalendarSync Sources/NeoToolboxApp
git commit -m "feat: run calendar sync in menu bar background"
```

## Final Acceptance

- [ ] `swift test` passes.
- [ ] `swift build` passes.
- [ ] Menu bar app can be launched with `swift run NeoToolboxApp`.
- [ ] Dashboard uses split navigation with Tools, Runtime, and Management groups.
- [ ] Calendar Sync can generate safe create/update/delete plans.
- [ ] Delete sync never targets mappings outside the selected calendar, source marker, or active tracked window.
- [ ] Missing `feishu-cli` is reported as a dependency issue.
- [ ] GUI app path lookup does not depend only on inherited shell `PATH`.
- [ ] Closing the dashboard keeps the app alive in the menu bar.
- [ ] Quitting from the menu bar stops the process.

## Known Follow-Ups

- Confirm DingTalk CalDAV discovery behavior against a real account.
- Confirm actual `feishu-cli` JSON output paths.
- Add signed `.app` or `.dmg` packaging after the development app works.
- Decide whether to initialize a separate app icon and bundle identifier.
