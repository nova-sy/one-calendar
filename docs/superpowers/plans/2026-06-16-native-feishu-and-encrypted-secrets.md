# Native Feishu + Encrypted Secret Store Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Replace `lark-cli` with a native Feishu OAuth + Calendar API client, and move business secrets (CalDAV passwords, Feishu AK/SK, tokens) from the Keychain into the local SQLite DB, encrypted at rest.

**Architecture:** A Keychain-held AES-GCM master key encrypts secret values stored in a new `secrets` table (`EncryptedSecretStore` implements the existing `CredentialStoring`). `FeishuOAuth` runs the documented authorization-code grant with a loopback redirect; `FeishuTokenManager` owns token lifecycle; `FeishuAPIClient` implements the existing `FeishuCalendarProviding`/`FeishuCalendarWriting` over HTTPS. Protocols are unchanged so SyncEngine and multi-source orchestration are untouched.

**Tech Stack:** Swift 6.2, CryptoKit, SwiftPM, SwiftUI (macOS 14+), XCTest, SQLite.

---

## Verified facts

- `CredentialStoring`: `savePassword(_:account:)`, `readPassword(account:) -> String?`, `deletePassword(account:)`. `MemoryCredentialStore` exists.
- `StateStoring` protocol + `SQLiteStateStore`/`InMemoryStateStore` (helper funcs `string/optionalString/int/bool`, `bind` overloads incl. `String?`, `query(sql:map:bind:)`, `execute(sql:bind:)`, `migrate()`).
- `CalendarSyncService.live(databasePath:)` builds `SQLiteStateStore`, `KeychainCredentialStore`, `FeishuCLIClient` (provider+writer), `DingTalkCalDAVClient`, then `loadSettings()`.
- `CalendarSyncService` init defaults: `feishuProvider/feishuWriter = UnavailableFeishuClient()`, `credentialStore = MemoryCredentialStore()`.
- `DependencyCheck { status: .available/.missing, executablePath: String?, message: String }`.
- `FeishuCalendar { id, summary }`; `NormalizedEvent { uid, title, start, end, ... }`; `EventMapping { feishuCalendarID, feishuEventID, source, ... }`.
- Feishu v2 OAuth token endpoint: `POST https://open.feishu.cn/open-apis/authen/v2/oauth/token`. Authorize: `https://accounts.feishu.cn/open-apis/authen/v1/authorize`. Calendar API base: `https://open.feishu.cn/open-apis/calendar/v4`.
- SQLite has no BLOB bind helper yet — Task 1 adds one.

## File structure

New (Core): `Security/MasterKeyProvider.swift`, `Security/EncryptedSecretStore.swift`, `Feishu/FeishuHTTP.swift`, `Feishu/FeishuOAuth.swift`, `Feishu/FeishuTokenManager.swift`, `Feishu/FeishuAPIClient.swift`.
New (tests): `EncryptedSecretStoreTests.swift`, `FeishuOAuthTests.swift`, `FeishuAPIClientTests.swift`.
Modified: `Storage/StateStore.swift`, `Storage/SQLiteStateStore.swift`, `Storage/InMemoryStateStore.swift`, `CalendarSync/CalendarSyncService.swift`, `App/Dashboard/Settings/SettingsView.swift`, `App/DashboardWindowController.swift`.
Removed: `Feishu/FeishuCLIClient.swift`, `Feishu/CommandRunner.swift`, `Tests/.../FeishuCLIClientTests.swift`, the `extension FeishuCLIClient: FeishuCalendarProviding` in `FeishuCalendarProviding.swift`.

---

### Task 1: secrets table + BLOB persistence

**Files:** `Storage/StateStore.swift`, `Storage/SQLiteStateStore.swift`, `Storage/InMemoryStateStore.swift`, test `EncryptedSecretStoreTests.swift`.

- [ ] **Step 1: failing test**

Create `Tests/NeoToolboxCoreTests/EncryptedSecretStoreTests.swift`:

```swift
import XCTest
@testable import NeoToolboxCore

final class SecretTableTests: XCTestCase {
    func testInMemorySecretRoundTrip() throws {
        let store = InMemoryStateStore()
        try store.saveSecret(account: "a", ciphertext: Data([1,2,3]), nonce: Data([9]))
        let got = try store.loadSecret(account: "a")
        XCTAssertEqual(got?.ciphertext, Data([1,2,3]))
        XCTAssertEqual(got?.nonce, Data([9]))
        try store.deleteSecret(account: "a")
        XCTAssertNil(try store.loadSecret(account: "a"))
    }

    func testSQLiteSecretRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SQLiteStateStore(path: dir.appendingPathComponent("s.sqlite3").path)
        try store.saveSecret(account: "b", ciphertext: Data([4,5]), nonce: Data([7,8]))
        XCTAssertEqual(try store.loadSecret(account: "b")?.ciphertext, Data([4,5]))
    }
}
```

- [ ] **Step 2: run, expect fail** — `swift test --filter SecretTableTests` → undefined `saveSecret`.

- [ ] **Step 3: implement**

In `StateStore.swift` add to the protocol:

```swift
    func saveSecret(account: String, ciphertext: Data, nonce: Data) throws
    func loadSecret(account: String) throws -> (ciphertext: Data, nonce: Data)?
    func deleteSecret(account: String) throws
```

In `SQLiteStateStore.swift` `migrate()` add:

```swift
        try execute(sql: """
        CREATE TABLE IF NOT EXISTS secrets (
            account TEXT PRIMARY KEY,
            ciphertext BLOB NOT NULL,
            nonce BLOB NOT NULL
        )
        """)
```

Add a BLOB bind helper near the other `bind` funcs:

