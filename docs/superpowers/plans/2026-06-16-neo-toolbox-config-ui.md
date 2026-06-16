# Calendar Sync Configuration UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a single-page Settings form and the service layer that loads, validates, persists, and applies Calendar Sync configuration, so the tool can actually be configured and run.

**Architecture:** Approach A — `CalendarSyncService` (NeoToolboxCore) owns the config lifecycle. It gains injected dependencies (state store, credential store, Feishu provider/writer, CalDAV client) and methods to load/save settings, test connections, and list calendars. A new `SettingsView` (NeoToolboxApp) binds a draft to those methods. The existing backend (`SyncEngine`, clients, `SQLiteStateStore`, Keychain) is unchanged; a small adapter bridges `StateStoring` to the engine's `CalendarSyncStateStoring`.

**Tech Stack:** Swift 6.2, SwiftPM, SwiftUI (macOS 14+), XCTest, SQLite, Security/Keychain.

---

## Background facts (verified in code)

- `CalendarSyncSettings` fields: `toolID, isEnabled, syncIntervalSeconds, syncWindowDays, dingTalkUsername, feishuCalendarID, deleteSyncEnabled`.
- `StoredToolSettings` adds `lastSuccessfulSyncAt: Date?` and `consecutiveFailureCount: Int`.
- `StateStoring` protocol: `saveToolSettings`, `loadToolSettings(toolID:)`, `upsertEventMapping`, `loadEventMappings(calendarID:)`, `archiveEventMapping(mappingKey:)`, plus reports/logs. `SQLiteStateStore(path:)` conforms.
- `SyncEngine.init(settings:eventFetcher:feishuWriter:stateStore:credentialStore:)` where `stateStore` is `any CalendarSyncStateStoring` (`loadActiveMappings(calendarID:)`, `upsertMapping`, `archiveMapping(mappingKey:)`). **No type currently bridges `StateStoring` → `CalendarSyncStateStoring`.**
- `SyncEngine` conforms to `CalendarSyncRunning` (`run(trigger:)`).
- `FeishuCLIClient`: `checkDependency() async -> DependencyCheck`, `listCalendars() async throws -> [FeishuCalendar]`, and conforms to `FeishuCalendarWriting`.
- `FeishuCalendar { id, summary }`. `DependencyCheck { status: DependencyStatus(.available/.missing), executablePath, message }`.
- `DingTalkCalDAVClient: DingTalkEventFetching` → `fetchEvents(settings:password:) async throws -> [NormalizedEvent]`.
- `CredentialStoring`: `savePassword(_:account:)`, `readPassword(account:) -> String?`, `deletePassword(account:)`. `MemoryCredentialStore` exists.
- `CalendarSyncService` is `@MainActor`, has `syncNow()`, `triggerSync(_:)`, `startTimer(intervalSeconds:)`, `stopTimer()`, and an init whose only behavioral param is `syncRunner` (everything else has display defaults). Existing tests call `CalendarSyncService(syncRunner:)` — **must stay compiling**.
- `SidebarItem` already has a `.settings` case; `DashboardView` currently routes it to a `PlaceholderDetailView` and constructs its own `CalendarSyncService()` with no dependencies. `DashboardWindowController.show()` builds `DashboardView()`. `NeoToolboxApp` owns `DashboardWindowController` and has a no-op `syncNow` in the menu bar.

## File Structure

New (NeoToolboxCore):
- `Sources/NeoToolboxCore/CalendarSync/CalendarSyncSettings+Stored.swift` — settings ↔ stored mapping + `unconfigured` default.
- `Sources/NeoToolboxCore/Storage/InMemoryStateStore.swift` — in-memory `StateStoring` (default dep + tests).
- `Sources/NeoToolboxCore/Feishu/FeishuCalendarProviding.swift` — provider protocol + `FeishuCLIClient` conformance.
- `Sources/NeoToolboxCore/CalendarSync/UnavailableClients.swift` — stub provider/writer/fetcher used as safe defaults.
- `Sources/NeoToolboxCore/Sync/CalendarSyncStateStoreAdapter.swift` — bridges `StateStoring` → `CalendarSyncStateStoring`.
- `Sources/NeoToolboxCore/CalendarSync/ConnectionTestResult.swift` — Test Connection result type.

New (NeoToolboxApp):
- `Sources/NeoToolboxApp/Dashboard/Settings/SettingsView.swift` — single-page form.

New (tests):
- `Tests/NeoToolboxCoreTests/CalendarSyncConfigTests.swift` — config-layer tests.

Modified:
- `Sources/NeoToolboxCore/CalendarSync/CalendarSyncService.swift` — config layer.
- `Sources/NeoToolboxApp/Dashboard/DashboardView.swift` — inject service, route Settings.
- `Sources/NeoToolboxApp/DashboardWindowController.swift` — build live service, pass down.
- `Sources/NeoToolboxApp/NeoToolboxApp.swift` — menu bar syncNow → service.

---

### Task 1: Settings default + stored mapping

**Files:**
- Create: `Sources/NeoToolboxCore/CalendarSync/CalendarSyncSettings+Stored.swift`
- Test: `Tests/NeoToolboxCoreTests/CalendarSyncConfigTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/NeoToolboxCoreTests/CalendarSyncConfigTests.swift`:

```swift
import XCTest
@testable import NeoToolboxCore

final class CalendarSyncConfigTests: XCTestCase {
    func testSettingsRoundTripThroughStored() {
        let settings = CalendarSyncSettings(
            toolID: "calendar-sync",
            isEnabled: true,
            syncIntervalSeconds: 1800,
            syncWindowDays: 30,
            dingTalkUsername: "alice",
            feishuCalendarID: "cal-1",
            deleteSyncEnabled: true
        )
        let stored = settings.asStoredToolSettings(
            lastSuccessfulSyncAt: nil,
            consecutiveFailureCount: 0
        )
        XCTAssertEqual(stored.dingTalkUsername, "alice")
        XCTAssertEqual(stored.feishuCalendarID, "cal-1")
        XCTAssertEqual(CalendarSyncSettings(stored: stored), settings)
    }

    func testUnconfiguredDefault() {
        let settings = CalendarSyncSettings.unconfigured
        XCTAssertEqual(settings.toolID, "calendar-sync")
        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(settings.syncIntervalSeconds, 1800)
        XCTAssertEqual(settings.syncWindowDays, 30)
        XCTAssertTrue(settings.dingTalkUsername.isEmpty)
        XCTAssertTrue(settings.feishuCalendarID.isEmpty)
        XCTAssertFalse(settings.deleteSyncEnabled)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CalendarSyncConfigTests`
Expected: FAIL to compile — `asStoredToolSettings`, `init(stored:)`, `unconfigured` undefined.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/NeoToolboxCore/CalendarSync/CalendarSyncSettings+Stored.swift`:

```swift
import Foundation

