# Neo Toolbox (Flutter)

Cross-platform (macOS + Windows) calendar sync: **DingTalk** and **Tencent
Meeting** calendars (CalDAV) → **Feishu**. A Flutter rewrite of the macOS-native
Swift app, sharing the same protocol design (see `docs/`).

## Features

- **Tray-resident** desktop app; window opens from the tray and the app keeps
  running after the window is closed (Quit from the tray to exit).
- **Multi-source CalDAV**: DingTalk (`/dav/{user}/primary/`) and Tencent Meeting
  (collection discovered via the well-known to principal to home to calendar chain).
- **Per-source target Feishu calendar** with per-source isolation.
- **Native Feishu integration**: self-built app (AK/SK), OAuth authorization-code
  + loopback, token auto-refresh, Calendar v4 API (list/create/update/delete).
- **Encrypted local secrets**: AES-GCM, master key in a local 0600 file (no OS
  keychain). CalDAV passwords + Feishu AK/SK + tokens stored encrypted in SQLite.
- Sync rules: interval (10/30/60 min) + window (7/30/90 days), background timer.

## Develop

    flutter pub get
    flutter test
    flutter run -d macos       # or -d windows

## Build

    flutter build macos --release
    flutter build windows --release

CI builds both on push; tagging `v*` attaches both zips to a GitHub Release.

## Feishu setup (one-time, user side)

1. Create a self-built app at open.feishu.cn; copy App ID + App Secret into
   Settings > Feishu.
2. Register the redirect URI http://127.0.0.1:17865/callback
3. Enable calendar scopes (read/create/update/delete + event:*, offline_access),
   publish a version, get admin approval.
4. Settings > Feishu > Authorize.