```swift
private func bindBlob(_ statement: OpaquePointer?, _ value: Data, _ index: Int32) {
    value.withUnsafeBytes { raw in
        sqlite3_bind_blob(statement, index, raw.baseAddress, Int32(value.count), SQLITE_TRANSIENT)
    }
}

private func blob(_ statement: OpaquePointer?, _ index: Int32) -> Data {
    guard let bytes = sqlite3_column_blob(statement, index) else { return Data() }
    let count = Int(sqlite3_column_bytes(statement, index))
    return Data(bytes: bytes, count: count)
}
```

> NOTE: `SQLITE_TRANSIENT` may need declaring: `let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)` at file scope if not already present. Check the top of `SQLiteStateStore.swift`.

Add the CRUD methods:

```swift
    public func saveSecret(account: String, ciphertext: Data, nonce: Data) throws {
        try execute(sql: "INSERT INTO secrets (account, ciphertext, nonce) VALUES (?, ?, ?) ON CONFLICT(account) DO UPDATE SET ciphertext = excluded.ciphertext, nonce = excluded.nonce") { statement in
            bind(statement, account, 1)
            bindBlob(statement, ciphertext, 2)
            bindBlob(statement, nonce, 3)
        }
    }

    public func loadSecret(account: String) throws -> (ciphertext: Data, nonce: Data)? {
        try query(sql: "SELECT ciphertext, nonce FROM secrets WHERE account = ?") { statement in
            (blob(statement, 0), blob(statement, 1))
        } bind: { statement in
            bind(statement, account, 1)
        }.first
    }

    public func deleteSecret(account: String) throws {
        try execute(sql: "DELETE FROM secrets WHERE account = ?") { statement in
            bind(statement, account, 1)
        }
    }
```

In `InMemoryStateStore.swift`:

```swift
    private var secrets: [String: (ciphertext: Data, nonce: Data)] = [:]

    public func saveSecret(account: String, ciphertext: Data, nonce: Data) throws {
        lock.lock(); defer { lock.unlock() }
        secrets[account] = (ciphertext, nonce)
    }
    public func loadSecret(account: String) throws -> (ciphertext: Data, nonce: Data)? {
        lock.lock(); defer { lock.unlock() }
        return secrets[account]
    }
    public func deleteSecret(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        secrets.removeValue(forKey: account)
    }
```

- [ ] **Step 4: run** — `swift test --filter SecretTableTests` → PASS.
- [ ] **Step 5: commit** — `git commit -m "feat: add encrypted secrets table"`.

---

### Task 2: master key provider

**Files:** `Security/MasterKeyProvider.swift`, test in `EncryptedSecretStoreTests.swift`.

- [ ] **Step 1: failing test**

Append:

```swift
import CryptoKit

final class MasterKeyTests: XCTestCase {
    func testInMemoryMasterKeyStable() throws {
        let p = InMemoryMasterKeyProvider()
        let k1 = try p.masterKey()
        let k2 = try p.masterKey()
        XCTAssertEqual(k1.withUnsafeBytes { Data($0) }, k2.withUnsafeBytes { Data($0) })
    }
}
```

- [ ] **Step 2: fail** — undefined.

- [ ] **Step 3: implement** `Security/MasterKeyProvider.swift`:

```swift
import CryptoKit
import Foundation

public protocol MasterKeyProviding: Sendable {
    func masterKey() throws -> SymmetricKey
}

public enum MasterKeyError: Error { case unavailable }

/// In-memory provider for tests; generates one stable key per instance.
public final class InMemoryMasterKeyProvider: MasterKeyProviding, @unchecked Sendable {
    private let key: SymmetricKey
    public init(key: SymmetricKey = SymmetricKey(size: .bits256)) { self.key = key }
    public func masterKey() throws -> SymmetricKey { key }
}

/// Stores a 256-bit key in the login Keychain under a fixed account.
public struct KeychainMasterKeyProvider: MasterKeyProviding {
    private let service = "com.nova-sy.neotoolbox"
    private let account = "neo-toolbox.master-key"
    public init() {}

    public func masterKey() throws -> SymmetricKey {
        if let data = try read() { return SymmetricKey(data: data) }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try write(data)
        return key
    }

    private func read() throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw MasterKeyError.unavailable }
        return data
    }

    private func write(_ data: Data) throws {
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        SecItemDelete(attrs as CFDictionary)
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw MasterKeyError.unavailable }
    }
}
```

- [ ] **Step 4: pass.** **Step 5: commit** `feat: add master key provider`.

---

### Task 3: EncryptedSecretStore

**Files:** `Security/EncryptedSecretStore.swift`, test.

- [ ] **Step 1: failing test**

```swift
final class EncryptedSecretStoreTests: XCTestCase {
    func testEncryptRoundTrip() throws {
        let store = InMemoryStateStore()
        let key = InMemoryMasterKeyProvider()
        let secrets = EncryptedSecretStore(store: store, masterKey: key)
        try secrets.savePassword("hunter2", account: "dingtalk:alice")
        XCTAssertEqual(try secrets.readPassword(account: "dingtalk:alice"), "hunter2")
        // ciphertext on disk is not the plaintext
        let raw = try store.loadSecret(account: "dingtalk:alice")
        XCTAssertNotNil(raw)
        XCTAssertFalse(String(data: raw!.ciphertext, encoding: .utf8) == "hunter2")
        try secrets.deletePassword(account: "dingtalk:alice")
        XCTAssertNil(try secrets.readPassword(account: "dingtalk:alice"))
    }

    func testWrongKeyFailsToDecrypt() throws {
        let store = InMemoryStateStore()
        try EncryptedSecretStore(store: store, masterKey: InMemoryMasterKeyProvider()).savePassword("x", account: "a")
        let other = EncryptedSecretStore(store: store, masterKey: InMemoryMasterKeyProvider())
        XCTAssertThrowsError(try other.readPassword(account: "a"))
    }
}
```

