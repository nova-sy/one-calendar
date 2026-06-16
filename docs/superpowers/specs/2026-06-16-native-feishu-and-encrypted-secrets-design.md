# Native Feishu App + Encrypted Local Secret Store Design

Date: 2026-06-16
Status: Approved design, pending implementation plan

## Problem

The Feishu side depends on the local `lark-cli` binary (a Node script). That
dependency is fragile: it breaks under the minimal PATH a Finder-launched app
gets (we had to patch the subprocess PATH for `node`), it requires the user to
install and authorize a separate tool, and it limits the app to whatever the CLI
exposes. CalDAV passwords currently live in the system Keychain.

This redesign:
1. Replaces `lark-cli` with a **native, self-built Feishu app** that the app
   authorizes via OAuth and then calls the Feishu Calendar API directly over
   HTTPS.
2. **Moves business secrets (CalDAV passwords, Feishu app_id/app_secret, Feishu
   tokens) out of the Keychain into the local SQLite database, encrypted at
   rest.** A single master key remains in the Keychain.

## Decisions (from brainstorming)

- **Encrypted-at-rest**: secrets stored as ciphertext in SQLite; one AES-GCM
  master key in the Keychain.
- **OAuth flow**: authorization-code with a loopback redirect (see deviation
  below). The user's app_id (AK) and app_secret (SK) are entered in Settings.
- **Remove `lark-cli` entirely**; replace with a native `FeishuAPIClient`.

### Deviation from "device flow"

Brainstorming chose the OAuth device flow (as `lark-cli` uses). Research found
Feishu does **not** publicly document the RFC 8628 device-authorization grant;
`lark-cli` relies on an undocumented endpoint. To avoid building on an
unsupported, fragile endpoint, this design uses the **documented authorization-
code grant** (Feishu v2 OAuth) with a **loopback redirect** captured by a short-
lived local HTTP server. The in-app UX is the same one-click "Authorize" button;
the only added setup is registering a fixed `http://127.0.0.1:<port>/callback`
redirect URI in the Feishu app (the Settings screen shows the exact string to
paste).

## Goals

- One global self-built Feishu app: user enters AK/SK, clicks Authorize once.
- Direct Feishu Calendar API calls (list/create/update/delete) with a
  user_access_token, auto-refreshing on expiry.
- Business secrets encrypted in the local DB; Keychain holds only the master key.
- One-time migration of existing Keychain CalDAV passwords into the encrypted DB.
- No `lark-cli` / `node` / subprocess dependency.

## Non-Goals

- Tenant-level (admin) Feishu access — user_access_token scopes to the
  authorizing user only (matches the "user's own calendar" requirement).
- Publishing to the Feishu app store; the user registers a self-built app.
- Encrypting the entire database — only secret values are encrypted (event
  mappings etc. stay plaintext, as today).

## Architecture

Five units. The `FeishuCalendarProviding` / `FeishuCalendarWriting` /
`CredentialStoring` protocols are unchanged, so `SyncEngine`, the multi-source
orchestration, and most of `SettingsView` are untouched.

### 1. `MasterKeyProvider` (NeoToolboxCore)

Generates a 256-bit symmetric key on first run and stores it in the Keychain
(account `neo-toolbox.master-key`); returns it on subsequent runs.

```
public protocol MasterKeyProviding: Sendable {
    func masterKey() throws -> SymmetricKey
}
public struct KeychainMasterKeyProvider: MasterKeyProviding { ... }
```

If the key cannot be read or created, secret operations throw — the app never
silently falls back to plaintext.

### 2. `EncryptedSecretStore` (NeoToolboxCore) — replaces Keychain for secrets

Backed by a new SQLite table and AES-GCM (CryptoKit):

```
CREATE TABLE secrets (
    account TEXT PRIMARY KEY,
    ciphertext BLOB NOT NULL,
    nonce BLOB NOT NULL
);
```

Implements the existing `CredentialStoring` protocol (`savePassword`,
`readPassword`, `deletePassword`) so it drops into the service where
`KeychainCredentialStore` is used today — for CalDAV passwords. It also stores
the Feishu app_secret and tokens under reserved account keys.

```
public final class EncryptedSecretStore: CredentialStoring {
    init(store: any StateStoring /* SQLite-backed */, masterKey: any MasterKeyProviding)
    // savePassword/readPassword/deletePassword encrypt/decrypt via AES-GCM
}
```

New `StateStoring` methods back the table: `saveSecret(account:ciphertext:nonce:)`,
`loadSecret(account:) -> (Data, Data)?`, `deleteSecret(account:)`.

### 3. `FeishuOAuth` (NeoToolboxCore) — authorization-code + loopback

- Builds the authorize URL:
  `https://accounts.feishu.cn/open-apis/authen/v1/authorize?client_id=<AK>&redirect_uri=<loopback>&response_type=code&scope=<calendar scopes + offline_access>&state=<random>`.
- Runs a one-shot loopback HTTP listener on a fixed port (`127.0.0.1:17865`),
  waits for `/callback?code=…&state=…`, validates `state`, returns the code.
- Exchanges the code at `POST https://open.feishu.cn/open-apis/authen/v2/oauth/token`
  with `grant_type=authorization_code, client_id, client_secret, code,
  redirect_uri`. Stores `access_token` (+ `expires_in` seconds) and
  `refresh_token` (+ its expiry) encrypted.
