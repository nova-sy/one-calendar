# Flutter Cross-Platform Rewrite — Migration Plan

Date: 2026-06-16
Target: a **new repository** `neo-toolbox-flutter`, Flutter (Dart), macOS + Windows.
Source of truth for behavior: the current Swift app (this repo) at its final state,
plus the protocol specs under `docs/superpowers/specs/`.

> The Swift macOS app stays the working/reference build until the Flutter app
> reaches parity, then is archived. Copy the `docs/superpowers/specs/*` protocol
> findings into the new repo — they are the language-agnostic asset.

## Feature parity checklist (current final app)

- Menu-bar / tray resident app; window opens from tray; keeps running after the
  window closes; sync continues; explicit Quit stops it.
- Multi-source CalDAV: **DingTalk** (`/dav/{user}/primary/`, fixed path) and
  **Tencent Meeting** (`cal.meeting.tencent.com`, discovered collection via the
  well-known → principal → calendar-home → first-calendar chain).
- CalDAV fetch = `REPORT calendar-query` with a required `time-range` (window
  forward); parse iCalendar (incl. `&#13;` entity decode); normalize events.
- Per-source target Feishu calendar (same or different); per-source isolation
  (mappings tagged by source so two sources sharing a calendar never delete
  each other's events).
- Native Feishu integration (no lark-cli): self-built app AK/SK; OAuth
  authorization-code + loopback `http://127.0.0.1:17865/callback`; token manager
  (auto-refresh, re-auth when refresh expired); Calendar v4 API client
  (list/create/update/delete) with 401 refresh-and-retry.
- Sync engine: fetch → fingerprint → plan (create/update/delete) → apply →
  persist event mappings; aggregate per enabled source.
- Encrypted local secrets: AES-GCM, master key in a local 0600 file (no OS
  keychain); CalDAV passwords + AK/SK + Feishu tokens stored encrypted in SQLite.
- Global sync rules: interval (10/30/60 min) + window (7/30/90 days). Background
  timer.
- UI: sidebar (Calendar Sync, Settings); Calendar Sync page = status cards
  (Status / Last Sync / Window / Last Changes) + runtime log; Settings = Feishu
  section (AK plaintext, SK masked + reveal eye, redirect URI, Save, Authorize,
  auth state) + per-source sections (username, password masked + reveal, target
  calendar dropdown auto-loaded, enable, Test) + sync rules. App logo (calendar
  + sync arrows).

## Dart stack (package choices)

| Concern | Swift now | Flutter/Dart |
|---|---|---|
| HTTP + custom verbs (PROPFIND/REPORT) | URLSession | `dio` (supports custom methods) |
| SQLite | sqlite3 C | `drift` (typed) or `sqflite_common_ffi` |
| AES-GCM | CryptoKit | `cryptography` package |
| Master key file 0600 | Foundation + posix | `dart:io` File + `path_provider`; chmod on POSIX, ACL/skip on Windows |
| OAuth loopback server | NWListener | `dart:io` `HttpServer.bind('127.0.0.1', 17865)` |
| Open browser | NSWorkspace | `url_launcher` |
| Tray / menu-bar | AppKit NSStatusItem | `tray_manager` + `window_manager` |
| iCalendar parse | custom | `icalendar_parser` or port the custom parser |
| State mgmt | @Published / ObservableObject | `riverpod` |
| Background timer | Task loop | `Timer.periodic` |
| Packaging | custom .app script | `flutter build macos` + `flutter build windows` + installers |

## Architecture mapping (Swift → Dart modules)

```
lib/
  core/
    models/        CalendarSource, CalendarSourceKind, NormalizedEvent, EventMapping,
                   SyncReport, CalendarSyncSettings/Configuration   (← Core/*)
    storage/       AppDatabase (drift): tool_settings, calendar_sources,
                   event_mappings, secrets  (← SQLiteStateStore)
    security/      MasterKeyProvider (file), EncryptedSecretStore (AES-GCM)
                   (← Security/*)
    caldav/        CalDavDiscovery, CalDavCalendarClient, ICalendarParser
                   (← DingTalk/*)
    feishu/        FeishuOAuth (+ loopback), FeishuTokenManager, FeishuApiClient
                   (← Feishu/*)
    sync/          EventFingerprint, SyncPlanBuilder, SyncEngine
                   (← Sync/*)
    service/       CalendarSyncService (Riverpod controller)  (← CalendarSyncService)
  ui/
    tray/          tray + window lifecycle   (← MenuBar/*, DashboardWindowController)
    dashboard/     sidebar + routing         (← Dashboard/*)
    calendar_sync/ status cards + log        (← CalendarSyncView, RuntimeLogView)
    settings/      Feishu + per-source + rules + RevealableSecretField
                   (← SettingsView, RevealableSecureField)
  main.dart
```

---

## Phase 0: Repo scaffold

- [ ] `flutter create --platforms=macos,windows neo-toolbox-flutter`; set app id
      `com.nova-sy.neotoolbox`, name "Neo Toolbox".
- [ ] Add deps: `dio`, `drift` + `drift_flutter`/`sqlite3_flutter_libs`,
      `cryptography`, `path_provider`, `url_launcher`, `tray_manager`,
      `window_manager`, `riverpod`/`flutter_riverpod`, `intl`.
- [ ] Copy `docs/superpowers/specs/*` from the Swift repo into `docs/`.
- [ ] CI: GitHub Actions building macОS + Windows artifacts (mirror the Swift
      repo's release workflow shape).

## Phase 1: Models + storage

- [ ] Port value types (`CalendarSource`, `CalendarSourceKind` with host +
      mappingTag + displayName, `NormalizedEvent`, `EventMapping` with
      `mappingKey`, `SyncReport`, `CalendarSyncSettings`/`Configuration`).
- [ ] `drift` schema: `tool_settings`, `calendar_sources`, `event_mappings`
      (with `source` column), `secrets` (BLOB ciphertext+nonce). Mirror the
      SQLite DDL in `SQLiteStateStore.swift`.
- [ ] DAO methods incl. `loadEventMappings(calendarId, source)` for isolation,
      and `calendar_sources` CRUD.
- [ ] Tests: round-trips, source-scoped mapping isolation.

## Phase 2: Security (encrypted secrets)

- [ ] `FileMasterKeyProvider`: 32-byte key in `<appSupport>/NeoToolbox/master.key`;
      create if absent; chmod 0600 on POSIX, best-effort on Windows.
- [ ] `EncryptedSecretStore`: AES-GCM via `cryptography`; `save/read/delete`
      keyed by account; ciphertext+nonce in `secrets`. Same account scheme
      (`<kind>:<username>`, `feishu:app_id|app_secret|tokens`).
- [ ] Tests: encrypt round-trip; wrong key fails; tamper fails.

## Phase 3: CalDAV (DingTalk + Tencent)

- [ ] `ICalendarParser`: VEVENT extraction + `&#13;`/`&amp;` decode + field
      parsing (port `ICalendarParser.swift` + the entity-decode logic).
- [ ] `CalDavDiscovery`: PROPFIND chain (well-known → principal →
      calendar-home-set → first calendar collection). Reference verified Tencent
      shape in the spec.
- [ ] `CalDavCalendarClient`: strategy `fixedPath("/dav/{user}/primary/")`
      (DingTalk) vs `discover` (Tencent); `REPORT calendar-query` with
      `time-range` from window; Basic auth; parse via ICalendarParser. Factory by
      kind.
- [ ] Tests: fixed-path URL build; discovery walks faked PROPFIND XML; entity
      decode. (Live DingTalk/Tencent verified manually as in the Swift app.)

## Phase 4: Feishu native (OAuth + API)

- [ ] `FeishuOAuth`: build authorize URL (`accounts.feishu.cn/.../authorize`),
      token exchange + refresh at `open.feishu.cn/open-apis/authen/v2/oauth/token`,
      `{code,msg,access_token,expires_in,refresh_token,refresh_token_expires_in}`.
- [ ] Loopback: `HttpServer.bind('127.0.0.1', 17865)`, capture `/callback?code&state`,
      validate state, then exchange. Scopes incl. `offline_access` + the 6
      calendar scopes.
- [ ] `FeishuTokenManager`: store AK/SK/tokens (encrypted), `validAccessToken()`
      refresh-on-expiry, re-auth when refresh expired.
- [ ] `FeishuApiClient`: `/open-apis/calendar/v4` list/create/update/delete with
      Bearer; `{code,msg,data}` envelope; 401 → refresh → retry once. Implements
      the calendar provider/writer interfaces.
- [ ] Tests: token exchange/refresh parse; manager lifecycle; API list/create +
      401 retry + business-error.

## Phase 5: Sync engine + service

- [ ] `EventFingerprint` (hash of normalized fields — port to `cryptography`
      sha256), `SyncPlanBuilder` (create/update/delete diff vs mappings),
      `SyncEngine` (fetch → plan → apply → persist mappings tagged by source tag).
- [ ] `CalendarSyncService` (Riverpod): load configuration (+ no Keychain
      migration needed in the new app), save/test per source, build a runner per
      enabled+configured source, aggregate `triggerSync`, background timer,
      Feishu save/authorize/auth-state, status + recent logs.
- [ ] Tests: per-source sync isolation, aggregate run, save/test flows.

## Phase 6: UI

- [ ] Tray (`tray_manager`): icon + menu (Open Dashboard, Sync Now, Quit);
      `window_manager` to show/hide window, keep app alive on window close
      (skipTaskbar/hidden), quit on explicit Quit.
- [ ] Dashboard: sidebar (Calendar Sync, Settings) + detail routing.
- [ ] Calendar Sync page: status cards (Status idle/running/failed, Last Sync
      time, Window, Last Changes c/u/d) bound to service; runtime log list.
- [ ] Settings: Feishu section (AK `TextField`, SK reveal field, redirect URI
      copyable, Save, Authorize → `url_launcher` + loopback, auth badge); per
      source section (username, password reveal field, target-calendar dropdown
      auto-loaded when authorized, enable, Test with per-side result); sync rules
      dropdowns. `RevealableSecretField` widget (mask + eye toggle).
- [ ] App logo asset (reuse `Assets/logo_master.png`) for icon + window branding;
      generate `.ico`/`.icns`/PNGs for both platforms.

## Phase 7: Packaging + release

- [ ] macOS: `flutter build macos`; bundle as menu-bar app (LSUIElement via
      Info.plist), sign ad-hoc for dev.
- [ ] Windows: `flutter build windows`; package with MSIX (`msix` package) or an
      installer (Inno Setup); tray app from system tray.
- [ ] CI release workflow: tag `v*` → build both → attach artifacts.

## Risks / platform notes

- Feishu loopback redirect must be registered in the app config (same as today);
  if Feishu rejects `127.0.0.1`, fall back to a manual code-paste field.
- Windows file ACLs ≠ POSIX 0600; the master key file protection is weaker on
  Windows — document it, or use Windows DPAPI (`CryptProtectData`) for the master
  key on Windows only.
- Tray behavior differs subtly macOS vs Windows (`tray_manager` abstracts most).
- iCalendar timezone handling: verify all-day vs timed events match the Swift
  parser's output on both DingTalk and Tencent samples.

## Estimate

~3–5 weeks to parity for one developer: phases 1–5 (logic, mostly mechanical
ports of small files) ~2 weeks; phase 6 (UI) ~1.5 weeks; phase 7 (packaging both
OSes) ~0.5–1 week.