- [ ] **Step 2: fail.**

- [ ] **Step 3: implement** `Security/EncryptedSecretStore.swift`:

```swift
import CryptoKit
import Foundation

public enum SecretStoreError: Error { case decryptionFailed }

public final class EncryptedSecretStore: CredentialStoring, @unchecked Sendable {
    private let store: any StateStoring
    private let masterKey: any MasterKeyProviding

    public init(store: any StateStoring, masterKey: any MasterKeyProviding) {
        self.store = store
        self.masterKey = masterKey
    }

    public func savePassword(_ password: String, account: String) throws {
        let key = try masterKey.masterKey()
        let sealed = try AES.GCM.seal(Data(password.utf8), using: key)
        // store combined ciphertext+tag, and nonce separately
        try store.saveSecret(account: account, ciphertext: sealed.ciphertext + sealed.tag, nonce: Data(sealed.nonce))
    }

    public func readPassword(account: String) throws -> String? {
        guard let row = try store.loadSecret(account: account) else { return nil }
        let key = try masterKey.masterKey()
        guard row.ciphertext.count > 16 else { throw SecretStoreError.decryptionFailed }
        let tag = row.ciphertext.suffix(16)
        let cipher = row.ciphertext.prefix(row.ciphertext.count - 16)
        do {
            let nonce = try AES.GCM.Nonce(data: row.nonce)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: cipher, tag: tag)
            let plain = try AES.GCM.open(box, using: key)
            return String(data: plain, encoding: .utf8)
        } catch {
            throw SecretStoreError.decryptionFailed
        }
    }

    public func deletePassword(account: String) throws {
        try store.deleteSecret(account: account)
    }
}
```

- [ ] **Step 4: pass.** **Step 5: commit** `feat: add encrypted secret store`.

---

### Task 4: Feishu HTTP seam

**Files:** `Feishu/FeishuHTTP.swift`.

- [ ] **Step 1:** implement (no test; exercised via clients):

```swift
import Foundation

public struct FeishuHTTPResponse: Sendable {
    public var status: Int
    public var body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
}

public protocol FeishuHTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> FeishuHTTPResponse
}

public struct URLSessionFeishuHTTPClient: FeishuHTTPClient {
    public init() {}
    public func send(_ request: URLRequest) async throws -> FeishuHTTPResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return FeishuHTTPResponse(status: status, body: data)
    }
}
```

- [ ] **Step 2: build** `swift build`. **Step 3: commit** `feat: add Feishu HTTP seam`.

---

### Task 5: FeishuOAuth (token exchange + refresh)

**Files:** `Feishu/FeishuOAuth.swift`, `Feishu/FeishuTokenManager.swift` (types), test `FeishuOAuthTests.swift`.

Loopback capture is integration-only; unit tests cover URL building, token exchange, and refresh parsing.

- [ ] **Step 1: failing test** `FeishuOAuthTests.swift`:

```swift
import XCTest
@testable import NeoToolboxCore

private final class FakeHTTP: FeishuHTTPClient, @unchecked Sendable {
    var response: FeishuHTTPResponse
    var lastRequest: URLRequest?
    init(_ response: FeishuHTTPResponse) { self.response = response }
    func send(_ request: URLRequest) async throws -> FeishuHTTPResponse { lastRequest = request; return response }
}

final class FeishuOAuthTests: XCTestCase {
    func testAuthorizeURLContainsParams() {
        let oauth = FeishuOAuth(http: FakeHTTP(.init(status: 200, body: Data())), now: { Date(timeIntervalSince1970: 0) })
        let url = oauth.authorizeURL(appID: "cli_x", redirectURI: "http://127.0.0.1:17865/callback", state: "st", scopes: ["calendar:calendar", "offline_access"])
        let s = url.absoluteString
        XCTAssertTrue(s.contains("client_id=cli_x"))
        XCTAssertTrue(s.contains("response_type=code"))
        XCTAssertTrue(s.contains("state=st"))
        XCTAssertTrue(s.contains("offline_access"))
    }

    func testExchangeParsesTokens() async throws {
        let json = #"{"code":0,"access_token":"at","expires_in":7200,"refresh_token":"rt","refresh_token_expires_in":604800}"#
        let http = FakeHTTP(.init(status: 200, body: Data(json.utf8)))
        let oauth = FeishuOAuth(http: http, now: { Date(timeIntervalSince1970: 1000) })
        let bundle = try await oauth.exchange(appID: "id", appSecret: "sec", code: "c", redirectURI: "r")
        XCTAssertEqual(bundle.accessToken, "at")
        XCTAssertEqual(bundle.refreshToken, "rt")
        XCTAssertEqual(bundle.accessTokenExpiry, Date(timeIntervalSince1970: 1000 + 7200))
    }

    func testRefreshParsesTokens() async throws {
        let json = #"{"code":0,"access_token":"at2","expires_in":7200,"refresh_token":"rt2","refresh_token_expires_in":604800}"#
        let oauth = FeishuOAuth(http: FakeHTTP(.init(status: 200, body: Data(json.utf8))), now: { Date(timeIntervalSince1970: 0) })
        let bundle = try await oauth.refresh(appID: "id", appSecret: "sec", refreshToken: "rt")
        XCTAssertEqual(bundle.accessToken, "at2")
        XCTAssertEqual(bundle.refreshToken, "rt2")
    }

    func testErrorEnvelopeThrows() async {
        let json = #"{"code":20001,"msg":"bad code"}"#
        let oauth = FeishuOAuth(http: FakeHTTP(.init(status: 400, body: Data(json.utf8))), now: { Date(timeIntervalSince1970: 0) })
        do { _ = try await oauth.exchange(appID: "id", appSecret: "s", code: "c", redirectURI: "r"); XCTFail() }
        catch {}
    }
}
```