public extension CalendarSyncSettings {
    static let defaultToolID = "calendar-sync"

    static let unconfigured = CalendarSyncSettings(
        toolID: defaultToolID,
        isEnabled: false,
        syncIntervalSeconds: 1800,
        syncWindowDays: 30,
        dingTalkUsername: "",
        feishuCalendarID: "",
        deleteSyncEnabled: false
    )

    init(stored: StoredToolSettings) {
        self.init(
            toolID: stored.toolID,
            isEnabled: stored.isEnabled,
            syncIntervalSeconds: stored.syncIntervalSeconds,
            syncWindowDays: stored.syncWindowDays,
            dingTalkUsername: stored.dingTalkUsername,
            feishuCalendarID: stored.feishuCalendarID,
            deleteSyncEnabled: stored.deleteSyncEnabled
        )
    }

    func asStoredToolSettings(
        lastSuccessfulSyncAt: Date?,
        consecutiveFailureCount: Int
    ) -> StoredToolSettings {
        StoredToolSettings(
            toolID: toolID,
            isEnabled: isEnabled,
            syncIntervalSeconds: syncIntervalSeconds,
            syncWindowDays: syncWindowDays,
            dingTalkUsername: dingTalkUsername,
            feishuCalendarID: feishuCalendarID,
            deleteSyncEnabled: deleteSyncEnabled,
            lastSuccessfulSyncAt: lastSuccessfulSyncAt,
            consecutiveFailureCount: consecutiveFailureCount
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CalendarSyncConfigTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/NeoToolboxCore/CalendarSync/CalendarSyncSettings+Stored.swift Tests/NeoToolboxCoreTests/CalendarSyncConfigTests.swift
git commit -m "feat: map calendar sync settings to stored settings"
```

---

### Task 2: In-memory state store

**Files:**
- Create: `Sources/NeoToolboxCore/Storage/InMemoryStateStore.swift`
- Test: `Tests/NeoToolboxCoreTests/CalendarSyncConfigTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `CalendarSyncConfigTests`:

```swift
    func testInMemoryStateStoreSavesAndLoadsToolSettings() throws {
        let store = InMemoryStateStore()
        let stored = CalendarSyncSettings.unconfigured.asStoredToolSettings(
            lastSuccessfulSyncAt: nil,
            consecutiveFailureCount: 0
        )
        try store.saveToolSettings(stored)
        let loaded = try store.loadToolSettings(toolID: "calendar-sync")
        XCTAssertEqual(loaded, stored)
        XCTAssertNil(try store.loadToolSettings(toolID: "missing"))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CalendarSyncConfigTests`
Expected: FAIL — `InMemoryStateStore` undefined.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/NeoToolboxCore/Storage/InMemoryStateStore.swift`:

```swift
import Foundation

public final class InMemoryStateStore: StateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var toolSettings: [String: StoredToolSettings] = [:]
    private var mappings: [String: EventMapping] = [:]
    private var archived: [String: EventMapping] = [:]
    private var reports: [SyncReportRecord] = []
    private var actions: [ActionLogRecord] = []

    public init() {}

    public func saveToolSettings(_ settings: StoredToolSettings) throws {
        lock.lock(); defer { lock.unlock() }
        toolSettings[settings.toolID] = settings
    }

    public func loadToolSettings(toolID: String) throws -> StoredToolSettings? {
        lock.lock(); defer { lock.unlock() }
        return toolSettings[toolID]
    }

    public func upsertEventMapping(_ mapping: EventMapping) throws {
        lock.lock(); defer { lock.unlock() }
        mappings[mapping.mappingKey] = mapping
    }

    public func loadEventMappings(calendarID: String) throws -> [EventMapping] {
        lock.lock(); defer { lock.unlock() }
        return mappings.values.filter { $0.feishuCalendarID == calendarID }
    }

    public func archiveEventMapping(mappingKey: String) throws {
        lock.lock(); defer { lock.unlock() }
        if let mapping = mappings.removeValue(forKey: mappingKey) {
            archived[mappingKey] = mapping
        }
    }

    public func loadArchivedEventMappings() throws -> [EventMapping] {
        lock.lock(); defer { lock.unlock() }
        return Array(archived.values)
    }

    public func saveSyncReport(_ report: SyncReportRecord) throws {
        lock.lock(); defer { lock.unlock() }
        reports.append(report)
    }

    public func saveActionLog(_ action: ActionLogRecord) throws {
        lock.lock(); defer { lock.unlock() }
        actions.append(action)
    }

    public func loadSyncReports() throws -> [SyncReportRecord] {
        lock.lock(); defer { lock.unlock() }
        return reports
    }

    public func loadActionLogs(reportID: String) throws -> [ActionLogRecord] {
        lock.lock(); defer { lock.unlock() }
        return actions.filter { $0.reportID == reportID }
    }
}
```

> NOTE: Verify the `EventMapping` field names (`mappingKey`, `feishuCalendarID`) against `Sources/NeoToolboxCore/Sync/` before running. If they differ, match the real names — the filter only needs to scope by calendar.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CalendarSyncConfigTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/NeoToolboxCore/Storage/InMemoryStateStore.swift Tests/NeoToolboxCoreTests/CalendarSyncConfigTests.swift
git commit -m "feat: add in-memory state store"
```

---

### Task 3: Feishu calendar provider protocol

**Files:**
- Create: `Sources/NeoToolboxCore/Feishu/FeishuCalendarProviding.swift`
- Test: `Tests/NeoToolboxCoreTests/CalendarSyncConfigTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `CalendarSyncConfigTests`:

```swift
    func testFeishuClientConformsToProvider() async throws {
        let provider: any FeishuCalendarProviding = FeishuCLIClient(
            executablePath: "/nonexistent/feishu-cli"
        )
        let check = await provider.checkDependency()
        XCTAssertEqual(check.status, .missing)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CalendarSyncConfigTests`
Expected: FAIL — `FeishuCalendarProviding` undefined.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/NeoToolboxCore/Feishu/FeishuCalendarProviding.swift`:

```swift
import Foundation

public protocol FeishuCalendarProviding: Sendable {
    func checkDependency() async -> DependencyCheck
    func listCalendars() async throws -> [FeishuCalendar]
}

extension FeishuCLIClient: FeishuCalendarProviding {}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CalendarSyncConfigTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/NeoToolboxCore/Feishu/FeishuCalendarProviding.swift Tests/NeoToolboxCoreTests/CalendarSyncConfigTests.swift
git commit -m "feat: add Feishu calendar provider protocol"
```

---

### Task 4: Unavailable stub clients (safe defaults)

**Files:**
- Create: `Sources/NeoToolboxCore/CalendarSync/UnavailableClients.swift`
- Test: `Tests/NeoToolboxCoreTests/CalendarSyncConfigTests.swift`

- [ ] **Step 1: Write the failing test**

Append:

```swift
    func testUnavailableFeishuProviderReportsMissing() async {
        let provider = UnavailableFeishuClient()
        let check = await provider.checkDependency()
        XCTAssertEqual(check.status, .missing)
    }

    func testUnavailableDingTalkFetcherThrows() async {
        let fetcher = UnavailableDingTalkClient()
        await XCTAssertThrowsErrorAsync(
            try await fetcher.fetchEvents(settings: .unconfigured, password: "")
        )
    }
```

Also add this async-throws helper at the bottom of the file (inside the class is fine, or as a top-level func in the same file):

```swift
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error but none thrown", file: file, line: line)
    } catch {
        // expected
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CalendarSyncConfigTests`
Expected: FAIL — `UnavailableFeishuClient` / `UnavailableDingTalkClient` undefined.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/NeoToolboxCore/CalendarSync/UnavailableClients.swift`:

```swift
import Foundation

struct CalendarSyncUnavailableError: Error, Equatable {
    let message: String
}

public struct UnavailableFeishuClient: FeishuCalendarProviding, FeishuCalendarWriting {
    public init() {}

    public func checkDependency() async -> DependencyCheck {
        DependencyCheck(status: .missing, executablePath: nil, message: "feishu-cli is not configured")
    }

    public func listCalendars() async throws -> [FeishuCalendar] {
        throw CalendarSyncUnavailableError(message: "feishu-cli is not configured")
    }

    public func createEvent(_ event: NormalizedEvent, calendarID: String) async throws -> String {
        throw CalendarSyncUnavailableError(message: "feishu-cli is not configured")
    }

    public func updateEvent(_ mapping: EventMapping, with event: NormalizedEvent) async throws {
        throw CalendarSyncUnavailableError(message: "feishu-cli is not configured")
    }

    public func deleteEvent(_ mapping: EventMapping) async throws {
        throw CalendarSyncUnavailableError(message: "feishu-cli is not configured")
    }
}

public struct UnavailableDingTalkClient: DingTalkEventFetching {
    public init() {}

    public func fetchEvents(settings: CalendarSyncSettings, password: String) async throws -> [NormalizedEvent] {
        throw CalendarSyncUnavailableError(message: "DingTalk CalDAV is not configured")
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CalendarSyncConfigTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/NeoToolboxCore/CalendarSync/UnavailableClients.swift Tests/NeoToolboxCoreTests/CalendarSyncConfigTests.swift
git commit -m "feat: add unavailable stub clients as safe defaults"
```

---

### Task 5: State-store adapter for the sync engine

**Files:**
- Create: `Sources/NeoToolboxCore/Sync/CalendarSyncStateStoreAdapter.swift`
- Test: `Tests/NeoToolboxCoreTests/CalendarSyncConfigTests.swift`

- [ ] **Step 1: Write the failing test**

Append:

```swift
    func testStateStoreAdapterBridgesToEngineProtocol() throws {
        let backing = InMemoryStateStore()
        let adapter = CalendarSyncStateStoreAdapter(store: backing)
        // Adapter must satisfy the engine's protocol.
        let engineStore: any CalendarSyncStateStoring = adapter
        let mappings = try engineStore.loadActiveMappings(calendarID: "cal-1")
        XCTAssertTrue(mappings.isEmpty)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CalendarSyncConfigTests`
Expected: FAIL — `CalendarSyncStateStoreAdapter` undefined.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/NeoToolboxCore/Sync/CalendarSyncStateStoreAdapter.swift`:

```swift
import Foundation

public struct CalendarSyncStateStoreAdapter: CalendarSyncStateStoring {
    private let store: any StateStoring

    public init(store: any StateStoring) {
        self.store = store
    }

    public func loadActiveMappings(calendarID: String) throws -> [EventMapping] {
        try store.loadEventMappings(calendarID: calendarID)
    }

    public func upsertMapping(_ mapping: EventMapping) throws {
        try store.upsertEventMapping(mapping)
    }

    public func archiveMapping(mappingKey: String) throws {
        try store.archiveEventMapping(mappingKey: mappingKey)
    }
}
```

> NOTE: `any StateStoring` is not `Sendable`; `CalendarSyncStateStoring` requires `Sendable`. If the compiler complains, mark the adapter `@unchecked Sendable` as a `final class` instead of a struct. Prefer the struct form first; switch only if the build fails.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CalendarSyncConfigTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/NeoToolboxCore/Sync/CalendarSyncStateStoreAdapter.swift Tests/NeoToolboxCoreTests/CalendarSyncConfigTests.swift
git commit -m "feat: adapt state store to calendar sync engine protocol"
```

---

### Task 6: Connection test result type

**Files:**
- Create: `Sources/NeoToolboxCore/CalendarSync/ConnectionTestResult.swift`
- Test: `Tests/NeoToolboxCoreTests/CalendarSyncConfigTests.swift`

- [ ] **Step 1: Write the failing test**

Append:

```swift
    func testConnectionTestResultEquality() {
        let a = ConnectionTestResult(dingTalk: .ok, feishu: .failed("nope"))
        let b = ConnectionTestResult(dingTalk: .ok, feishu: .failed("nope"))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, ConnectionTestResult(dingTalk: .ok, feishu: .ok))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CalendarSyncConfigTests`
Expected: FAIL — `ConnectionTestResult` undefined.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/NeoToolboxCore/CalendarSync/ConnectionTestResult.swift`:

```swift
import Foundation

public struct ConnectionTestResult: Equatable, Sendable {
    public enum Side: Equatable, Sendable {
        case ok
        case failed(String)

        public var isOK: Bool {
            if case .ok = self { return true }
            return false
        }
    }

    public var dingTalk: Side
    public var feishu: Side

    public init(dingTalk: Side, feishu: Side) {
        self.dingTalk = dingTalk
        self.feishu = feishu
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CalendarSyncConfigTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/NeoToolboxCore/CalendarSync/ConnectionTestResult.swift Tests/NeoToolboxCoreTests/CalendarSyncConfigTests.swift
git commit -m "feat: add connection test result type"
```

---

### Task 7: Extend `CalendarSyncService` with config dependencies + state

**Files:**
- Modify: `Sources/NeoToolboxCore/CalendarSync/CalendarSyncService.swift`
- Test: `Tests/NeoToolboxCoreTests/CalendarSyncConfigTests.swift`

This task only widens the init and adds stored state. Existing `CalendarSyncServiceTests` must keep passing because every new param has a default and `syncRunner` stays last.

- [ ] **Step 1: Write the failing test**

Append a `@MainActor` test class to `CalendarSyncConfigTests.swift` (separate class so it can be `@MainActor`):

```swift
@MainActor
final class CalendarSyncServiceConfigTests: XCTestCase {
    func testServiceStartsUnconfigured() {
        let service = CalendarSyncService(
            stateStore: InMemoryStateStore(),
            credentialStore: MemoryCredentialStore()
        )
        XCTAssertEqual(service.settings, .unconfigured)
        XCTAssertFalse(service.hasStoredPassword)
        XCTAssertTrue(service.availableCalendars.isEmpty)
        XCTAssertNil(service.testResult)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CalendarSyncServiceConfigTests`
Expected: FAIL — the new init params / published properties don't exist.

- [ ] **Step 3: Write minimal implementation**

In `CalendarSyncService.swift`, replace the stored-properties block and `init` (lines ~16–47) with:

```swift
    @Published public private(set) var status: CalendarSyncStatus
    @Published public private(set) var lastReport: SyncReport?
    @Published public private(set) var dependencyCheck: DependencyCheck
    @Published public private(set) var setupSteps: [CalendarSyncSetupStep]
    @Published public private(set) var recentLogs: [RuntimeLog]
    @Published public private(set) var consecutiveFailureCount: Int

    @Published public private(set) var settings: CalendarSyncSettings
    @Published public private(set) var availableCalendars: [FeishuCalendar]
    @Published public private(set) var testResult: ConnectionTestResult?
    @Published public private(set) var hasStoredPassword: Bool

    private let stateStore: any StateStoring
    private let credentialStore: any CredentialStoring
    private let feishuProvider: any FeishuCalendarProviding
    private let feishuWriter: any FeishuCalendarWriting
    private let caldavClient: any DingTalkEventFetching

    private var syncRunner: (any CalendarSyncRunning)?
    private var isRunning = false
    private var timerTask: Task<Void, Never>?

    public init(
        status: CalendarSyncStatus = CalendarSyncStatus(),
        lastReport: SyncReport? = nil,
        dependencyCheck: DependencyCheck = DependencyCheck(
            status: .missing,
            executablePath: nil,
            message: "feishu-cli has not been checked"
        ),
        setupSteps: [CalendarSyncSetupStep] = CalendarSyncSetupStep.defaultSteps,
        recentLogs: [RuntimeLog] = RuntimeLog.sample,
        consecutiveFailureCount: Int = 0,
        settings: CalendarSyncSettings = .unconfigured,
        availableCalendars: [FeishuCalendar] = [],
        hasStoredPassword: Bool = false,
        stateStore: any StateStoring = InMemoryStateStore(),
        credentialStore: any CredentialStoring = MemoryCredentialStore(),
        feishuProvider: any FeishuCalendarProviding = UnavailableFeishuClient(),
        feishuWriter: any FeishuCalendarWriting = UnavailableFeishuClient(),
        caldavClient: any DingTalkEventFetching = UnavailableDingTalkClient(),
        syncRunner: (any CalendarSyncRunning)? = nil
    ) {
        self.status = status
        self.lastReport = lastReport
        self.dependencyCheck = dependencyCheck
        self.setupSteps = setupSteps
        self.recentLogs = recentLogs
        self.consecutiveFailureCount = consecutiveFailureCount
        self.settings = settings
        self.availableCalendars = availableCalendars
        self.testResult = nil
        self.hasStoredPassword = hasStoredPassword
        self.stateStore = stateStore
        self.credentialStore = credentialStore
        self.feishuProvider = feishuProvider
        self.feishuWriter = feishuWriter
        self.caldavClient = caldavClient
        self.syncRunner = syncRunner
    }
```

Change the existing `private let syncRunner` to `private var syncRunner` (done above — note it moved out of the `let` block).

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CalendarSyncServiceConfigTests`
Expected: PASS.

Run: `swift test --filter CalendarSyncServiceTests`
Expected: PASS (existing tests unaffected).

- [ ] **Step 5: Commit**

```bash
git add Sources/NeoToolboxCore/CalendarSync/CalendarSyncService.swift Tests/NeoToolboxCoreTests/CalendarSyncConfigTests.swift
git commit -m "feat: add config dependencies to calendar sync service"
```

---

### Task 8: Derive setup steps from settings

**Files:**
- Modify: `Sources/NeoToolboxCore/CalendarSync/CalendarSyncService.swift`
- Test: `Tests/NeoToolboxCoreTests/CalendarSyncConfigTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `CalendarSyncServiceConfigTests`:

```swift
    func testSetupStepCompletenessReflectsConfig() {
        let service = CalendarSyncService(
            stateStore: InMemoryStateStore(),
            credentialStore: MemoryCredentialStore()
        )
        func step(_ id: String) -> Bool {
            service.setupSteps.first { $0.id == id }?.isComplete ?? false
        }
        // Unconfigured: nothing complete.
        XCTAssertFalse(step("dingtalk-caldav"))
        XCTAssertFalse(step("feishu-calendar"))

        service.applyConfiguredStateForTesting(
            settings: CalendarSyncSettings(
                toolID: "calendar-sync", isEnabled: true,
                syncIntervalSeconds: 1800, syncWindowDays: 30,
                dingTalkUsername: "alice", feishuCalendarID: "cal-1",
                deleteSyncEnabled: false
            ),
            hasStoredPassword: true,
            dependency: DependencyCheck(status: .available, executablePath: "/bin/feishu-cli", message: "ok")
        )
        XCTAssertTrue(step("feishu-cli"))
        XCTAssertTrue(step("dingtalk-caldav"))
        XCTAssertTrue(step("feishu-calendar"))
        XCTAssertTrue(step("sync-rules"))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CalendarSyncServiceConfigTests`
Expected: FAIL — `applyConfiguredStateForTesting` and the derivation don't exist.

- [ ] **Step 3: Write minimal implementation**

Add to `CalendarSyncService` (private helper + a test-only applier):

```swift
    private func recomputeSetupSteps() {
        let dingTalkReady = !settings.dingTalkUsername.isEmpty && hasStoredPassword
        let feishuCliReady = dependencyCheck.status == .available
        let calendarReady = !settings.feishuCalendarID.isEmpty
        let rulesReady = settings.syncIntervalSeconds > 0 && settings.syncWindowDays > 0
        let trialReady = lastReport != nil

        setupSteps = CalendarSyncSetupStep.defaultSteps.map { step in
            var copy = step
            switch step.id {
            case "feishu-cli": copy.isComplete = feishuCliReady
            case "dingtalk-caldav": copy.isComplete = dingTalkReady
            case "feishu-calendar": copy.isComplete = calendarReady
            case "sync-rules": copy.isComplete = rulesReady
            case "trial-run": copy.isComplete = trialReady
            default: break
            }
            return copy
        }
    }

    #if DEBUG
    func applyConfiguredStateForTesting(
        settings: CalendarSyncSettings,
        hasStoredPassword: Bool,
        dependency: DependencyCheck
    ) {
        self.settings = settings
        self.hasStoredPassword = hasStoredPassword
        self.dependencyCheck = dependency
        recomputeSetupSteps()
    }
    #endif
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CalendarSyncServiceConfigTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/NeoToolboxCore/CalendarSync/CalendarSyncService.swift Tests/NeoToolboxCoreTests/CalendarSyncConfigTests.swift
git commit -m "feat: derive setup steps from configuration"
```

---

### Task 9: `loadSettings()`

**Files:**
- Modify: `Sources/NeoToolboxCore/CalendarSync/CalendarSyncService.swift`
- Test: `Tests/NeoToolboxCoreTests/CalendarSyncConfigTests.swift`

- [ ] **Step 1: Write the failing test**

Append:

```swift
    func testLoadSettingsRestoresPersistedConfig() throws {
        let store = InMemoryStateStore()
        let creds = MemoryCredentialStore()
        try creds.savePassword("secret", account: "alice")
        let stored = CalendarSyncSettings(
            toolID: "calendar-sync", isEnabled: false,
            syncIntervalSeconds: 1800, syncWindowDays: 30,
            dingTalkUsername: "alice", feishuCalendarID: "cal-1",
            deleteSyncEnabled: false
        ).asStoredToolSettings(lastSuccessfulSyncAt: nil, consecutiveFailureCount: 0)
        try store.saveToolSettings(stored)

        let service = CalendarSyncService(stateStore: store, credentialStore: creds)
        service.loadSettings()

        XCTAssertEqual(service.settings.dingTalkUsername, "alice")
        XCTAssertEqual(service.settings.feishuCalendarID, "cal-1")
        XCTAssertTrue(service.hasStoredPassword)
        XCTAssertTrue(service.setupSteps.first { $0.id == "feishu-calendar" }?.isComplete ?? false)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CalendarSyncServiceConfigTests`
Expected: FAIL — `loadSettings` undefined.

- [ ] **Step 3: Write minimal implementation**

Add to `CalendarSyncService`:

```swift
    public func loadSettings() {
        do {
            guard let stored = try stateStore.loadToolSettings(toolID: CalendarSyncSettings.defaultToolID) else {
                settings = .unconfigured
                hasStoredPassword = false
                rebuildRunner()
                recomputeSetupSteps()
                return
            }
            settings = CalendarSyncSettings(stored: stored)
            consecutiveFailureCount = stored.consecutiveFailureCount
            if let last = stored.lastSuccessfulSyncAt {
                status = CalendarSyncStatus(state: status.state, lastSyncAt: last)
            }
            hasStoredPassword = (try? credentialStore.readPassword(account: settings.dingTalkUsername)) ?? nil != nil
            rebuildRunner()
            recomputeSetupSteps()
            if settings.isEnabled && isConfigured {
                startTimer(intervalSeconds: settings.syncIntervalSeconds)
            }
        } catch {
            recentLogs.insert(RuntimeLog(timestamp: Date(), level: .error, message: "Failed to load settings: \(error)"), at: 0)
        }
    }

    private var isConfigured: Bool {
        !settings.dingTalkUsername.isEmpty
            && !settings.feishuCalendarID.isEmpty
            && hasStoredPassword
    }
```

Add the runner factory (used here and in Task 10):

```swift
    private func rebuildRunner() {
        guard isConfigured else {
            syncRunner = nil
            return
        }
        let engine = SyncEngine(
            settings: settings,
            eventFetcher: caldavClient,
            feishuWriter: feishuWriter,
            stateStore: CalendarSyncStateStoreAdapter(store: stateStore),
            credentialStore: credentialStore
        )
        syncRunner = engine
    }
```

> NOTE: `hasStoredPassword = (try? ...) ?? nil != nil` is intentionally explicit. If the compiler is unhappy with operator precedence, write it as:
> ```swift
> let pw = (try? credentialStore.readPassword(account: settings.dingTalkUsername)) ?? nil
> hasStoredPassword = (pw?.isEmpty == false)
> ```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CalendarSyncServiceConfigTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/NeoToolboxCore/CalendarSync/CalendarSyncService.swift Tests/NeoToolboxCoreTests/CalendarSyncConfigTests.swift
git commit -m "feat: load persisted calendar sync settings"
```

---

### Task 10: `saveSettings(_:password:)`

**Files:**
- Modify: `Sources/NeoToolboxCore/CalendarSync/CalendarSyncService.swift`
- Test: `Tests/NeoToolboxCoreTests/CalendarSyncConfigTests.swift`

- [ ] **Step 1: Write the failing test**

Append:

```swift
    func testSaveSettingsPersistsAndStoresPassword() throws {
        let store = InMemoryStateStore()
        let creds = MemoryCredentialStore()
        let service = CalendarSyncService(stateStore: store, credentialStore: creds)

        let draft = CalendarSyncSettings(
            toolID: "calendar-sync", isEnabled: true,
            syncIntervalSeconds: 600, syncWindowDays: 7,
            dingTalkUsername: "bob", feishuCalendarID: "cal-9",
            deleteSyncEnabled: true
        )
        try service.saveSettings(draft, password: "pw1")

        XCTAssertEqual(try store.loadToolSettings(toolID: "calendar-sync")?.dingTalkUsername, "bob")
        XCTAssertEqual(try creds.readPassword(account: "bob"), "pw1")
        XCTAssertTrue(service.hasStoredPassword)
        XCTAssertEqual(service.settings, draft)
    }

    func testSaveSettingsWithEmptyPasswordKeepsExisting() throws {
        let store = InMemoryStateStore()
        let creds = MemoryCredentialStore()
        try creds.savePassword("existing", account: "bob")
        let service = CalendarSyncService(stateStore: store, credentialStore: creds)

        let draft = CalendarSyncSettings(
            toolID: "calendar-sync", isEnabled: false,
            syncIntervalSeconds: 1800, syncWindowDays: 30,
            dingTalkUsername: "bob", feishuCalendarID: "cal-1",
            deleteSyncEnabled: false
        )
        try service.saveSettings(draft, password: nil)

        XCTAssertEqual(try creds.readPassword(account: "bob"), "existing")
        XCTAssertTrue(service.hasStoredPassword)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CalendarSyncServiceConfigTests`
Expected: FAIL — `saveSettings` undefined.

- [ ] **Step 3: Write minimal implementation**

Add to `CalendarSyncService`:

```swift
    public func saveSettings(_ draft: CalendarSyncSettings, password: String?) throws {
        if let password, !password.isEmpty {
            try credentialStore.savePassword(password, account: draft.dingTalkUsername)
        }

        let existing = try? stateStore.loadToolSettings(toolID: draft.toolID)
        let stored = draft.asStoredToolSettings(
            lastSuccessfulSyncAt: existing??.lastSuccessfulSyncAt ?? nil,
            consecutiveFailureCount: existing??.consecutiveFailureCount ?? 0
        )
        try stateStore.saveToolSettings(stored)

        settings = draft
        let pw = (try? credentialStore.readPassword(account: draft.dingTalkUsername)) ?? nil
        hasStoredPassword = (pw?.isEmpty == false)

        rebuildRunner()
        recomputeSetupSteps()

        if draft.isEnabled && isConfigured {
            startTimer(intervalSeconds: draft.syncIntervalSeconds)
        } else {
            stopTimer()
        }
    }
```

> NOTE: `try? stateStore.loadToolSettings(...)` is `StoredToolSettings??`. The `existing??.field ?? default` double-optional flattening is correct; if the compiler objects, bind first:
> ```swift
> let prior = (try? stateStore.loadToolSettings(toolID: draft.toolID)) ?? nil
> let stored = draft.asStoredToolSettings(
>     lastSuccessfulSyncAt: prior?.lastSuccessfulSyncAt,
>     consecutiveFailureCount: prior?.consecutiveFailureCount ?? 0
> )
> ```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CalendarSyncServiceConfigTests`
Expected: PASS (both new tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/NeoToolboxCore/CalendarSync/CalendarSyncService.swift Tests/NeoToolboxCoreTests/CalendarSyncConfigTests.swift
git commit -m "feat: save calendar sync settings and credentials"
```

---

### Task 11: `loadFeishuCalendars()`

**Files:**
- Modify: `Sources/NeoToolboxCore/CalendarSync/CalendarSyncService.swift`
- Test: `Tests/NeoToolboxCoreTests/CalendarSyncConfigTests.swift`

- [ ] **Step 1: Write the failing test**

First add a fake provider near the top of `CalendarSyncConfigTests.swift` (top-level, after imports):

```swift
final class FakeFeishuProvider: FeishuCalendarProviding, @unchecked Sendable {
    var dependency: DependencyCheck
    var calendars: [FeishuCalendar]
    var listError: Error?

    init(
        dependency: DependencyCheck = DependencyCheck(status: .available, executablePath: "/bin/feishu-cli", message: "ok"),
        calendars: [FeishuCalendar] = [],
        listError: Error? = nil
    ) {
        self.dependency = dependency
        self.calendars = calendars
        self.listError = listError
    }

    func checkDependency() async -> DependencyCheck { dependency }

    func listCalendars() async throws -> [FeishuCalendar] {
        if let listError { throw listError }
        return calendars
    }
}
```

Append to `CalendarSyncServiceConfigTests`:

```swift
    func testLoadFeishuCalendarsPopulatesList() async {
        let provider = FakeFeishuProvider(calendars: [
            FeishuCalendar(id: "c1", summary: "Work"),
            FeishuCalendar(id: "c2", summary: "Personal")
        ])
        let service = CalendarSyncService(
            stateStore: InMemoryStateStore(),
            credentialStore: MemoryCredentialStore(),
            feishuProvider: provider
        )
        await service.loadFeishuCalendars()
        XCTAssertEqual(service.availableCalendars.map(\.id), ["c1", "c2"])
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CalendarSyncServiceConfigTests`
Expected: FAIL — `loadFeishuCalendars` undefined.

- [ ] **Step 3: Write minimal implementation**

Add to `CalendarSyncService`:

```swift
    public func loadFeishuCalendars() async {
        dependencyCheck = await feishuProvider.checkDependency()
        guard dependencyCheck.status == .available else {
            availableCalendars = []
            recomputeSetupSteps()
            recentLogs.insert(RuntimeLog(timestamp: Date(), level: .warning, message: dependencyCheck.message), at: 0)
            return
        }
        do {
            availableCalendars = try await feishuProvider.listCalendars()
        } catch {
            availableCalendars = []
            recentLogs.insert(RuntimeLog(timestamp: Date(), level: .error, message: "Failed to list calendars: \(error)"), at: 0)
        }
        recomputeSetupSteps()
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CalendarSyncServiceConfigTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/NeoToolboxCore/CalendarSync/CalendarSyncService.swift Tests/NeoToolboxCoreTests/CalendarSyncConfigTests.swift
git commit -m "feat: list Feishu calendars for config dropdown"
```

---

### Task 12: `testConnection(_:password:)`

**Files:**
- Modify: `Sources/NeoToolboxCore/CalendarSync/CalendarSyncService.swift`
- Test: `Tests/NeoToolboxCoreTests/CalendarSyncConfigTests.swift`

- [ ] **Step 1: Write the failing test**

Add a fake CalDAV fetcher near the top of the file (top-level):

```swift
final class FakeDingTalkFetcher: DingTalkEventFetching, @unchecked Sendable {
    var error: Error?
    init(error: Error? = nil) { self.error = error }
    func fetchEvents(settings: CalendarSyncSettings, password: String) async throws -> [NormalizedEvent] {
        if let error { throw error }
        return []
    }
}

struct TestOnlyError: Error {}
```

Append to `CalendarSyncServiceConfigTests`:

```swift
    func testTestConnectionReportsBothSidesOK() async {
        let service = CalendarSyncService(
            stateStore: InMemoryStateStore(),
            credentialStore: MemoryCredentialStore(),
            feishuProvider: FakeFeishuProvider(calendars: [FeishuCalendar(id: "c1", summary: "Work")]),
            caldavClient: FakeDingTalkFetcher()
        )
        let draft = CalendarSyncSettings(
            toolID: "calendar-sync", isEnabled: false,
            syncIntervalSeconds: 1800, syncWindowDays: 30,
            dingTalkUsername: "alice", feishuCalendarID: "c1",
            deleteSyncEnabled: false
        )
        let result = await service.testConnection(draft, password: "pw")
        XCTAssertTrue(result.dingTalk.isOK)
        XCTAssertTrue(result.feishu.isOK)
        XCTAssertEqual(service.testResult, result)
    }

    func testTestConnectionReportsDingTalkFailure() async {
        let service = CalendarSyncService(
            stateStore: InMemoryStateStore(),
            credentialStore: MemoryCredentialStore(),
            feishuProvider: FakeFeishuProvider(),
            caldavClient: FakeDingTalkFetcher(error: TestOnlyError())
        )
        let draft = CalendarSyncSettings.unconfigured
        let result = await service.testConnection(draft, password: "pw")
        XCTAssertFalse(result.dingTalk.isOK)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CalendarSyncServiceConfigTests`
Expected: FAIL — `testConnection` undefined.

- [ ] **Step 3: Write minimal implementation**

Add to `CalendarSyncService`:

```swift
    @discardableResult
    public func testConnection(_ draft: CalendarSyncSettings, password: String?) async -> ConnectionTestResult {
        let feishuSide = await testFeishuSide()
        let dingTalkSide = await testDingTalkSide(draft, password: password)
        let result = ConnectionTestResult(dingTalk: dingTalkSide, feishu: feishuSide)
        testResult = result
        recomputeSetupSteps()
        return result
    }

    private func testFeishuSide() async -> ConnectionTestResult.Side {
        dependencyCheck = await feishuProvider.checkDependency()
        guard dependencyCheck.status == .available else {
            return .failed(dependencyCheck.message)
        }
        do {
            availableCalendars = try await feishuProvider.listCalendars()
            return .ok
        } catch {
            return .failed(String(describing: error))
        }
    }

    private func testDingTalkSide(_ draft: CalendarSyncSettings, password: String?) async -> ConnectionTestResult.Side {
        let pw: String
        if let password, !password.isEmpty {
            pw = password
        } else {
            pw = ((try? credentialStore.readPassword(account: draft.dingTalkUsername)) ?? nil) ?? ""
        }
        do {
            _ = try await caldavClient.fetchEvents(settings: draft, password: pw)
            return .ok
        } catch {
            return .failed(String(describing: error))
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CalendarSyncServiceConfigTests`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/NeoToolboxCore/CalendarSync/CalendarSyncService.swift Tests/NeoToolboxCoreTests/CalendarSyncConfigTests.swift
git commit -m "feat: test DingTalk and Feishu connections"
```

---

### Task 13: `CalendarSyncService.live()` factory

**Files:**
- Modify: `Sources/NeoToolboxCore/CalendarSync/CalendarSyncService.swift`
- Test: `Tests/NeoToolboxCoreTests/CalendarSyncConfigTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `CalendarSyncServiceConfigTests`:

```swift
    func testLiveFactoryBuildsServiceAtPath() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("neo-toolbox-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("state.sqlite3").path

        let service = try CalendarSyncService.live(databasePath: dbPath)
        XCTAssertEqual(service.settings, .unconfigured)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CalendarSyncServiceConfigTests`
Expected: FAIL — `live(databasePath:)` undefined.

- [ ] **Step 3: Write minimal implementation**

Add to `CalendarSyncService`:

```swift
    public static func live(databasePath: String) throws -> CalendarSyncService {
        let store = try SQLiteStateStore(path: databasePath)
        let credentials = KeychainCredentialStore()
        let feishu = FeishuCLIClient()
        let caldav = DingTalkCalDAVClient()
        let service = CalendarSyncService(
            stateStore: store,
            credentialStore: credentials,
            feishuProvider: feishu,
            feishuWriter: feishu,
            caldavClient: caldav
        )
        service.loadSettings()
        return service
    }
```

> NOTE: Confirm `KeychainCredentialStore()` has a no-arg init. If it needs a service-name argument, pass `KeychainCredentialStore(service: "com.nova-sy.neotoolbox")` (check `Sources/NeoToolboxCore/Security/KeychainCredentialStore.swift`).

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CalendarSyncServiceConfigTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/NeoToolboxCore/CalendarSync/CalendarSyncService.swift Tests/NeoToolboxCoreTests/CalendarSyncConfigTests.swift
git commit -m "feat: add live factory for calendar sync service"
```

---

### Task 14: `SettingsView`

**Files:**
- Create: `Sources/NeoToolboxApp/Dashboard/Settings/SettingsView.swift`

This is a SwiftUI view; verify via build (SwiftUI views are not unit-tested here, consistent with the existing app target).

- [ ] **Step 1: Write the view**

Create `Sources/NeoToolboxApp/Dashboard/Settings/SettingsView.swift`:

```swift
import NeoToolboxCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var service: CalendarSyncService

    @State private var username: String = ""
    @State private var password: String = ""
    @State private var feishuCalendarID: String = ""
    @State private var intervalSeconds: Int = 1800
    @State private var windowDays: Int = 30
    @State private var deleteSyncEnabled: Bool = false
    @State private var isEnabled: Bool = false
    @State private var isBusy = false
    @State private var saveError: String?

    private let intervalOptions = [600, 1800, 3600]
    private let windowOptions = [7, 30, 90]

    var body: some View {
        Form {
            Section("DingTalk (CalDAV)") {
                TextField("CalDAV username", text: $username)
                SecureField(passwordPlaceholder, text: $password)
                if service.hasStoredPassword && password.isEmpty {
                    Text("Password saved in Keychain. Leave blank to keep it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Feishu calendar") {
                HStack {
                    Button("Load calendars") {
                        Task { isBusy = true; await service.loadFeishuCalendars(); isBusy = false }
                    }
                    .disabled(isBusy)
                    if isBusy { ProgressView().controlSize(.small) }
                }
                Picker("Target calendar", selection: $feishuCalendarID) {
                    Text("Not selected").tag("")
                    ForEach(service.availableCalendars, id: \.id) { cal in
                        Text(cal.summary).tag(cal.id)
                    }
                }
            }

            Section("Sync rules") {
                Picker("Interval", selection: $intervalSeconds) {
                    Text("10 minutes").tag(600)
                    Text("30 minutes").tag(1800)
                    Text("60 minutes").tag(3600)
                }
                Picker("Sync window", selection: $windowDays) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                Toggle("Sync deletions", isOn: $deleteSyncEnabled)
                Toggle("Enable scheduled sync", isOn: $isEnabled)
            }

            Section("Connection") {
                Button("Test connection") {
                    Task { isBusy = true; await service.testConnection(draft, password: passwordOrNil); isBusy = false }
                }
                .disabled(isBusy)
                if let result = service.testResult {
                    resultRow("DingTalk", result.dingTalk)
                    resultRow("Feishu", result.feishu)
                }
            }

            Section {
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                if let saveError {
                    Text(saveError).foregroundStyle(.red).font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(maxWidth: 640, alignment: .leading)
        .onAppear(perform: loadFromService)
    }

    private var draft: CalendarSyncSettings {
        CalendarSyncSettings(
            toolID: CalendarSyncSettings.defaultToolID,
            isEnabled: isEnabled,
            syncIntervalSeconds: intervalSeconds,
            syncWindowDays: windowDays,
            dingTalkUsername: username,
            feishuCalendarID: feishuCalendarID,
            deleteSyncEnabled: deleteSyncEnabled
        )
    }

    private var passwordOrNil: String? { password.isEmpty ? nil : password }
    private var passwordPlaceholder: String { service.hasStoredPassword ? "•••••••• (saved)" : "CalDAV password" }

    private func loadFromService() {
        let s = service.settings
        username = s.dingTalkUsername
        feishuCalendarID = s.feishuCalendarID
        intervalSeconds = intervalOptions.contains(s.syncIntervalSeconds) ? s.syncIntervalSeconds : 1800
        windowDays = windowOptions.contains(s.syncWindowDays) ? s.syncWindowDays : 30
        deleteSyncEnabled = s.deleteSyncEnabled
        isEnabled = s.isEnabled
    }

    private func save() {
        saveError = nil
        do {
            try service.saveSettings(draft, password: passwordOrNil)
            password = ""
        } catch {
            saveError = String(describing: error)
        }
    }

    @ViewBuilder
    private func resultRow(_ label: String, _ side: ConnectionTestResult.Side) -> some View {
        HStack {
            Image(systemName: side.isOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(side.isOK ? .green : .red)
            if case let .failed(message) = side {
                Text("\(label): \(message)").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("\(label): OK").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: Build complete (SettingsView not yet referenced — that's fine).

- [ ] **Step 3: Commit**

```bash
git add Sources/NeoToolboxApp/Dashboard/Settings/SettingsView.swift
git commit -m "feat: add calendar sync settings form view"
```

---

### Task 15: Route Settings to `SettingsView` and inject the service

**Files:**
- Modify: `Sources/NeoToolboxApp/Dashboard/DashboardView.swift`

- [ ] **Step 1: Modify `DashboardView` to take an injected service**

Replace the top of `DashboardView` (the `@StateObject` line) and the `.settings` case:

```swift
struct DashboardView: View {
    @State private var selection: SidebarItem = .calendarSync
    @ObservedObject var calendarSyncService: CalendarSyncService

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } detail: {
            detailView
        }
        .frame(minWidth: 880, minHeight: 560)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .calendarSync:
            CalendarSyncView(service: calendarSyncService)
        case .futureTools:
            PlaceholderDetailView(title: "Future Tools", subtitle: "Additional tools will appear here.")
        case .allToolStatus:
            PlaceholderDetailView(title: "All Tool Status", subtitle: "A toolbox-level health overview.")
        case .runtimeLogs:
            PlaceholderDetailView(title: "Runtime Logs", subtitle: "Recent tool activity and diagnostics.")
        case .dependencyChecks:
            PlaceholderDetailView(title: "Dependency Checks", subtitle: "External command and configuration checks.")
        case .settings:
            SettingsView(service: calendarSyncService)
        }
    }
}
```

(`@StateObject private var calendarSyncService = CalendarSyncService()` is removed — the service is now passed in.)

- [ ] **Step 2: Build**

Run: `swift build`
Expected: FAIL — `DashboardWindowController` constructs `DashboardView()` with no argument. Fixed in Task 16.

- [ ] **Step 3: Commit (after Task 16 builds green)**

Defer the commit; combine with Task 16 so the tree never holds a broken build. Proceed directly to Task 16.

---

### Task 16: Build live service in the window controller and wire the menu bar

**Files:**
- Modify: `Sources/NeoToolboxApp/DashboardWindowController.swift`
- Modify: `Sources/NeoToolboxApp/NeoToolboxApp.swift`

- [ ] **Step 1: Modify `DashboardWindowController` to own the live service**

Replace the file body:

```swift
import AppKit
import NeoToolboxCore
import SwiftUI

@MainActor
final class DashboardWindowController: ObservableObject {
    let service: CalendarSyncService
    private var window: NSWindow?

    init() {
        service = Self.makeService()
    }

    private static func makeService() -> CalendarSyncService {
        do {
            return try CalendarSyncService.live(databasePath: Self.databasePath())
        } catch {
            NSLog("Failed to build live CalendarSyncService: \(error)")
            return CalendarSyncService()
        }
    }

    private static func databasePath() -> String {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("NeoToolbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("state.sqlite3").path
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Neo Toolbox"
        window.center()
        window.contentView = NSHostingView(rootView: DashboardView(calendarSyncService: service))
        window.isReleasedWhenClosed = false
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
```

- [ ] **Step 2: Wire the menu-bar "Sync Now" to the service**

In `NeoToolboxApp.swift`, replace the `syncNow` closure:

```swift
                syncNow: {
                    dashboard.service.syncNow()
                },
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: Build complete.

- [ ] **Step 4: Run the test suite**

Run: `swift test`
Expected: All tests pass (existing + new `CalendarSyncConfigTests` / `CalendarSyncServiceConfigTests`).

- [ ] **Step 5: Manual smoke check**

Run: `swift run NeoToolboxApp`
Open the dashboard from the menu bar → select **Settings** → confirm the form renders with DingTalk/Feishu/Rules sections, a Load calendars button, Test connection, and Save. Quit afterward.

- [ ] **Step 6: Commit**

```bash
git add Sources/NeoToolboxApp/Dashboard/DashboardView.swift Sources/NeoToolboxApp/DashboardWindowController.swift Sources/NeoToolboxApp/NeoToolboxApp.swift
git commit -m "feat: wire settings view and live service into the app"
```

---

## Self-Review

**Spec coverage:**
- Single-page settings form, sidebar Settings item → Tasks 14, 15 (sidebar `.settings` already exists).
- Independent Test Connection button → Task 12 + Task 14.
- Feishu calendar dropdown via `listCalendars` → Tasks 11, 14.
- Interval/window preset dropdowns → Task 14.
- Service owns config lifecycle (load/save/test/list, derived steps, rebuild runner, timer) → Tasks 7–13.
- Persist non-secret to SQLite, password to Keychain → Tasks 1, 10, 13.
- AppDelegate/app wiring + Application Support DB path → Task 16.
- `FeishuCalendarProviding` test seam → Task 3. State-store adapter → Task 5. Error handling (test result, save alert, missing cli) → Tasks 6, 10, 11, 12, 14.
- Testing strategy (Memory stores + fakes) → Tasks 1–13.

**Placeholder scan:** No "TBD"/"add error handling" — every code step is concrete. Two `NOTE` callouts flag real-name verification (`EventMapping` fields, `KeychainCredentialStore` init) and a Swift double-optional ergonomics fallback; both give the exact alternative code.

**Type consistency:** `CalendarSyncSettings.defaultToolID` / `.unconfigured` (Task 1) reused in 7/9/10/13/14. `asStoredToolSettings`/`init(stored:)` (Task 1) used in 9/10. `rebuildRunner`/`isConfigured`/`recomputeSetupSteps` defined in 7–9 and reused consistently. `ConnectionTestResult.Side.isOK` (Task 6) used in 12/14. `CalendarSyncStateStoreAdapter(store:)` (Task 5) used in `rebuildRunner` (Task 9). Service init param order is fixed in Task 7 and all later `CalendarSyncService(...)` calls use labeled args, so default ordering holds.

**Known risks called out for the implementer:**
- `EventMapping` field names in `InMemoryStateStore` (Task 2 NOTE).
- `KeychainCredentialStore` init shape (Task 13 NOTE).
- `CalendarSyncStateStoreAdapter` Sendable form (Task 5 NOTE).
- `#if DEBUG` test helper (Task 8) — `swift test` builds in debug, so it is available to tests.
