# Multi-Source CalDAV Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Tencent Meeting as a second parallel CalDAV source alongside DingTalk, each syncing into its own chosen Feishu calendar, with per-source isolation.

**Architecture:** Keep `CalendarSyncSettings` as the per-source engine input. Introduce `CalendarSource` + `CalendarSyncConfiguration` for the multi-source app state. Generalize the DingTalk CalDAV client into `CalDAVCalendarClient` (host + collection strategy: fixed path or discovery). Scope event mappings by source so two sources sharing a Feishu calendar never delete each other's events. `CalendarSyncService` orchestrates one engine per enabled source.

**Tech Stack:** Swift 6.2, SwiftPM, SwiftUI (macOS 14+), XCTest, SQLite, CalDAV.

---

## Verified facts (from probing + code reads)

- `EventMapping` has `source: String`, `feishuCalendarID`, computed `mappingKey`. `EventMapping.calendarSyncSource == "neo-toolbox.calendar-sync"`.
- `CalendarSyncStateStoring` (SyncEngine's store): `loadActiveMappings(calendarID:)`, `upsertMapping`, `archiveMapping(mappingKey:)`.
- `StateStoring` (full store): `saveToolSettings`, `loadToolSettings(toolID:)`, `upsertEventMapping`, `loadEventMappings(calendarID:)`, `archiveEventMapping(mappingKey:)`, reports/logs. `SQLiteStateStore(path:)`, `InMemoryStateStore()` conform.
- `SQLiteStateStore.loadEventMappings` SQL filters `WHERE feishu_calendar_id = ? AND archived = 0`.
- `SyncEngine.init(settings:eventFetcher:feishuWriter:stateStore:credentialStore:)`; `run()` reads `settings.dingTalkUsername`, `settings.feishuCalendarID`, `settings.deleteSyncEnabled`, `settings.syncWindowDays`; tags new mappings with `EventMapping.calendarSyncSource`.
- `DingTalkCalDAVClient(transport:parser:endpoint:now:)` builds `…/dav/{username}/primary/`, REPORT with time-range; `CalDAVTransporting.send(URLRequest) -> Data`.
- Tencent CalDAV: host `cal.meeting.tencent.com`, well-known → `/caldav/`, principal `/caldav/{localpart}/`, home `/caldav/{localpart}/calendar`, collection dynamic id under home.
- `CalendarSyncService` (@MainActor) holds `settings: CalendarSyncSettings`, dependencies, `loadSettings/saveSettings/testConnection/loadFeishuCalendars`, builds a single runner.

## File Structure

New (NeoToolboxCore):
- `CalendarSync/CalendarSource.swift` — source model + configuration + sourceTag.
- `DingTalk/CalDAVCalendarClient.swift` — generalized client (host + strategy).
- `DingTalk/CalDAVDiscovery.swift` — PROPFIND discovery chain.

New (tests): `Tests/NeoToolboxCoreTests/MultiSourceTests.swift`, `CalDAVDiscoveryTests.swift`.

Modified: `CalendarSyncSettings.swift` (no field change — add a derive helper), `Storage/StateStore.swift` + `SQLiteStateStore.swift` + `InMemoryStateStore.swift` (sources table + source-scoped mappings), `Sync/SyncEngine.swift` (sourceTag), `Sync/CalendarSyncStateStoreAdapter.swift`, `CalendarSync/CalendarSyncService.swift`, `CalendarSync/ConnectionTestResult.swift`, `App/.../SettingsView.swift`.

Keep `DingTalkCalDAVClient.swift` as a thin wrapper over `CalDAVCalendarClient` for back-compat (existing tests reference it), or migrate its tests. This plan keeps it as a typealias-style wrapper.

---

### Task 1: Source model + configuration

**Files:**
- Create: `Sources/NeoToolboxCore/CalendarSync/CalendarSource.swift`
- Test: `Tests/NeoToolboxCoreTests/MultiSourceTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/NeoToolboxCoreTests/MultiSourceTests.swift`:

```swift
import XCTest
@testable import NeoToolboxCore

final class MultiSourceTests: XCTestCase {
    func testSourceKindTagAndHost() {
        XCTAssertEqual(CalendarSourceKind.dingtalk.mappingTag, "neo-toolbox.dingtalk")
        XCTAssertEqual(CalendarSourceKind.tencent.mappingTag, "neo-toolbox.tencent")
        XCTAssertEqual(CalendarSourceKind.dingtalk.host, "calendar.dingtalk.com")
        XCTAssertEqual(CalendarSourceKind.tencent.host, "cal.meeting.tencent.com")
    }

    func testSourceIdentityIsKind() {
        let s = CalendarSource(kind: .tencent, username: "u", feishuCalendarID: "c", isEnabled: true)
        XCTAssertEqual(s.id, "tencent")
    }

    func testDerivedPerSourceSettings() {
        let source = CalendarSource(kind: .dingtalk, username: "alice", feishuCalendarID: "cal-1", isEnabled: true)
        let config = CalendarSyncConfiguration(sources: [source], syncIntervalSeconds: 600, syncWindowDays: 14)
        let settings = config.settings(for: source)
        XCTAssertEqual(settings.dingTalkUsername, "alice")
        XCTAssertEqual(settings.feishuCalendarID, "cal-1")
        XCTAssertEqual(settings.syncIntervalSeconds, 600)
        XCTAssertEqual(settings.syncWindowDays, 14)
        XCTAssertTrue(settings.isEnabled)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MultiSourceTests`
Expected: FAIL — types undefined.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/NeoToolboxCore/CalendarSync/CalendarSource.swift`:

```swift
import Foundation

public enum CalendarSourceKind: String, Codable, Sendable, CaseIterable {
    case dingtalk
    case tencent

    public var host: String {
        switch self {
        case .dingtalk: "calendar.dingtalk.com"
        case .tencent: "cal.meeting.tencent.com"
        }
    }

    public var mappingTag: String {
        "neo-toolbox.\(rawValue)"
    }

    public var displayName: String {
        switch self {
        case .dingtalk: "DingTalk"
        case .tencent: "Tencent Meeting"
        }
    }
}

public struct CalendarSource: Equatable, Sendable, Identifiable {
    public var kind: CalendarSourceKind
    public var username: String
    public var feishuCalendarID: String
    public var isEnabled: Bool
    public var resolvedCollectionURL: String?

    public var id: String { kind.rawValue }

    public init(
        kind: CalendarSourceKind,
        username: String,
        feishuCalendarID: String,
        isEnabled: Bool,
        resolvedCollectionURL: String? = nil
    ) {
        self.kind = kind
        self.username = username
        self.feishuCalendarID = feishuCalendarID
        self.isEnabled = isEnabled
        self.resolvedCollectionURL = resolvedCollectionURL
    }

    public var isConfigured: Bool {
        !username.isEmpty && !feishuCalendarID.isEmpty
    }

    public func credentialAccount() -> String {
        "\(kind.rawValue):\(username)"
    }
}

public struct CalendarSyncConfiguration: Equatable, Sendable {
    public var sources: [CalendarSource]
    public var syncIntervalSeconds: Int
    public var syncWindowDays: Int

    public init(
        sources: [CalendarSource] = [],
        syncIntervalSeconds: Int = 1800,
        syncWindowDays: Int = 30
    ) {
        self.sources = sources
        self.syncIntervalSeconds = syncIntervalSeconds
        self.syncWindowDays = syncWindowDays
    }

    public func source(for kind: CalendarSourceKind) -> CalendarSource? {
        sources.first { $0.kind == kind }
    }

    /// Per-source value consumed by SyncEngine.
    public func settings(for source: CalendarSource) -> CalendarSyncSettings {
        CalendarSyncSettings(
            toolID: CalendarSyncSettings.defaultToolID,
            isEnabled: source.isEnabled,
            syncIntervalSeconds: syncIntervalSeconds,
            syncWindowDays: syncWindowDays,
            dingTalkUsername: source.username,
            feishuCalendarID: source.feishuCalendarID,
            deleteSyncEnabled: true
        )
    }
}
```

> NOTE: `deleteSyncEnabled: true` keeps current behavior (delete sync on). If a per-source delete toggle is wanted later, add it to `CalendarSource`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MultiSourceTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/NeoToolboxCore/CalendarSync/CalendarSource.swift Tests/NeoToolboxCoreTests/MultiSourceTests.swift
git commit -m "feat: add calendar source model and configuration"
```

---

### Task 2: Source-scoped mapping load (protocol + stores)

**Files:**
- Modify: `Sources/NeoToolboxCore/Sync/SyncEngine.swift` (protocol only)
- Modify: `Sources/NeoToolboxCore/Sync/CalendarSyncStateStoreAdapter.swift`
- Modify: `Sources/NeoToolboxCore/Storage/StateStore.swift`
- Modify: `Sources/NeoToolboxCore/Storage/SQLiteStateStore.swift`
- Modify: `Sources/NeoToolboxCore/Storage/InMemoryStateStore.swift`
- Test: `Tests/NeoToolboxCoreTests/MultiSourceTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `MultiSourceTests`:

```swift
    func testLoadEventMappingsIsolatesBySource() throws {
        let store = InMemoryStateStore()
        func mapping(uid: String, source: String) -> EventMapping {
            EventMapping(
                dingTalkUID: uid, recurrenceID: nil, feishuEventID: "f-\(uid)",
                feishuCalendarID: "shared", source: source,
                fingerprint: "fp", lastStart: Date(timeIntervalSince1970: 0),
                lastEnd: Date(timeIntervalSince1970: 60), lastSeenAt: Date(timeIntervalSince1970: 0)
            )
        }
        try store.upsertEventMapping(mapping(uid: "a", source: "neo-toolbox.dingtalk"))
        try store.upsertEventMapping(mapping(uid: "b", source: "neo-toolbox.tencent"))

        let ding = try store.loadEventMappings(calendarID: "shared", source: "neo-toolbox.dingtalk")
        XCTAssertEqual(ding.map(\.dingTalkUID), ["a"])
        let all = try store.loadEventMappings(calendarID: "shared")
        XCTAssertEqual(Set(all.map(\.dingTalkUID)), ["a", "b"])
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MultiSourceTests`
Expected: FAIL — `loadEventMappings(calendarID:source:)` undefined.

- [ ] **Step 3: Write minimal implementation**

In `StateStore.swift`, add to the `StateStoring` protocol (after the existing `loadEventMappings`):

```swift
    func loadEventMappings(calendarID: String, source: String) throws -> [EventMapping]
```

In `SyncEngine.swift`, change the `CalendarSyncStateStoring` protocol method:

```swift
public protocol CalendarSyncStateStoring: Sendable {
    func loadActiveMappings(calendarID: String, source: String) throws -> [EventMapping]
    func upsertMapping(_ mapping: EventMapping) throws
    func archiveMapping(mappingKey: String) throws
}
```

In `CalendarSyncStateStoreAdapter.swift`, update the bridge:

```swift
    public func loadActiveMappings(calendarID: String, source: String) throws -> [EventMapping] {
        try store.loadEventMappings(calendarID: calendarID, source: source)
    }
```

In `SQLiteStateStore.swift`, add the source-scoped query next to `loadEventMappings`:

```swift
    public func loadEventMappings(calendarID: String, source: String) throws -> [EventMapping] {
        try query(sql: "SELECT * FROM event_mappings WHERE feishu_calendar_id = ? AND source = ? AND archived = 0 ORDER BY mapping_key") { statement in
            eventMapping(from: statement)
        } bind: { statement in
            bind(statement, calendarID, 1)
            bind(statement, source, 2)
        }
    }
```

> NOTE: Match the existing `loadEventMappings(calendarID:)` body for the row-mapping closure name (`eventMapping(from:)`) and `bind` helper arity. Open the file and mirror the existing method exactly, only adding the `source` predicate + second bind.

In `InMemoryStateStore.swift`, add:

```swift
    public func loadEventMappings(calendarID: String, source: String) throws -> [EventMapping] {
        lock.lock(); defer { lock.unlock() }
        return mappings.values.filter { $0.feishuCalendarID == calendarID && $0.source == source }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MultiSourceTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/NeoToolboxCore/Sync Sources/NeoToolboxCore/Storage Tests/NeoToolboxCoreTests/MultiSourceTests.swift
git commit -m "feat: scope event mapping load by source"
```

---

### Task 3: SyncEngine source tag

**Files:**
- Modify: `Sources/NeoToolboxCore/Sync/SyncEngine.swift`
- Test: `Tests/NeoToolboxCoreTests/SyncEngineTests.swift` (verify existing still pass)

- [ ] **Step 1: Update SyncEngine to accept and use a source tag**

In `SyncEngine`, add a stored `sourceTag` with a default, and use it for the mapping load and new mappings.

Replace the stored properties + init:

```swift
    private let settings: CalendarSyncSettings
    private let eventFetcher: any DingTalkEventFetching
    private let feishuWriter: any FeishuCalendarWriting
    private let stateStore: any CalendarSyncStateStoring
    private let credentialStore: any CredentialStoring
    private let sourceTag: String

    public init(
        settings: CalendarSyncSettings,
        eventFetcher: any DingTalkEventFetching,
        feishuWriter: any FeishuCalendarWriting,
        stateStore: any CalendarSyncStateStoring,
        credentialStore: any CredentialStoring,
        sourceTag: String = EventMapping.calendarSyncSource
    ) {
        self.settings = settings
        self.eventFetcher = eventFetcher
        self.feishuWriter = feishuWriter
        self.stateStore = stateStore
        self.credentialStore = credentialStore
        self.sourceTag = sourceTag
    }
```

Change the mapping load in `run()`:

```swift
        let mappings = try stateStore.loadActiveMappings(calendarID: settings.feishuCalendarID, source: sourceTag)
```

Change the credential account in `run()` (so each source reads its own password):

```swift
        let password = try credentialStore.readPassword(account: settings.dingTalkUsername) ?? ""
```

> NOTE: keep this line as-is for now; the service stores per-source passwords under `"<kind>:<username>"`, but the engine is also given a `credentialStore` whose lookups the service controls. Task 9 passes a credential store keyed to the source. If simpler, the service can pre-read the password and inject a single-entry store. Keep the engine reading by `settings.dingTalkUsername` and have the service store the password under that account too (Task 9 handles this).

Change `mapping(for:feishuID:now:)` to tag with `sourceTag`:

```swift
            source: sourceTag,
```

(in the `EventMapping(...)` inside `mapping(for:feishuID:now:)`, replace `source: EventMapping.calendarSyncSource` with `source: sourceTag`.)

- [ ] **Step 2: Run tests**

Run: `swift test --filter SyncEngineTests`
Expected: PASS (default `sourceTag` preserves behavior; the fake store in those tests must implement the new `loadActiveMappings(calendarID:source:)` signature — update the test's fake).

> NOTE: `SyncEngineTests` has a fake conforming to `CalendarSyncStateStoring`. Update its `loadActiveMappings(calendarID:)` to `loadActiveMappings(calendarID:source:)` (ignore `source`, or filter by it). Make the minimal change to compile and keep assertions valid.

- [ ] **Step 3: Commit**

```bash
git add Sources/NeoToolboxCore/Sync/SyncEngine.swift Tests/NeoToolboxCoreTests/SyncEngineTests.swift
git commit -m "feat: tag sync engine mappings by source"
```

---

### Task 4: calendar_sources persistence

**Files:**
- Modify: `Sources/NeoToolboxCore/Storage/StateStore.swift`
- Modify: `Sources/NeoToolboxCore/Storage/SQLiteStateStore.swift`
- Modify: `Sources/NeoToolboxCore/Storage/InMemoryStateStore.swift`
- Test: `Tests/NeoToolboxCoreTests/MultiSourceTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `MultiSourceTests`:

```swift
    func testCalendarSourcePersistenceRoundTrip() throws {
        let store = InMemoryStateStore()
        let source = CalendarSource(kind: .tencent, username: "Cal_x", feishuCalendarID: "c9", isEnabled: true, resolvedCollectionURL: "https://h/col/")
        try store.saveCalendarSource(source)
        let loaded = try store.loadCalendarSources()
        XCTAssertEqual(loaded, [source])
        try store.deleteCalendarSource(id: "tencent")
        XCTAssertTrue(try store.loadCalendarSources().isEmpty)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MultiSourceTests`
Expected: FAIL — methods undefined.

- [ ] **Step 3: Write minimal implementation**

In `StateStore.swift` protocol, add:

```swift
    func saveCalendarSource(_ source: CalendarSource) throws
    func loadCalendarSources() throws -> [CalendarSource]
    func deleteCalendarSource(id: String) throws
```

In `SQLiteStateStore.swift`, add the table to `migrate()` (after `tool_settings`):

```swift
        try execute(sql: """
        CREATE TABLE IF NOT EXISTS calendar_sources (
            source_id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            username TEXT NOT NULL,
            feishu_calendar_id TEXT NOT NULL,
            is_enabled INTEGER NOT NULL,
            resolved_collection_url TEXT
        )
        """)
```

And the CRUD methods (mirror the style of `saveToolSettings`/`loadToolSettings` in the same file — use the existing `execute(sql:bind:)` and `query(sql:map:bind:)` helpers):

```swift
    public func saveCalendarSource(_ source: CalendarSource) throws {
        try execute(sql: """
        INSERT INTO calendar_sources (source_id, kind, username, feishu_calendar_id, is_enabled, resolved_collection_url)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(source_id) DO UPDATE SET
            kind = excluded.kind,
            username = excluded.username,
            feishu_calendar_id = excluded.feishu_calendar_id,
            is_enabled = excluded.is_enabled,
            resolved_collection_url = excluded.resolved_collection_url
        """) { statement in
            bind(statement, source.id, 1)
            bind(statement, source.kind.rawValue, 2)
            bind(statement, source.username, 3)
            bind(statement, source.feishuCalendarID, 4)
            bind(statement, source.isEnabled ? 1 : 0, 5)
            if let url = source.resolvedCollectionURL { bind(statement, url, 6) } else { bindNull(statement, 6) }
        }
    }

    public func loadCalendarSources() throws -> [CalendarSource] {
        try query(sql: "SELECT * FROM calendar_sources ORDER BY source_id") { statement in
            CalendarSource(
                kind: CalendarSourceKind(rawValue: string(statement, 1)) ?? .dingtalk,
                username: string(statement, 2),
                feishuCalendarID: string(statement, 3),
                isEnabled: int(statement, 4) == 1,
                resolvedCollectionURL: optionalString(statement, 5)
            )
        } bind: { _ in }
    }

    public func deleteCalendarSource(id: String) throws {
        try execute(sql: "DELETE FROM calendar_sources WHERE source_id = ?") { statement in
            bind(statement, id, 1)
        }
    }
```

> NOTE: Confirm the exact helper names in `SQLiteStateStore.swift` — this file already uses `string(statement,_)`, `optionalString(statement,_)`, `int(...)` or similar, plus `bind(...)` and likely a null-bind. Open the file and reuse the real helper names (e.g. there may be `bind(statement, Int(...), n)` for integers and a null variant). Mirror `saveToolSettings`/`loadToolSettings` precisely. Column indices are 0-based per the existing accessors — adjust to match how other loaders index (the existing `loadToolSettings` shows the convention).

In `InMemoryStateStore.swift`, add storage + methods:

```swift
    private var sources: [String: CalendarSource] = [:]

    public func saveCalendarSource(_ source: CalendarSource) throws {
        lock.lock(); defer { lock.unlock() }
        sources[source.id] = source
    }

    public func loadCalendarSources() throws -> [CalendarSource] {
        lock.lock(); defer { lock.unlock() }
        return sources.values.sorted { $0.id < $1.id }
    }

    public func deleteCalendarSource(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        sources.removeValue(forKey: id)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MultiSourceTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/NeoToolboxCore/Storage Tests/NeoToolboxCoreTests/MultiSourceTests.swift
git commit -m "feat: persist calendar sources"
```

---

### Task 5: CalDAV discovery

**Files:**
- Create: `Sources/NeoToolboxCore/DingTalk/CalDAVDiscovery.swift`
- Test: `Tests/NeoToolboxCoreTests/CalDAVDiscoveryTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/NeoToolboxCoreTests/CalDAVDiscoveryTests.swift`:

```swift
import XCTest
@testable import NeoToolboxCore

private final class StubTransport: CalDAVTransporting, @unchecked Sendable {
    var responses: [String: (Int, String)]   // path -> (status surrogate via body), simplified
    var bodies: [Data]
    private var index = 0
    let scripted: [(String) -> (Int, String)?]
    init(_ handler: @escaping (String) -> (Int, String)?) {
        self.responses = [:]; self.bodies = []; self.scripted = [handler]
    }
    func send(_ request: URLRequest) async throws -> Data {
        let path = request.url?.path ?? ""
        if let (_, body) = scripted[0](path) {
            return body.data(using: .utf8)!
        }
        return Data()
    }
}

final class CalDAVDiscoveryTests: XCTestCase {
    func testDiscoversCollectionThroughChain() async throws {
        let principalXML = """
        <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:response><d:href>/caldav</d:href><d:propstat><d:prop>\
        <d:current-user-principal><d:href>/caldav/me/</d:href></d:current-user-principal>\
        <c:calendar-home-set><d:href>/caldav/me/calendar</d:href></c:calendar-home-set>\
        </d:prop></d:propstat></d:response></d:multistatus>
        """
        let homeXML = """
        <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">\
        <d:response><d:href>/caldav/me/calendar/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>\
        <d:response><d:href>/caldav/me/calendar/abc123/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/><c:calendar/></d:resourcetype><d:displayname>Meetings</d:displayname></d:prop></d:propstat></d:response>\
        </d:multistatus>
        """
        let transport = StubTransport { path in
            if path.contains("/calendar") && path.hasSuffix("calendar") { return (207, homeXML) }
            return (207, principalXML)
        }
        let discovery = CalDAVDiscovery(transport: transport)
        let url = try await discovery.discoverCalendarCollection(
            host: "cal.meeting.tencent.com", username: "Cal_x@cal.meeting.tencent.com", password: "p"
        )
        XCTAssertTrue(url.absoluteString.hasSuffix("/caldav/me/calendar/abc123/"), url.absoluteString)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CalDAVDiscoveryTests`
Expected: FAIL — `CalDAVDiscovery` undefined.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/NeoToolboxCore/DingTalk/CalDAVDiscovery.swift`:

```swift
import Foundation

/// Walks the standard CalDAV discovery chain: PROPFIND the well-known root for
/// the principal + calendar-home-set, then PROPFIND the home (Depth 1) for the
/// first calendar collection.
public struct CalDAVDiscovery: Sendable {
    private let transport: any CalDAVTransporting

    public init(transport: any CalDAVTransporting) {
        self.transport = transport
    }

    public func discoverCalendarCollection(host: String, username: String, password: String) async throws -> URL {
        let homeHref = try await propfindHome(host: host, username: username, password: password)
        let homeURL = absolute(host: host, path: homeHref)
        let collectionHref = try await propfindFirstCalendar(url: homeURL, username: username, password: password)
        return absolute(host: host, path: collectionHref)
    }

    private func propfindHome(host: String, username: String, password: String) async throws -> String {
        let body = """
        <?xml version="1.0"?><d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">\
        <d:prop><d:current-user-principal/><c:calendar-home-set/></d:prop></d:propfind>
        """
        let data = try await send(method: "PROPFIND", url: absolute(host: host, path: "/caldav/"), depth: "0", username: username, password: password, body: body)
        let xml = String(data: data, encoding: .utf8) ?? ""
        if let home = firstHref(in: xml, after: "calendar-home-set") { return home }
        if let principal = firstHref(in: xml, after: "current-user-principal") { return principal }
        throw CalDAVDiscoveryError.noCalendarHome
    }

    private func propfindFirstCalendar(url: URL, username: String, password: String) async throws -> String {
        let body = """
        <?xml version="1.0"?><d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">\
        <d:prop><d:resourcetype/><d:displayname/></d:prop></d:propfind>
        """
        let data = try await send(method: "PROPFIND", url: url, depth: "1", username: username, password: password, body: body)
        let xml = String(data: data, encoding: .utf8) ?? ""
        guard let href = firstCalendarHref(in: xml) else { throw CalDAVDiscoveryError.noCalendarCollection }
        return href
    }

    private func send(method: String, url: URL, depth: String, username: String, password: String, body: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(depth, forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let raw = "\(username):\(password)"
        request.setValue("Basic \(Data(raw.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        request.httpBody = body.data(using: .utf8)
        return try await transport.send(request)
    }

    private func absolute(host: String, path: String) -> URL {
        if path.hasPrefix("http") { return URL(string: path)! }
        return URL(string: "https://\(host)\(path)")!
    }

    /// First `<href>` that appears after the given tag name.
    private func firstHref(in xml: String, after tag: String) -> String? {
        guard let tagRange = xml.range(of: tag) else { return nil }
        let rest = xml[tagRange.upperBound...]
        return firstHref(in: String(rest))
    }

    private func firstHref(in xml: String) -> String? {
        guard let open = xml.range(of: "href>", options: .caseInsensitive) else { return nil }
        let rest = xml[open.upperBound...]
        guard let close = rest.range(of: "<") else { return nil }
        return String(rest[..<close.lowerBound])
    }

    /// First `<response>` whose resourcetype contains `<calendar/>`.
    private func firstCalendarHref(in xml: String) -> String? {
        let lowered = xml
        var searchStart = lowered.startIndex
        while let respOpen = lowered.range(of: "response>", range: searchStart..<lowered.endIndex) {
            guard let respClose = lowered.range(of: "response>", range: respOpen.upperBound..<lowered.endIndex) else { break }
            let segment = String(lowered[respOpen.upperBound..<respClose.lowerBound])
            if segment.lowercased().contains("calendar"), segment.lowercased().contains("href") {
                // require a calendar resourcetype, not just the home collection
                if segment.lowercased().contains(":calendar/") || segment.lowercased().contains("<calendar") {
                    if let href = firstHref(in: segment) { return href }
                }
            }
            searchStart = respClose.upperBound
        }
        return nil
    }
}

public enum CalDAVDiscoveryError: Error, Equatable {
    case noCalendarHome
    case noCalendarCollection
}
```

> NOTE: The XML parsing here is deliberately lightweight (string scanning), matching the existing `DingTalkCalDAVClient.extractCalendarData` approach rather than introducing an XML parser. The test fixture exercises the real chain shape. If the host returns namespaced tags like `D:href`, the `firstHref` search on `href>` still matches because it looks for the suffix `href>`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CalDAVDiscoveryTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/NeoToolboxCore/DingTalk/CalDAVDiscovery.swift Tests/NeoToolboxCoreTests/CalDAVDiscoveryTests.swift
git commit -m "feat: add CalDAV collection discovery"
```

---

### Task 6: Generalized CalDAVCalendarClient + factory

**Files:**
- Create: `Sources/NeoToolboxCore/DingTalk/CalDAVCalendarClient.swift`
- Modify: `Sources/NeoToolboxCore/DingTalk/DingTalkCalDAVClient.swift` (delegate to it)
- Test: `Tests/NeoToolboxCoreTests/MultiSourceTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `MultiSourceTests` (reuse the `FakeCalDAVTransport` recording helper from `DingTalkCalDAVClientTests`; if it is `private`, add a small local recording transport here):

```swift
    func testFixedPathClientTargetsPrimaryCollection() async throws {
        let transport = RecordingTransport(responseBody: emptyMultiStatus)
        let client = CalDAVCalendarClient(
            host: "calendar.dingtalk.com",
            strategy: .fixedPath("/dav/{user}/primary/"),
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let settings = CalendarSyncSettings(
            toolID: "calendar-sync", isEnabled: true, syncIntervalSeconds: 900, syncWindowDays: 30,
            dingTalkUsername: "ding-user", feishuCalendarID: "c", deleteSyncEnabled: true
        )
        _ = try await client.fetchEvents(settings: settings, password: "secret")
        XCTAssertEqual(transport.lastURL?.absoluteString, "https://calendar.dingtalk.com/dav/ding-user/primary/")
        XCTAssertEqual(transport.lastMethod, "REPORT")
    }
```

Add helpers at file scope in `MultiSourceTests.swift`:

```swift
final class RecordingTransport: CalDAVTransporting, @unchecked Sendable {
    let responseBody: String
    var lastURL: URL?
    var lastMethod: String?
    init(responseBody: String) { self.responseBody = responseBody }
    func send(_ request: URLRequest) async throws -> Data {
        lastURL = request.url; lastMethod = request.httpMethod
        return responseBody.data(using: .utf8)!
    }
}

let emptyMultiStatus = """
<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"></d:multistatus>
"""
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MultiSourceTests`
Expected: FAIL — `CalDAVCalendarClient` undefined.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/NeoToolboxCore/DingTalk/CalDAVCalendarClient.swift`:

```swift
import Foundation

public struct CalDAVCalendarClient: DingTalkEventFetching {
    public enum CollectionStrategy: Sendable {
        /// A path template containing `{user}`, e.g. "/dav/{user}/primary/".
        case fixedPath(String)
        /// Discover the collection via the CalDAV well-known chain.
        case discover
    }

    private let host: String
    private let strategy: CollectionStrategy
    private let transport: any CalDAVTransporting
    private let parser: ICalendarParser
    private let now: @Sendable () -> Date

    public init(
        host: String,
        strategy: CollectionStrategy,
        transport: any CalDAVTransporting = URLSessionCalDAVTransport(),
        parser: ICalendarParser = ICalendarParser(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.host = host
        self.strategy = strategy
        self.transport = transport
        self.parser = parser
        self.now = now
    }

    public func fetchEvents(settings: CalendarSyncSettings, password: String) async throws -> [NormalizedEvent] {
        let url = try await resolveCollectionURL(username: settings.dingTalkUsername, password: password)
        var request = URLRequest(url: url)
        request.httpMethod = "REPORT"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(authorization(username: settings.dingTalkUsername, password: password), forHTTPHeaderField: "Authorization")
        request.httpBody = reportBody(settings: settings).data(using: .utf8)

        let data = try await transport.send(request)
        let body = String(data: data, encoding: .utf8) ?? ""
        return try extractCalendarData(from: body).flatMap { try parser.parse($0) }
    }

    /// Resolves the collection URL. The result is also returned so callers can
    /// cache it (see CalendarSyncService).
    public func resolveCollectionURL(username: String, password: String) async throws -> URL {
        switch strategy {
        case let .fixedPath(template):
            let path = template.replacingOccurrences(of: "{user}", with: username)
            return URL(string: "https://\(host)\(path)")!
        case .discover:
            return try await CalDAVDiscovery(transport: transport)
                .discoverCalendarCollection(host: host, username: username, password: password)
        }
    }

    private func authorization(username: String, password: String) -> String {
        let raw = "\(username):\(password)"
        return "Basic \(Data(raw.utf8).base64EncodedString())"
    }

    private func reportBody(settings: CalendarSyncSettings) -> String {
        let start = now().addingTimeInterval(-86_400)
        let end = now().addingTimeInterval(TimeInterval(settings.syncWindowDays) * 86_400)
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:prop><d:getetag /><c:calendar-data /></d:prop>
          <c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT">
            <c:time-range start="\(caldavTimestamp(start))" end="\(caldavTimestamp(end))" />
          </c:comp-filter></c:comp-filter></c:filter>
        </c:calendar-query>
        """
    }

    private func caldavTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    private func extractCalendarData(from body: String) -> [String] {
        // Reuse the same extraction + entity decode as the original client.
        CalDAVCalendarDataExtractor.extract(from: body)
    }
}

public enum CalDAVClientFactory {
    public static func make(
        kind: CalendarSourceKind,
        transport: any CalDAVTransporting = URLSessionCalDAVTransport(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> CalDAVCalendarClient {
        switch kind {
        case .dingtalk:
            return CalDAVCalendarClient(host: kind.host, strategy: .fixedPath("/dav/{user}/primary/"), transport: transport, now: now)
        case .tencent:
            return CalDAVCalendarClient(host: kind.host, strategy: .discover, transport: transport, now: now)
        }
    }
}
```

Extract the existing parse helpers from `DingTalkCalDAVClient.swift` into a shared `CalDAVCalendarDataExtractor` enum (move `extractCalendarData` + `decodeXML` there, make them `static`), then have BOTH `DingTalkCalDAVClient` and `CalDAVCalendarClient` call it. Add to a new small file or the bottom of `CalDAVCalendarClient.swift`:

```swift
enum CalDAVCalendarDataExtractor {
    static func extract(from body: String) -> [String] {
        // Move the body of DingTalkCalDAVClient.extractCalendarData here verbatim,
        // calling the static decodeXML below.
        // ... (copy existing regex/scan logic) ...
    }

    static func decodeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&#13;", with: "\r")
            .replacingOccurrences(of: "&#10;", with: "\n")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
```

> NOTE: Open `DingTalkCalDAVClient.swift`, cut the `extractCalendarData(from:)` and `decodeXML(_:)` bodies, and paste them into `CalDAVCalendarDataExtractor` as `static` functions (rename internal calls accordingly). Then make `DingTalkCalDAVClient.fetchEvents` delegate to a `CalDAVCalendarClient` with `.fixedPath("/dav/{user}/primary/")` so its existing tests keep passing, OR leave `DingTalkCalDAVClient` calling `CalDAVCalendarDataExtractor.extract`. Pick whichever keeps `DingTalkCalDAVClientTests` green with the least change. The simplest: keep `DingTalkCalDAVClient` as-is but have it call `CalDAVCalendarDataExtractor.extract`/`.decodeXML` instead of private copies.

- [ ] **Step 4: Run tests**

Run: `swift test --filter MultiSourceTests`
Expected: PASS.

Run: `swift test --filter DingTalkCalDAVClientTests`
Expected: PASS (unchanged behavior).

- [ ] **Step 5: Commit**

```bash
git add Sources/NeoToolboxCore/DingTalk Tests/NeoToolboxCoreTests/MultiSourceTests.swift
git commit -m "feat: add generalized CalDAV client and factory"
```

---

### Task 7: ConnectionTestResult per source

**Files:**
- Modify: `Sources/NeoToolboxCore/CalendarSync/ConnectionTestResult.swift`
- Test: `Tests/NeoToolboxCoreTests/MultiSourceTests.swift`

- [ ] **Step 1: Write the failing test**

Append:

```swift
    func testSourceTestResultEquality() {
        let a = SourceTestResult(caldav: .ok, feishu: .failed("x"))
        XCTAssertEqual(a, SourceTestResult(caldav: .ok, feishu: .failed("x")))
        XCTAssertNotEqual(a, SourceTestResult(caldav: .failed("y"), feishu: .ok))
    }
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --filter MultiSourceTests`
Expected: FAIL — `SourceTestResult` undefined.

- [ ] **Step 3: Implement**

Add to `ConnectionTestResult.swift` (keep the existing `ConnectionTestResult` for now; add the per-source type reusing `ConnectionTestResult.Side`):

```swift
public struct SourceTestResult: Equatable, Sendable {
    public var caldav: ConnectionTestResult.Side
    public var feishu: ConnectionTestResult.Side

    public init(caldav: ConnectionTestResult.Side, feishu: ConnectionTestResult.Side) {
        self.caldav = caldav
        self.feishu = feishu
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter MultiSourceTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/NeoToolboxCore/CalendarSync/ConnectionTestResult.swift Tests/NeoToolboxCoreTests/MultiSourceTests.swift
git commit -m "feat: add per-source connection test result"
```

---

### Task 8: Service — load configuration + migration

**Files:**
- Modify: `Sources/NeoToolboxCore/CalendarSync/CalendarSyncService.swift`
- Test: `Tests/NeoToolboxCoreTests/MultiSourceTests.swift`

This task replaces the single-source state in the service with `configuration: CalendarSyncConfiguration` plus per-source test results, and migrates a legacy `tool_settings` row.

- [ ] **Step 1: Write the failing test (@MainActor)**

Append a new `@MainActor` class:

```swift
@MainActor
final class MultiSourceServiceTests: XCTestCase {
    func testLoadMigratesLegacyDingTalkSettings() throws {
        let store = InMemoryStateStore()
        // legacy single-source row, no calendar_sources rows
        try store.saveToolSettings(CalendarSyncSettings(
            toolID: "calendar-sync", isEnabled: true, syncIntervalSeconds: 600, syncWindowDays: 7,
            dingTalkUsername: "alice", feishuCalendarID: "cal-1", deleteSyncEnabled: true
        ).asStoredToolSettings(lastSuccessfulSyncAt: nil, consecutiveFailureCount: 0))

        let service = CalendarSyncService(stateStore: store, credentialStore: MemoryCredentialStore())
        service.loadSettings()

        let ding = service.configuration.source(for: .dingtalk)
        XCTAssertEqual(ding?.username, "alice")
        XCTAssertEqual(ding?.feishuCalendarID, "cal-1")
        XCTAssertEqual(service.configuration.syncIntervalSeconds, 600)
        // migration persisted a source row
        XCTAssertEqual(try store.loadCalendarSources().count, 1)
    }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --filter MultiSourceServiceTests`
Expected: FAIL — `configuration` undefined.

- [ ] **Step 3: Implement**

In `CalendarSyncService`, add published state:

```swift
    @Published public private(set) var configuration: CalendarSyncConfiguration
    @Published public private(set) var sourceTestResults: [CalendarSourceKind: SourceTestResult] = [:]
```

Initialize `configuration = CalendarSyncConfiguration()` in `init` (add an initializer parameter `configuration: CalendarSyncConfiguration = CalendarSyncConfiguration()` and assign).

Rewrite `loadSettings()` to load global settings + sources, with migration:

```swift
    public func loadSettings() {
        do {
            let stored = try stateStore.loadToolSettings(toolID: CalendarSyncSettings.defaultToolID)
            var sources = try stateStore.loadCalendarSources()

            // Migrate a legacy single-source row into a dingtalk source once.
            if sources.isEmpty, let stored, !stored.dingTalkUsername.isEmpty {
                let migrated = CalendarSource(
                    kind: .dingtalk,
                    username: stored.dingTalkUsername,
                    feishuCalendarID: stored.feishuCalendarID,
                    isEnabled: stored.isEnabled
                )
                try stateStore.saveCalendarSource(migrated)
                sources = [migrated]
            }

            configuration = CalendarSyncConfiguration(
                sources: sources,
                syncIntervalSeconds: stored?.syncIntervalSeconds ?? 1800,
                syncWindowDays: stored?.syncWindowDays ?? 30
            )
            refreshHasStoredPasswords()
            rebuildRunners()
            recomputeSetupSteps()
            if hasEnabledConfiguredSource {
                startTimer(intervalSeconds: configuration.syncIntervalSeconds)
            }
        } catch {
            recentLogs.insert(RuntimeLog(timestamp: Date(), level: .error, message: "Failed to load settings: \(error)"), at: 0)
        }
    }

    private var hasEnabledConfiguredSource: Bool {
        configuration.sources.contains { $0.isEnabled && $0.isConfigured && hasStoredPassword(for: $0) }
    }
```

Add helpers used above (full bodies in Task 9/10). For this task, add stubs so it compiles:

```swift
    private var storedPasswordAccounts: Set<String> = []

    private func refreshHasStoredPasswords() {
        storedPasswordAccounts = []
        for source in configuration.sources {
            if let pw = try? credentialStore.readPassword(account: source.credentialAccount()), pw?.isEmpty == false {
                storedPasswordAccounts.insert(source.credentialAccount())
            }
        }
    }

    func hasStoredPassword(for source: CalendarSource) -> Bool {
        storedPasswordAccounts.contains(source.credentialAccount())
    }

    private func rebuildRunners() { /* Task 11 */ }
```

> NOTE: keep the existing single-source `settings`/`saveSettings`/`testConnection`/`rebuildRunner` for now to avoid breaking existing tests in `CalendarSyncConfigTests`. They can be removed in Task 12 once the UI and multi-source paths replace them. If a name clashes (`recomputeSetupSteps`), keep one implementation and update it in Task 9.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter MultiSourceServiceTests`
Expected: PASS.

Run: `swift test --filter CalendarSyncServiceConfigTests`
Expected: PASS (existing single-source tests unaffected).

- [ ] **Step 5: Commit**

```bash
git add Sources/NeoToolboxCore/CalendarSync/CalendarSyncService.swift Tests/NeoToolboxCoreTests/MultiSourceTests.swift
git commit -m "feat: load multi-source configuration with legacy migration"
```

---

### Task 9: Service — save a source

**Files:**
- Modify: `Sources/NeoToolboxCore/CalendarSync/CalendarSyncService.swift`
- Test: `Tests/NeoToolboxCoreTests/MultiSourceTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `MultiSourceServiceTests`:

```swift
    func testSaveSourcePersistsRowAndPassword() throws {
        let store = InMemoryStateStore()
        let creds = MemoryCredentialStore()
        let service = CalendarSyncService(stateStore: store, credentialStore: creds)
        service.loadSettings()

        let source = CalendarSource(kind: .tencent, username: "Cal_x", feishuCalendarID: "c9", isEnabled: true)
        try service.saveSource(source, password: "pw", intervalSeconds: 1800, windowDays: 30)

        XCTAssertEqual(try store.loadCalendarSources().first(where: { $0.id == "tencent" })?.username, "Cal_x")
        XCTAssertEqual(try creds.readPassword(account: "tencent:Cal_x"), "pw")
        XCTAssertTrue(service.hasStoredPassword(for: source))
        XCTAssertEqual(service.configuration.source(for: .tencent)?.feishuCalendarID, "c9")
    }
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --filter MultiSourceServiceTests`
Expected: FAIL — `saveSource` undefined.

- [ ] **Step 3: Implement**

Add to `CalendarSyncService`:

```swift
    public func saveSource(_ source: CalendarSource, password: String?, intervalSeconds: Int, windowDays: Int) throws {
        if let password, !password.isEmpty {
            try credentialStore.savePassword(password, account: source.credentialAccount())
        }
        try stateStore.saveCalendarSource(source)

        // Persist global interval/window on the tool_settings row.
        let prior = (try? stateStore.loadToolSettings(toolID: CalendarSyncSettings.defaultToolID)) ?? nil
        let globalRow = CalendarSyncSettings(
            toolID: CalendarSyncSettings.defaultToolID,
            isEnabled: true,
            syncIntervalSeconds: intervalSeconds,
            syncWindowDays: windowDays,
            dingTalkUsername: prior?.dingTalkUsername ?? "",
            feishuCalendarID: prior?.feishuCalendarID ?? "",
            deleteSyncEnabled: true
        ).asStoredToolSettings(
            lastSuccessfulSyncAt: prior?.lastSuccessfulSyncAt,
            consecutiveFailureCount: prior?.consecutiveFailureCount ?? 0
        )
        try stateStore.saveToolSettings(globalRow)

        var sources = configuration.sources.filter { $0.kind != source.kind }
        sources.append(source)
        sources.sort { $0.id < $1.id }
        configuration = CalendarSyncConfiguration(sources: sources, syncIntervalSeconds: intervalSeconds, syncWindowDays: windowDays)

        refreshHasStoredPasswords()
        rebuildRunners()
        recomputeSetupSteps()
        if hasEnabledConfiguredSource {
            startTimer(intervalSeconds: intervalSeconds)
        } else {
            stopTimer()
        }
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter MultiSourceServiceTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/NeoToolboxCore/CalendarSync/CalendarSyncService.swift Tests/NeoToolboxCoreTests/MultiSourceTests.swift
git commit -m "feat: save a calendar source through the service"
```

---

### Task 10: Service — test a source

**Files:**
- Modify: `Sources/NeoToolboxCore/CalendarSync/CalendarSyncService.swift`
- Test: `Tests/NeoToolboxCoreTests/MultiSourceTests.swift`

The service needs a per-source CalDAV fetcher. Add an injectable factory closure so tests can substitute a fake.

- [ ] **Step 1: Write the failing test**

Append:

```swift
    func testTestSourceReportsCalDAVAndFeishu() async {
        let store = InMemoryStateStore()
        let service = CalendarSyncService(
            stateStore: store,
            credentialStore: MemoryCredentialStore(),
            feishuProvider: FakeFeishuProvider(calendars: [FeishuCalendar(id: "c1", summary: "Work")]),
            caldavFetcherForKind: { _ in ConfigFakeDingTalkFetcher() }
        )
        service.loadSettings()
        let source = CalendarSource(kind: .tencent, username: "u", feishuCalendarID: "c1", isEnabled: true)
        let result = await service.testSource(source, password: "p")
        XCTAssertTrue(result.caldav.isOK)
        XCTAssertTrue(result.feishu.isOK)
        XCTAssertEqual(service.sourceTestResults[.tencent], result)
    }
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --filter MultiSourceServiceTests`
Expected: FAIL — `caldavFetcherForKind` / `testSource` undefined.

- [ ] **Step 3: Implement**

Add an injected factory to `CalendarSyncService` init:

```swift
    private let caldavFetcherForKind: @Sendable (CalendarSourceKind) -> any DingTalkEventFetching
```

Add the init parameter (defaulted to the real factory):

```swift
        caldavFetcherForKind: @escaping @Sendable (CalendarSourceKind) -> any DingTalkEventFetching = { CalDAVClientFactory.make(kind: $0) },
```

assign `self.caldavFetcherForKind = caldavFetcherForKind`.

Add:

```swift
    @discardableResult
    public func testSource(_ source: CalendarSource, password: String?) async -> SourceTestResult {
        let feishuSide = await testFeishuSide()
        let caldavSide = await testCalDAVSide(source, password: password)
        let result = SourceTestResult(caldav: caldavSide, feishu: feishuSide)
        sourceTestResults[source.kind] = result
        recomputeSetupSteps()
        return result
    }

    private func testCalDAVSide(_ source: CalendarSource, password: String?) async -> ConnectionTestResult.Side {
        let pw: String
        if let password, !password.isEmpty {
            pw = password
        } else {
            pw = ((try? credentialStore.readPassword(account: source.credentialAccount())) ?? nil) ?? ""
        }
        let settings = configuration.settings(for: source)
        do {
            _ = try await caldavFetcherForKind(source.kind).fetchEvents(settings: settings, password: pw)
            return .ok
        } catch {
            return .failed(String(describing: error))
        }
    }
```

> NOTE: `testFeishuSide()` already exists from the single-source implementation; reuse it. If it was made `private`, keep it. It populates `availableCalendars` too.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter MultiSourceServiceTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/NeoToolboxCore/CalendarSync/CalendarSyncService.swift Tests/NeoToolboxCoreTests/MultiSourceTests.swift
git commit -m "feat: test a calendar source connection"
```

---

### Task 11: Service — per-source runners + sync

**Files:**
- Modify: `Sources/NeoToolboxCore/CalendarSync/CalendarSyncService.swift`
- Test: `Tests/NeoToolboxCoreTests/MultiSourceTests.swift`

- [ ] **Step 1: Write the failing test**

Append:

```swift
    func testSyncRunsEnabledSourcesAndAggregates() async throws {
        let store = InMemoryStateStore()
        let creds = MemoryCredentialStore()
        try creds.savePassword("p", account: "dingtalk:alice")
        try creds.savePassword("p", account: "tencent:Cal_x")
        let service = CalendarSyncService(
            stateStore: store,
            credentialStore: creds,
            feishuWriter: RecordingFeishuWriter(),
            caldavFetcherForKind: { _ in ConfigFakeDingTalkFetcher() }
        )
        try store.saveCalendarSource(CalendarSource(kind: .dingtalk, username: "alice", feishuCalendarID: "c1", isEnabled: true))
        try store.saveCalendarSource(CalendarSource(kind: .tencent, username: "Cal_x", feishuCalendarID: "c2", isEnabled: false))
        service.loadSettings()

        await service.triggerSync(.manual)
        // dingtalk enabled (no events from fake -> zero ops but a report); tencent disabled -> skipped
        XCTAssertEqual(service.status.state, .idle)
    }
```

> NOTE: This is a smoke-level assertion (no crash, ends idle). `ConfigFakeDingTalkFetcher` returns `[]`, so the run produces an empty report. The point is that enabling/disabling sources routes correctly and `triggerSync` aggregates without error.

- [ ] **Step 2: Run to verify fail**

Run: `swift test --filter MultiSourceServiceTests`
Expected: FAIL — `feishuWriter` param / multi-source `triggerSync` not wired.

- [ ] **Step 3: Implement**

Add a `feishuWriter` init parameter to the service (defaulted to `UnavailableFeishuClient()`), store it. Implement `rebuildRunners()` to build one `SyncEngine` per enabled+configured source, keyed by kind, and make `triggerSync` iterate them.

```swift
    private var runnersByKind: [CalendarSourceKind: any CalendarSyncRunning] = [:]

    private func rebuildRunners() {
        runnersByKind = [:]
        for source in configuration.sources where source.isEnabled && source.isConfigured && hasStoredPassword(for: source) {
            let engine = SyncEngine(
                settings: configuration.settings(for: source),
                eventFetcher: caldavFetcherForKind(source.kind),
                feishuWriter: feishuWriter,
                stateStore: CalendarSyncStateStoreAdapter(store: stateStore),
                credentialStore: PerSourceCredentialStore(base: credentialStore, account: source.credentialAccount(), engineKey: source.username),
                sourceTag: source.kind.mappingTag
            )
            runnersByKind[source.kind] = engine
        }
    }

    public func triggerSync(_ trigger: SyncTrigger) async {
        guard !isRunning else { return }
        isRunning = true
        status = CalendarSyncStatus(state: .running, lastSyncAt: status.lastSyncAt)
        defer { isRunning = false }

        var anyFailure = false
        var lastReport: SyncReport?
        for (_, runner) in runnersByKind {
            do {
                let report = try await runner.run(trigger: trigger)
                lastReport = report
                appendLogs(for: report)
            } catch {
                anyFailure = true
                recentLogs.insert(RuntimeLog(timestamp: Date(), level: .error, message: String(describing: error)), at: 0)
            }
        }
        if let lastReport { self.lastReport = lastReport }
        status = CalendarSyncStatus(state: anyFailure ? .failed("One or more sources failed") : .idle, lastSyncAt: Date())
        consecutiveFailureCount = anyFailure ? consecutiveFailureCount + 1 : 0
        recomputeSetupSteps()
    }
```

Add a tiny credential adapter so the engine reads the per-source password by `settings.dingTalkUsername`:

```swift
    private struct PerSourceCredentialStore: CredentialStoring {
        let base: any CredentialStoring
        let account: String
        let engineKey: String
        func savePassword(_ password: String, account: String) throws { try base.savePassword(password, account: self.account) }
        func readPassword(account: String) throws -> String? { try base.readPassword(account: self.account) }
        func deletePassword(account: String) throws { try base.deletePassword(account: self.account) }
    }
```

> NOTE: `appendLogs(for:)` — reuse the existing log-appending used by the old single-source `triggerSync`/`syncNow`. If the old `triggerSync` is still present, rename the old one or remove it (Task 12). For now, keep `syncNow()` delegating to the new `triggerSync(.manual)`. Remove the old single-source `triggerSync` body to avoid two definitions — replace it with the new one above. Update `CalendarSyncServiceTests` (which calls `triggerSync(.manual)` with a `FakeSyncRunner`) in the next note.

> NOTE: `CalendarSyncServiceTests` constructs `CalendarSyncService(syncRunner: runner)` and calls `triggerSync(.manual)` expecting the single runner to run. To keep those tests meaningful, have `rebuildRunners()` ALSO honor an injected `syncRunner` (the legacy single runner) by registering it under a synthetic key when `runnersByKind` is empty, OR update those tests to the new source-based flow. Prefer: keep `syncRunner` support — if `runnersByKind` is empty and a legacy `syncRunner` exists, run it. Add that fallback in `triggerSync`.

Add `RecordingFeishuWriter` test helper at file scope in `MultiSourceTests.swift`:

```swift
final class RecordingFeishuWriter: FeishuCalendarWriting, @unchecked Sendable {
    func createEvent(_ event: NormalizedEvent, calendarID: String) async throws -> String { "evt" }
    func updateEvent(_ mapping: EventMapping, with event: NormalizedEvent) async throws {}
    func deleteEvent(_ mapping: EventMapping) async throws {}
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter MultiSourceServiceTests`
Expected: PASS.

Run: `swift test --filter CalendarSyncServiceTests`
Expected: PASS (legacy single-runner fallback preserved).

- [ ] **Step 5: Commit**

```bash
git add Sources/NeoToolboxCore/CalendarSync/CalendarSyncService.swift Tests/NeoToolboxCoreTests/MultiSourceTests.swift
git commit -m "feat: run sync per enabled source and aggregate"
```

---

### Task 12: setupSteps from sources + cleanup

**Files:**
- Modify: `Sources/NeoToolboxCore/CalendarSync/CalendarSyncService.swift`
- Test: existing suites

- [ ] **Step 1: Update `recomputeSetupSteps()`**

Generalize completeness to the multi-source config:

```swift
    private func recomputeSetupSteps() {
        let anySourceReady = configuration.sources.contains { $0.isConfigured && hasStoredPassword(for: $0) }
        let feishuCliReady = dependencyCheck.status == .available
        let calendarReady = configuration.sources.contains { !$0.feishuCalendarID.isEmpty }
        let rulesReady = configuration.syncIntervalSeconds > 0 && configuration.syncWindowDays > 0
        let trialReady = lastReport != nil

        setupSteps = CalendarSyncSetupStep.defaultSteps.map { step in
            var copy = step
            switch step.id {
            case "feishu-cli": copy.isComplete = feishuCliReady
            case "dingtalk-caldav": copy.isComplete = anySourceReady
            case "feishu-calendar": copy.isComplete = calendarReady
            case "sync-rules": copy.isComplete = rulesReady
            case "trial-run": copy.isComplete = trialReady
            default: break
            }
            return copy
        }
    }
```

- [ ] **Step 2: Build + full test run**

Run: `swift build`
Expected: Build complete.

Run: `swift test`
Expected: All pass. Fix any remaining references to the removed single-source `settings`/`saveSettings`/`testConnection` if they were deleted; if still present (kept for back-compat), leave them. Keep `CalendarSyncConfigTests` green — if a method was removed, update or delete the specific test.

> NOTE: Decide explicitly: KEEP the legacy single-source `settings`, `saveSettings`, `testConnection`, `loadFeishuCalendars`, `hasStoredPassword`, `live(databasePath:)`. They do not conflict with the multi-source additions and several tests rely on them. `live(databasePath:)` must now ALSO build with the new `feishuWriter` + `caldavFetcherForKind` defaults — verify it still compiles (it uses defaulted params, so it does), and call `loadSettings()` (now multi-source aware) at the end.

- [ ] **Step 3: Commit**

```bash
git add Sources/NeoToolboxCore/CalendarSync/CalendarSyncService.swift
git commit -m "feat: derive setup steps from multi-source configuration"
```

---

### Task 13: SettingsView — per-source sections

**Files:**
- Modify: `Sources/NeoToolboxApp/Dashboard/Settings/SettingsView.swift`

This is a SwiftUI view; verify via build.

- [ ] **Step 1: Rewrite `SettingsView` with a section per source**

Replace the file with a version that renders a `SourceSectionView` for `.dingtalk` and `.tencent`, plus a global rules section and Save. Full file:

```swift
import NeoToolboxCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var service: CalendarSyncService

    @State private var intervalSeconds = 1800
    @State private var windowDays = 30
    @State private var drafts: [CalendarSourceKind: SourceDraft] = [:]
    @State private var saveError: String?
    @State private var isBusy = false

    var body: some View {
        Form {
            ForEach(CalendarSourceKind.allCases, id: \.self) { kind in
                sourceSection(for: kind)
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
            }

            Section {
                Button("Load Feishu calendars") {
                    Task { isBusy = true; await service.loadFeishuCalendars(); isBusy = false }
                }
                .disabled(isBusy)
                if let saveError {
                    Text(saveError).foregroundStyle(.red).font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(maxWidth: 680, alignment: .leading)
        .onAppear(perform: loadFromService)
    }

    @ViewBuilder
    private func sourceSection(for kind: CalendarSourceKind) -> some View {
        let binding = draftBinding(for: kind)
        Section(kind.displayName) {
            TextField("CalDAV username", text: binding.username)
            SecureField(passwordPlaceholder(for: kind), text: binding.password)
            Picker("Target calendar", selection: binding.feishuCalendarID) {
                Text("Not selected").tag("")
                ForEach(service.availableCalendars, id: \.id) { cal in
                    Text(cal.summary).tag(cal.id)
                }
            }
            Toggle("Enabled", isOn: binding.isEnabled)
            HStack {
                Button("Test \(kind.displayName)") {
                    Task { await testSource(kind) }
                }
                .disabled(isBusy)
                if let r = service.sourceTestResults[kind] {
                    resultBadge("CalDAV", r.caldav)
                    resultBadge("Feishu", r.feishu)
                }
            }
            Button("Save \(kind.displayName)") { saveSource(kind) }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Draft handling

    private func loadFromService() {
        intervalSeconds = [600, 1800, 3600].contains(service.configuration.syncIntervalSeconds) ? service.configuration.syncIntervalSeconds : 1800
        windowDays = [7, 30, 90].contains(service.configuration.syncWindowDays) ? service.configuration.syncWindowDays : 30
        for kind in CalendarSourceKind.allCases {
            let s = service.configuration.source(for: kind)
            drafts[kind] = SourceDraft(
                username: s?.username ?? "",
                password: "",
                feishuCalendarID: s?.feishuCalendarID ?? "",
                isEnabled: s?.isEnabled ?? false
            )
        }
    }

    private func draftBinding(for kind: CalendarSourceKind) -> SourceDraftBinding {
        SourceDraftBinding(
            username: Binding(get: { drafts[kind]?.username ?? "" }, set: { drafts[kind, default: .empty].username = $0 }),
            password: Binding(get: { drafts[kind]?.password ?? "" }, set: { drafts[kind, default: .empty].password = $0 }),
            feishuCalendarID: Binding(get: { drafts[kind]?.feishuCalendarID ?? "" }, set: { drafts[kind, default: .empty].feishuCalendarID = $0 }),
            isEnabled: Binding(get: { drafts[kind]?.isEnabled ?? false }, set: { drafts[kind, default: .empty].isEnabled = $0 })
        )
    }

    private func source(for kind: CalendarSourceKind) -> CalendarSource {
        let d = drafts[kind] ?? .empty
        return CalendarSource(kind: kind, username: d.username, feishuCalendarID: d.feishuCalendarID, isEnabled: d.isEnabled)
    }

    private func passwordPlaceholder(for kind: CalendarSourceKind) -> String {
        let s = service.configuration.source(for: kind)
        if let s, service.hasStoredPassword(for: s) { return "•••••••• (saved)" }
        return "CalDAV password"
    }

    private func testSource(_ kind: CalendarSourceKind) async {
        isBusy = true
        let pw = drafts[kind]?.password
        await service.testSource(source(for: kind), password: pw?.isEmpty == true ? nil : pw)
        isBusy = false
    }

    private func saveSource(_ kind: CalendarSourceKind) {
        saveError = nil
        let pw = drafts[kind]?.password
        do {
            try service.saveSource(source(for: kind), password: (pw?.isEmpty == true) ? nil : pw, intervalSeconds: intervalSeconds, windowDays: windowDays)
            drafts[kind]?.password = ""
        } catch {
            saveError = String(describing: error)
        }
    }

    @ViewBuilder
    private func resultBadge(_ label: String, _ side: ConnectionTestResult.Side) -> some View {
        HStack(spacing: 3) {
            Image(systemName: side.isOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(side.isOK ? .green : .red)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct SourceDraft {
    var username: String
    var password: String
    var feishuCalendarID: String
    var isEnabled: Bool
    static let empty = SourceDraft(username: "", password: "", feishuCalendarID: "", isEnabled: false)
}

private struct SourceDraftBinding {
    var username: Binding<String>
    var password: Binding<String>
    var feishuCalendarID: Binding<String>
    var isEnabled: Binding<Bool>
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: Build complete.

- [ ] **Step 3: Commit**

```bash
git add Sources/NeoToolboxApp/Dashboard/Settings/SettingsView.swift
git commit -m "feat: per-source settings sections for DingTalk and Tencent"
```

---

### Task 14: Full verification + live test

**Files:** none (verification)

- [ ] **Step 1: Build**

Run: `swift build`
Expected: Build complete.

- [ ] **Step 2: Full test suite**

Run: `swift test`
Expected: All tests pass.

- [ ] **Step 3: Package + manual smoke**

Run: `./Scripts/package-app.sh` then `open dist/NeoToolbox.app`
Open dashboard → Settings → confirm DingTalk and Tencent Meeting sections render with username/password/target/enable/Test/Save, plus global Sync rules and Load Feishu calendars.

- [ ] **Step 4: Live verification (manual, user-driven)**

Enter Tencent credentials (host `cal.meeting.tencent.com`), Test → expect CalDAV green; Load Feishu calendars, pick a target; enable; Save; Sync Now; confirm Tencent meetings appear in the chosen Feishu calendar and DingTalk still syncs to its own.

- [ ] **Step 5: Commit (if any verification fixups were needed)**

```bash
git add -A
git commit -m "test: verify multi-source sync end to end"
```

---

## Self-Review

**Spec coverage:**
- Source model + per-source target calendar → Task 1 (`CalendarSource`, `CalendarSyncConfiguration.settings(for:)`).
- `calendar_sources` persistence + migration → Tasks 4, 8.
- CalDAV generalization (fixed vs discover) + Tencent dynamic collection → Tasks 5, 6.
- Per-source isolation (no cross-source deletes) → Tasks 2, 3 (`loadEventMappings(calendarID:source:)`, engine `sourceTag`).
- Multi-source orchestration (run per enabled source, aggregate) → Task 11.
- Per-source UI + Test → Tasks 7, 10, 13.
- setupSteps generalization → Task 12.
- Live verification → Task 14.

**Placeholder scan:** Code steps contain concrete code. Several `NOTE` blocks flag real-codebase verification points (SQLite helper names, moving `extractCalendarData` into a shared extractor, keeping legacy single-source methods, updating `SyncEngineTests`/`CalendarSyncServiceTests` fakes to the new `loadActiveMappings(calendarID:source:)` signature). Each NOTE gives the exact change to make. These are integration seams, not undefined behavior.

**Type consistency:** `CalendarSourceKind.mappingTag` (Task 1) used as `sourceTag` (Tasks 3, 11). `loadEventMappings(calendarID:source:)` defined Task 2, used Tasks 2/3. `CalendarSource.credentialAccount()` (Task 1) used Tasks 9/10/11. `SourceTestResult` (Task 7) used Tasks 10/13. `configuration.settings(for:)` (Task 1) used Tasks 10/11. `caldavFetcherForKind` (Task 10) used Tasks 10/11. `feishuWriter` service field (Task 11) used Task 11.

**Known risks called out for the implementer:**
- SQLite helper names/index convention (Task 4 NOTE) — mirror existing `saveToolSettings`/`loadToolSettings`.
- Moving `extractCalendarData`/`decodeXML` into `CalDAVCalendarDataExtractor` without breaking `DingTalkCalDAVClientTests` (Task 6 NOTE).
- Keeping legacy single-source service methods so `CalendarSyncConfigTests` stays green (Tasks 8, 12 NOTEs).
- Updating `SyncEngineTests`/`CalendarSyncServiceTests` fakes for the new mapping-load signature and the per-source runner fallback (Tasks 3, 11 NOTEs).