- [ ] **Step 2: fail.**

- [ ] **Step 3: implement** `Feishu/FeishuTokenManager.swift` (token bundle type only here):

```swift
import Foundation

public struct FeishuTokenBundle: Equatable, Sendable, Codable {
    public var accessToken: String
    public var accessTokenExpiry: Date
    public var refreshToken: String
    public var refreshTokenExpiry: Date
    public init(accessToken: String, accessTokenExpiry: Date, refreshToken: String, refreshTokenExpiry: Date) {
        self.accessToken = accessToken
        self.accessTokenExpiry = accessTokenExpiry
        self.refreshToken = refreshToken
        self.refreshTokenExpiry = refreshTokenExpiry
    }
}

public enum FeishuAuthError: Error, Equatable {
    case server(String)
    case needsReauthorization
    case notConfigured
}
```

`Feishu/FeishuOAuth.swift`:

```swift
import Foundation

public struct FeishuOAuth: Sendable {
    private let http: any FeishuHTTPClient
    private let now: @Sendable () -> Date
    private let authorizeBase = "https://accounts.feishu.cn/open-apis/authen/v1/authorize"
    private let tokenURL = "https://open.feishu.cn/open-apis/authen/v2/oauth/token"

    public init(http: any FeishuHTTPClient = URLSessionFeishuHTTPClient(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.http = http
        self.now = now
    }

    public func authorizeURL(appID: String, redirectURI: String, state: String, scopes: [String]) -> URL {
        var comps = URLComponents(string: authorizeBase)!
        comps.queryItems = [
            .init(name: "client_id", value: appID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "state", value: state)
        ]
        return comps.url!
    }

    public func exchange(appID: String, appSecret: String, code: String, redirectURI: String) async throws -> FeishuTokenBundle {
        try await token(body: [
            "grant_type": "authorization_code",
            "client_id": appID, "client_secret": appSecret,
            "code": code, "redirect_uri": redirectURI
        ])
    }

    public func refresh(appID: String, appSecret: String, refreshToken: String) async throws -> FeishuTokenBundle {
        try await token(body: [
            "grant_type": "refresh_token",
            "client_id": appID, "client_secret": appSecret,
            "refresh_token": refreshToken
        ])
    }

    private func token(body: [String: String]) async throws -> FeishuTokenBundle {
        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let response = try await http.send(request)
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: response.body)
        if let code = decoded.code, code != 0 {
            throw FeishuAuthError.server(decoded.msg ?? "oauth error \(code)")
        }
        guard let at = decoded.access_token, let rt = decoded.refresh_token else {
            throw FeishuAuthError.server(decoded.msg ?? "missing tokens")
        }
        let t = now()
        return FeishuTokenBundle(
            accessToken: at,
            accessTokenExpiry: t.addingTimeInterval(TimeInterval(decoded.expires_in ?? 7200)),
            refreshToken: rt,
            refreshTokenExpiry: t.addingTimeInterval(TimeInterval(decoded.refresh_token_expires_in ?? 604800))
        )
    }

    private struct TokenResponse: Decodable {
        var code: Int?
        var msg: String?
        var access_token: String?
        var expires_in: Int?
        var refresh_token: String?
        var refresh_token_expires_in: Int?
    }
}
```

- [ ] **Step 4: pass.** **Step 5: commit** `feat: add Feishu OAuth token exchange and refresh`.

---

### Task 6: FeishuTokenManager

**Files:** `Feishu/FeishuTokenManager.swift` (append), test in `FeishuOAuthTests.swift`.

Owns: read/write the token bundle (JSON, encrypted via `CredentialStoring` under account `feishu:tokens`), AK/SK (accounts `feishu:app_id`, `feishu:app_secret`), and a `validAccessToken()` that refreshes when near expiry.

- [ ] **Step 1: failing test**

```swift
final class FeishuTokenManagerTests: XCTestCase {
    func testReturnsTokenWhenFresh() async throws {
        let creds = MemoryCredentialStore()
        let mgr = FeishuTokenManager(credentials: creds, oauth: FeishuOAuth(http: FakeHTTP(.init(status:200, body: Data())), now: { Date(timeIntervalSince1970: 0) }), now: { Date(timeIntervalSince1970: 0) })
        try mgr.saveAppCredentials(appID: "id", appSecret: "sec")
        try mgr.storeTokens(FeishuTokenBundle(accessToken: "at", accessTokenExpiry: Date(timeIntervalSince1970: 10000), refreshToken: "rt", refreshTokenExpiry: Date(timeIntervalSince1970: 999999)))
        let token = try await mgr.validAccessToken()
        XCTAssertEqual(token, "at")
    }

    func testRefreshesWhenExpired() async throws {
        let creds = MemoryCredentialStore()
        let json = #"{"code":0,"access_token":"fresh","expires_in":7200,"refresh_token":"rt2","refresh_token_expires_in":604800}"#
        let oauth = FeishuOAuth(http: FakeHTTP(.init(status:200, body: Data(json.utf8))), now: { Date(timeIntervalSince1970: 5000) })
        let mgr = FeishuTokenManager(credentials: creds, oauth: oauth, now: { Date(timeIntervalSince1970: 5000) })
        try mgr.saveAppCredentials(appID: "id", appSecret: "sec")
        try mgr.storeTokens(FeishuTokenBundle(accessToken: "old", accessTokenExpiry: Date(timeIntervalSince1970: 100), refreshToken: "rt", refreshTokenExpiry: Date(timeIntervalSince1970: 999999)))
        let token = try await mgr.validAccessToken()
        XCTAssertEqual(token, "fresh")
    }

    func testThrowsWhenRefreshExpired() async throws {
        let creds = MemoryCredentialStore()
        let mgr = FeishuTokenManager(credentials: creds, oauth: FeishuOAuth(http: FakeHTTP(.init(status:200, body: Data())), now: { Date(timeIntervalSince1970: 999999999) }), now: { Date(timeIntervalSince1970: 999999999) })
        try mgr.saveAppCredentials(appID: "id", appSecret: "sec")
        try mgr.storeTokens(FeishuTokenBundle(accessToken: "old", accessTokenExpiry: Date(timeIntervalSince1970: 100), refreshToken: "rt", refreshTokenExpiry: Date(timeIntervalSince1970: 200)))
        do { _ = try await mgr.validAccessToken(); XCTFail() } catch { XCTAssertEqual(error as? FeishuAuthError, .needsReauthorization) }
    }
}
```