- Refresh: `POST …/oauth/token` with `grant_type=refresh_token`.

```
public struct FeishuOAuth: Sendable {
    func authorize(appID: String, appSecret: String, openBrowser: (URL) -> Void) async throws -> FeishuTokenBundle
    func refresh(appID: String, appSecret: String, refreshToken: String) async throws -> FeishuTokenBundle
}
```

`FeishuTokenBundle { accessToken, accessTokenExpiry, refreshToken, refreshTokenExpiry }`.
An injectable `now`/HTTP transport keeps it testable.

### 4. `FeishuAPIClient` (NeoToolboxCore) — replaces `FeishuCLIClient`

Implements `FeishuCalendarProviding` + `FeishuCalendarWriting` by calling the
Feishu Calendar v4 API over HTTPS with the user_access_token:

- `checkDependency()` → reports whether AK/SK are set and a valid token exists
  (reusing `DependencyCheck`; "missing" message guides the user to authorize).
- `listCalendars()` → `GET /open-apis/calendar/v4/calendars`.
- `createEvent` → `POST /open-apis/calendar/v4/calendars/{id}/events`.
- `updateEvent` → `PATCH …/events/{event_id}`.
- `deleteEvent` → `DELETE …/events/{event_id}`.

Parses the `{ code, msg, data }` envelope (same shape we already handle). On a
401 / token-expired response, it refreshes via a `FeishuTokenManager` and
retries once.

`FeishuTokenManager` owns token lifecycle: reads tokens from the encrypted
store, refreshes when `accessTokenExpiry` is near, persists rotated tokens, and
surfaces "needs re-authorization" when the refresh token has expired.

### 5. Settings UI — global Feishu section

`SettingsView` gains a **Feishu** section (above the per-source sections):
- `app_id` (AK) and `app_secret` (SK) `SecureField`s.
- The exact redirect URI string to register, shown for copy.
- An **Authorize** button → runs `FeishuOAuth.authorize`, opening the browser;
  shows authorized/not-authorized status and the authorized user.
- Errors (missing AK/SK, auth failure/timeout, refresh expired) shown inline.

The per-source target-calendar dropdowns now populate from `FeishuAPIClient`.

## Data flow

```
First run → MasterKeyProvider creates/loads master key in Keychain
          → migrate any legacy Keychain CalDAV passwords into encrypted DB

Configure Feishu → enter AK/SK (encrypted in DB) → Authorize
   → browser → loopback captures code → token exchange → tokens encrypted in DB

Sync → FeishuAPIClient calls Calendar API with user_access_token
     → on 401: FeishuTokenManager refreshes, retries once
     → CalDAV side unchanged (password now read from EncryptedSecretStore)
```

## Error handling

- Master key unreadable → secret ops throw; sync refuses to run (no plaintext
  fallback).
- AES-GCM decrypt failure (tampered/corrupt) → throw a typed error; surface in UI.
- AK/SK missing or token absent → Feishu `checkDependency` reports missing with a
  "authorize in Settings" message.
- Authorization timeout / state mismatch / user denied → typed error, inline.
- Refresh-token expired → "re-authorize" prompt; sync for the Feishu side pauses.

## Testing

Unit tests (fakes; no network, no Keychain):
- `EncryptedSecretStore`: save→read round-trip; wrong master key fails to
  decrypt; delete removes.
- Legacy migration: a Keychain-backed password is re-encrypted into the DB once
  and the service reads it back.
- `FeishuOAuth`: code→token exchange and refresh parse the v2 envelope (fake
  HTTP); state mismatch rejected.
- `FeishuTokenManager`: refreshes when near expiry, persists rotated tokens,
  reports re-auth when refresh expired.
- `FeishuAPIClient`: list/create/update/delete request shape + envelope parse;
  401 triggers one refresh+retry.
- Protocols unchanged → SyncEngine / multi-source tests carry over.

Live verification requires the user to register a self-built Feishu app, enter
AK/SK, and authorize in the browser — a manual step that cannot be automated.

## Files

New (NeoToolboxCore):
- `Security/MasterKeyProvider.swift`
- `Security/EncryptedSecretStore.swift`
- `Feishu/FeishuOAuth.swift`
- `Feishu/FeishuTokenManager.swift`
- `Feishu/FeishuAPIClient.swift`
- `Feishu/FeishuHTTP.swift` (small HTTPS transport seam)

New (tests): `Tests/NeoToolboxCoreTests/EncryptedSecretStoreTests.swift`,
`FeishuOAuthTests.swift`, `FeishuAPIClientTests.swift`.

Modified:
- `Storage/StateStore.swift` + `SQLiteStateStore.swift` + `InMemoryStateStore.swift` (secrets table).
- `CalendarSync/CalendarSyncService.swift` (use EncryptedSecretStore; Feishu token state; authorize entry point; migration).
- `App/.../SettingsView.swift` (Feishu section).
- `App/DashboardWindowController.swift` (wire EncryptedSecretStore + FeishuAPIClient into the live service).

Removed:
- `Feishu/FeishuCLIClient.swift`, `Feishu/CommandRunner.swift`,
  `Feishu/FeishuCalendarProviding.swift`'s `FeishuCLIClient` conformance,
  and the `Tests/.../FeishuCLIClientTests.swift`. The CommandRunner PATH patch
  goes away with it.