- [ ] **Step 2: fail.**

- [ ] **Step 3: implement** (append to `FeishuTokenManager.swift`):

```swift
public final class FeishuTokenManager: @unchecked Sendable {
    private let credentials: any CredentialStoring
    private let oauth: FeishuOAuth
    private let now: @Sendable () -> Date
    private let refreshSkew: TimeInterval = 120

    private let appIDAccount = "feishu:app_id"
    private let appSecretAccount = "feishu:app_secret"
    private let tokensAccount = "feishu:tokens"

    public init(credentials: any CredentialStoring, oauth: FeishuOAuth = FeishuOAuth(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.credentials = credentials
        self.oauth = oauth
        self.now = now
    }

    public func saveAppCredentials(appID: String, appSecret: String) throws {
        try credentials.savePassword(appID, account: appIDAccount)
        if !appSecret.isEmpty { try credentials.savePassword(appSecret, account: appSecretAccount) }
    }

    public func appID() -> String? { (try? credentials.readPassword(account: appIDAccount)) ?? nil }
    public func hasAppCredentials() -> Bool { appID()?.isEmpty == false && ((try? credentials.readPassword(account: appSecretAccount)) ?? nil)?.isEmpty == false }
    public func isAuthorized() -> Bool { (try? loadTokens()) != nil }

    public func storeTokens(_ bundle: FeishuTokenBundle) throws {
        let data = try JSONEncoder().encode(bundle)
        try credentials.savePassword(String(data: data, encoding: .utf8)!, account: tokensAccount)
    }

    public func loadTokens() throws -> FeishuTokenBundle? {
        guard let s = (try credentials.readPassword(account: tokensAccount)), let data = s.data(using: .utf8) else { return nil }
        return try JSONDecoder().decode(FeishuTokenBundle.self, from: data)
    }

    public func clearTokens() throws { try credentials.deletePassword(account: tokensAccount) }

    public func validAccessToken() async throws -> String {
        guard let id = appID(), let secret = (try credentials.readPassword(account: appSecretAccount)), !id.isEmpty, !secret.isEmpty else {
            throw FeishuAuthError.notConfigured
        }
        guard let tokens = try loadTokens() else { throw FeishuAuthError.needsReauthorization }
        if now() < tokens.accessTokenExpiry.addingTimeInterval(-refreshSkew) {
            return tokens.accessToken
        }
        if now() >= tokens.refreshTokenExpiry {
            throw FeishuAuthError.needsReauthorization
        }
        let refreshed = try await oauth.refresh(appID: id, appSecret: secret, refreshToken: tokens.refreshToken)
        try storeTokens(refreshed)
        return refreshed.accessToken
    }
}
```

- [ ] **Step 4: pass.** **Step 5: commit** `feat: add Feishu token manager`.

---

### Task 7: FeishuAPIClient

**Files:** `Feishu/FeishuAPIClient.swift`, test `FeishuAPIClientTests.swift`.

- [ ] **Step 1: failing test**

```swift
import XCTest
@testable import NeoToolboxCore

private final class SeqHTTP: FeishuHTTPClient, @unchecked Sendable {
    var responses: [FeishuHTTPResponse]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [FeishuHTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> FeishuHTTPResponse {
        requests.append(request)
        return responses.isEmpty ? .init(status: 200, body: Data()) : responses.removeFirst()
    }
}

final class FeishuAPIClientTests: XCTestCase {
    private func manager(_ http: FeishuHTTPClient) throws -> FeishuTokenManager {
        let creds = MemoryCredentialStore()
        let m = FeishuTokenManager(credentials: creds, oauth: FeishuOAuth(http: http, now: { Date(timeIntervalSince1970: 0) }), now: { Date(timeIntervalSince1970: 0) })
        try m.saveAppCredentials(appID: "id", appSecret: "sec")
        try m.storeTokens(FeishuTokenBundle(accessToken: "at", accessTokenExpiry: Date(timeIntervalSince1970: 99999), refreshToken: "rt", refreshTokenExpiry: Date(timeIntervalSince1970: 999999)))
        return m
    }

    func testListCalendars() async throws {
        let body = #"{"code":0,"data":{"calendar_list":[{"calendar_id":"c1","summary":"Work"}]}}"#
        let http = SeqHTTP([.init(status: 200, body: Data(body.utf8))])
        let client = FeishuAPIClient(http: http, tokens: try manager(http))
        let cals = try await client.listCalendars()
        XCTAssertEqual(cals.map(\.id), ["c1"])
        XCTAssertEqual(http.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer at")
    }

    func testCreateEventReturnsID() async throws {
        let body = #"{"code":0,"data":{"event":{"event_id":"e9"}}}"#
        let http = SeqHTTP([.init(status: 200, body: Data(body.utf8))])
        let client = FeishuAPIClient(http: http, tokens: try manager(http))
        let event = NormalizedEvent(uid: "u", recurrenceID: nil, title: "T", start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200), isAllDay: false, location: nil, notes: nil)
        let id = try await client.createEvent(event, calendarID: "c1")
        XCTAssertEqual(id, "e9")
    }
}
```

- [ ] **Step 2: fail.**

- [ ] **Step 3: implement** `Feishu/FeishuAPIClient.swift`:

```swift
import Foundation

public struct FeishuAPIClient: FeishuCalendarProviding, FeishuCalendarWriting {
    private let http: any FeishuHTTPClient
    private let tokens: FeishuTokenManager
    private let base = "https://open.feishu.cn/open-apis/calendar/v4"

    public init(http: any FeishuHTTPClient = URLSessionFeishuHTTPClient(), tokens: FeishuTokenManager) {
        self.http = http
        self.tokens = tokens
    }

    public func checkDependency() async -> DependencyCheck {
        guard tokens.hasAppCredentials() else {
            return DependencyCheck(status: .missing, executablePath: nil, message: "Enter Feishu App ID and Secret in Settings")
        }
        guard tokens.isAuthorized() else {
            return DependencyCheck(status: .missing, executablePath: nil, message: "Authorize Feishu in Settings")
        }
        return DependencyCheck(status: .available, executablePath: nil, message: "Feishu authorized")
    }

    public func listCalendars() async throws -> [FeishuCalendar] {
        let data = try await call(method: "GET", path: "/calendars", body: nil)
        let env = try JSONDecoder().decode(Envelope<CalendarList>.self, from: data)
        try env.throwIfError()
        return (env.data?.calendar_list ?? []).map { FeishuCalendar(id: $0.calendar_id, summary: $0.summary) }
    }

    public func createEvent(_ event: NormalizedEvent, calendarID: String) async throws -> String {
        let body = try eventBody(event)
        let data = try await call(method: "POST", path: "/calendars/\(calendarID)/events", body: body)
        let env = try JSONDecoder().decode(Envelope<CreatedEvent>.self, from: data)
        try env.throwIfError()
        guard let id = env.data?.event.event_id else { throw FeishuAuthError.server("missing event_id") }
        return id
    }

    public func updateEvent(_ mapping: EventMapping, with event: NormalizedEvent) async throws {
        let body = try eventBody(event)
        let data = try await call(method: "PATCH", path: "/calendars/\(mapping.feishuCalendarID)/events/\(mapping.feishuEventID)", body: body)
        try JSONDecoder().decode(Envelope<Empty>.self, from: data).throwIfError()
    }

    public func deleteEvent(_ mapping: EventMapping) async throws {
        let data = try await call(method: "DELETE", path: "/calendars/\(mapping.feishuCalendarID)/events/\(mapping.feishuEventID)", body: nil)
        try JSONDecoder().decode(Envelope<Empty>.self, from: data).throwIfError()
    }

    private func eventBody(_ event: NormalizedEvent) throws -> Data {
        let payload: [String: Any] = [
            "summary": event.title,
            "start_time": ["timestamp": String(Int(event.start.timeIntervalSince1970))],
            "end_time": ["timestamp": String(Int(event.end.timeIntervalSince1970))]
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func call(method: String, path: String, body: Data?) async throws -> Data {
        func once(_ token: String) async throws -> FeishuHTTPResponse {
            var request = URLRequest(url: URL(string: base + path)!)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            return try await http.send(request)
        }
        var token = try await tokens.validAccessToken()
        var response = try await once(token)
        if response.status == 401 {
            try tokens.clearAccessOnly()
            token = try await tokens.validAccessToken()
            response = try await once(token)
        }
        return response.body
    }

    private struct Envelope<T: Decodable>: Decodable {
        var code: Int?
        var msg: String?
        var data: T?
        func throwIfError() throws {
            if let code, code != 0 { throw FeishuAuthError.server(msg ?? "Feishu API error \(code)") }
        }
    }
    private struct CalendarList: Decodable { var calendar_list: [Item]?; struct Item: Decodable { var calendar_id: String; var summary: String } }
    private struct CreatedEvent: Decodable { var event: Ev; struct Ev: Decodable { var event_id: String } }
    private struct Empty: Decodable {}
}
```

> NOTE: `tokens.clearAccessOnly()` — add a method to `FeishuTokenManager` that forces the next `validAccessToken()` to refresh: simplest is to store the bundle with `accessTokenExpiry = .distantPast`. Implement:
> ```swift
> public func clearAccessOnly() throws {
>     guard var b = try loadTokens() else { return }
>     b.accessTokenExpiry = Date.distantPast
>     try storeTokens(b)
> }
> ```

- [ ] **Step 4: pass.** **Step 5: commit** `feat: add native Feishu API client`.

---

### Task 8: Service integration + migration + authorize entry

**Files:** `CalendarSync/CalendarSyncService.swift`.

- [ ] **Step 1: failing test** (append to `FeishuAPIClientTests` or a service test):

```swift
@MainActor
final class FeishuServiceTests: XCTestCase {
    func testMigratesLegacyKeychainPasswordIntoEncryptedStore() throws {
        let store = InMemoryStateStore()
        let legacy = MemoryCredentialStore()
        try legacy.savePassword("pw", account: "dingtalk:alice")
        let encrypted = EncryptedSecretStore(store: store, masterKey: InMemoryMasterKeyProvider())
        try store.saveCalendarSource(CalendarSource(kind: .dingtalk, username: "alice", feishuCalendarID: "c", isEnabled: true))

        let service = CalendarSyncService(stateStore: store, credentialStore: encrypted)
        service.migrateLegacyCredentials(from: legacy)

        XCTAssertEqual(try encrypted.readPassword(account: "dingtalk:alice"), "pw")
    }
}
```

- [ ] **Step 2: fail.**

- [ ] **Step 3: implement** — add to `CalendarSyncService`:

```swift
    public func migrateLegacyCredentials(from legacy: any CredentialStoring) {
        for source in configuration.sources {
            let account = source.credentialAccount()
            if (try? credentialStore.readPassword(account: account)) ?? nil == nil,
               let pw = (try? legacy.readPassword(account: account)) ?? nil, !pw.isEmpty {
                try? credentialStore.savePassword(pw, account: account)
            }
        }
        refreshHasStoredPasswordsPublic()
    }

    private func refreshHasStoredPasswordsPublic() { refreshHasStoredPasswords() }
```

Add a Feishu authorize entry point + manager (inject via init). Add to init params:

```swift
        feishuTokenManager: FeishuTokenManager? = nil,
```

store `self.feishuTokenManager = feishuTokenManager` (optional). Add:

```swift
    @Published public private(set) var feishuAuthorized = false

    public func refreshFeishuAuthState() {
        feishuAuthorized = feishuTokenManager?.isAuthorized() ?? false
    }

    public func saveFeishuApp(appID: String, appSecret: String) throws {
        try feishuTokenManager?.saveAppCredentials(appID: appID, appSecret: appSecret)
    }

    public func authorizeFeishu(openBrowser: @escaping (URL) -> Void) async -> Result<Void, Error> {
        guard let mgr = feishuTokenManager, let appID = mgr.appID() else { return .failure(FeishuAuthError.notConfigured) }
        do {
            let bundle = try await FeishuLoopbackAuthorizer().authorize(appID: appID, appSecret: (try mgr.appSecret()) ?? "", oauth: FeishuOAuth(), openBrowser: openBrowser)
            try mgr.storeTokens(bundle)
            refreshFeishuAuthState()
            return .success(())
        } catch {
            return .failure(error)
        }
    }
```

> NOTE: `mgr.appSecret()` — add `public func appSecret() throws -> String? { try credentials.readPassword(account: appSecretAccount) }` to `FeishuTokenManager`. `FeishuLoopbackAuthorizer` is implemented in Task 9.

Update `live(databasePath:)`:

```swift
    public static func live(databasePath: String) throws -> CalendarSyncService {
        let store = try SQLiteStateStore(path: databasePath)
        let encrypted = EncryptedSecretStore(store: store, masterKey: KeychainMasterKeyProvider())
        let tokenManager = FeishuTokenManager(credentials: encrypted)
        let feishu = FeishuAPIClient(tokens: tokenManager)
        let caldav = DingTalkCalDAVClient()
        let service = CalendarSyncService(
            stateStore: store,
            credentialStore: encrypted,
            feishuProvider: feishu,
            feishuWriter: feishu,
            caldavClient: caldav,
            feishuTokenManager: tokenManager
        )
        // One-time migration from the old Keychain credential store.
        service.loadSettings()
        service.migrateLegacyCredentials(from: KeychainCredentialStore())
        service.refreshFeishuAuthState()
        return service
    }
```

- [ ] **Step 4: pass** (`FeishuServiceTests`), and `swift test --filter CalendarSyncServiceConfigTests` still green (defaults unchanged).
- [ ] **Step 5: commit** `feat: integrate encrypted store and Feishu auth into service`.

---

### Task 9: Loopback authorizer

**Files:** `Feishu/FeishuOAuth.swift` (append `FeishuLoopbackAuthorizer`).

Implements the local one-shot HTTP listener using Network.framework (`NWListener`) on `127.0.0.1:17865`, opens the browser, waits for `/callback?code=…&state=…`, exchanges the code. No unit test (integration/manual); keep it small and isolated.

- [ ] **Step 1: implement** (concise NWListener-based capture):

```swift
import Foundation
import Network

public struct FeishuLoopbackAuthorizer: Sendable {
    public let port: UInt16
    public init(port: UInt16 = 17865) { self.port = port }

    public var redirectURI: String { "http://127.0.0.1:\(port)/callback" }

    public func authorize(appID: String, appSecret: String, oauth: FeishuOAuth, openBrowser: @escaping (URL) -> Void) async throws -> FeishuTokenBundle {
        let state = UUID().uuidString
        let url = oauth.authorizeURL(appID: appID, redirectURI: redirectURI, state: state, scopes: FeishuScopes.calendar)
        let code = try await captureCode(expectedState: state) {
            openBrowser(url)
        }
        return try await oauth.exchange(appID: appID, appSecret: appSecret, code: code, redirectURI: redirectURI)
    }

    private func captureCode(expectedState: String, onReady: @escaping () -> Void) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            do {
                let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
                let finished = LockedFlag()
                listener.newConnectionHandler = { connection in
                    connection.start(queue: .global())
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                        let request = String(data: data ?? Data(), encoding: .utf8) ?? ""
                        let html = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html><body>Authorization complete. You can close this window.</body></html>"
                        connection.send(content: html.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
                        guard finished.setOnce() else { return }
                        listener.cancel()
                        if let code = Self.parse(request, param: "code"), Self.parse(request, param: "state") == expectedState {
                            continuation.resume(returning: code)
                        } else {
                            continuation.resume(throwing: FeishuAuthError.server("authorization failed or state mismatch"))
                        }
                    }
                }
                listener.start(queue: .global())
                onReady()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func parse(_ request: String, param: String) -> String? {
        guard let line = request.split(separator: "\r\n").first,
              let pathPart = line.split(separator: " ").dropFirst().first,
              let comps = URLComponents(string: "http://x\(pathPart)") else { return nil }
        return comps.queryItems?.first(where: { $0.name == param })?.value
    }
}

public enum FeishuScopes {
    public static let calendar = [
        "offline_access",
        "calendar:calendar",
        "calendar:calendar:read",
        "calendar:calendar.event:create",
        "calendar:calendar.event:update",
        "calendar:calendar.event:delete",
        "calendar:calendar.event:read"
    ]
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func setOnce() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
```

- [ ] **Step 2: build** `swift build`. **Step 3: commit** `feat: add Feishu loopback authorizer`.

---

### Task 10: SettingsView Feishu section

**Files:** `App/Dashboard/Settings/SettingsView.swift`.

- [ ] **Step 1:** add a Feishu section at the top of the `Form` (before the source sections):

```swift
            Section("Feishu") {
                SecureField("App ID (AK)", text: $feishuAppID)
                SecureField("App Secret (SK)", text: $feishuAppSecret)
                Text("Register this redirect URI in your Feishu app: http://127.0.0.1:17865/callback")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Button("Save app") { saveFeishuApp() }
                    Button("Authorize") { Task { await authorizeFeishu() } }.disabled(isBusy)
                    if service.feishuAuthorized {
                        Label("Authorized", systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.caption)
                    }
                }
                if let feishuError { Text(feishuError).foregroundStyle(.red).font(.caption) }
            }
```

Add `@State private var feishuAppID = ""`, `feishuAppSecret = ""`, `feishuError: String?`, and:

```swift
    private func saveFeishuApp() {
        feishuError = nil
        do { try service.saveFeishuApp(appID: feishuAppID, appSecret: feishuAppSecret); feishuAppSecret = "" }
        catch { feishuError = String(describing: error) }
    }

    private func authorizeFeishu() async {
        isBusy = true; feishuError = nil
        let result = await service.authorizeFeishu { url in NSWorkspace.shared.open(url) }
        if case let .failure(error) = result { feishuError = String(describing: error) }
        isBusy = false
    }
```

Add `import AppKit` for `NSWorkspace`.

- [ ] **Step 2: build** `swift build`. **Step 3: commit** `feat: add Feishu app + authorize UI`.

---

### Task 11: Remove lark-cli

**Files:** delete `Feishu/FeishuCLIClient.swift`, `Feishu/CommandRunner.swift`, `Tests/.../FeishuCLIClientTests.swift`; edit `Feishu/FeishuCalendarProviding.swift`.

- [ ] **Step 1:** remove the `extension FeishuCLIClient: FeishuCalendarProviding {}` line from `FeishuCalendarProviding.swift` (keep the protocol). Delete the three files.

- [ ] **Step 2: build** `swift build` — fix any remaining references (there should be none after Task 8 updated `live()`).

- [ ] **Step 3: full test** `swift test` — expect green. Remove or update any test that referenced `FeishuCLIClient`/`CommandRunner`.

- [ ] **Step 4: commit** `refactor: remove lark-cli dependency`.

---

### Task 12: Full verify + package

- [ ] **Step 1:** `swift build`
- [ ] **Step 2:** `swift test` (all green)
- [ ] **Step 3:** `swift build -c release`
- [ ] **Step 4:** `./Scripts/package-app.sh` then `open dist/NeoToolbox.app`; confirm Settings shows the Feishu section (AK/SK + redirect URI + Authorize) and the per-source sections.
- [ ] **Step 5: commit** any fixups: `test: verify native Feishu build`.

---

## Self-Review

**Spec coverage:** master key (T2), encrypted secret store replacing Keychain for secrets (T1,T3), secrets table (T1), OAuth auth-code+loopback (T5,T9), token lifecycle/refresh (T6), native calendar client with 401-retry (T7), AK/SK + authorize UI (T10), migration from Keychain (T8), remove lark-cli (T11), global Feishu app (T8,T10), verify (T12). All spec items mapped.

**Placeholder scan:** Concrete code throughout. NOTEs flag: `SQLITE_TRANSIENT` declaration, `clearAccessOnly`/`appSecret()` manager additions, and that the loopback authorizer is integration-only. Each gives exact code.

**Type consistency:** `FeishuTokenBundle` (T5) used in T6/T7/T8/T9. `FeishuTokenManager` API (`validAccessToken`, `storeTokens`, `hasAppCredentials`, `appID`, `appSecret`, `clearAccessOnly`) defined T6/T7-NOTE/T8-NOTE, used T7/T8. `EncryptedSecretStore(store:masterKey:)` (T3) used T8. `FeishuLoopbackAuthorizer.redirectURI` = `http://127.0.0.1:17865/callback` matches the UI string (T10) and `authorizeURL` redirect. `FeishuScopes.calendar` (T9) includes `offline_access` so a refresh_token is issued (required by T6).

**Risks for the implementer:** Feishu may reject a `127.0.0.1` redirect that isn't registered — the user must paste the shown redirect URI into their app config; if Feishu disallows loopback entirely, fall back to a manual code-paste field (out of scope here, note to user). The v2 token response field names (`access_token`, `expires_in`, `refresh_token`, `refresh_token_expires_in`) are assumed per OAuth2 norms; verify against a live response during manual auth and adjust `TokenResponse` keys if Feishu nests them under `data`.
