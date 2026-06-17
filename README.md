# ONE CALENDAR

把**钉钉 / 腾讯会议**日历（CalDAV）单向同步到**飞书**的桌面应用，支持 **macOS + Windows**。

> English: see [README.en.md](README.en.md)

---

## 功能

- **多来源**：钉钉、腾讯会议，可同时启用
- **每源独立目标日历**：每个来源各选自己的飞书日历（可同可不同），来源间互不干扰（一个来源的同步不会删另一个来源的日程）
- **原生飞书集成**：自建应用 OAuth 授权，直接调飞书日历 API（创建 / 更新 / 删除），无需任何外部命令行工具
- **后台定时同步**：间隔 10 / 30 / 60 分钟，窗口 7 / 30 / 90 天；改动即自动保存并重排定时
- **本地加密存储**：账号密码、AK/SK、令牌均 AES-GCM 加密存本地数据库；主密钥放本地文件（不占用系统钥匙串）
- **常驻后台**：关闭窗口不退出，后台继续同步；macOS 点 Dock 图标重开，Windows 用系统托盘
- **中 / 英双语**（默认中文）、**自动检查更新**

---

## 安装

到 [Releases](https://github.com/nova-sy/one-calendar/releases) 下载：

- **macOS**：`OneCalendar-macos.zip` → 解压 → 运行 `OneCalendar.app`
  （首次打开若被 Gatekeeper 拦，右键 → 打开）
- **Windows**：`OneCalendar-windows.zip` → 解压 → 运行 `OneCalendar.exe`

---

## 配置

### 1. 飞书（同步目标，自建应用）

1. 打开 [open.feishu.cn](https://open.feishu.cn) → 开发者后台 → **创建企业自建应用**，拿到 **App ID** 和 **App Secret**
2. **安全设置 → 重定向 URL** 添加：`http://127.0.0.1:17865/callback`
3. **权限管理** 开通日历权限（user 级）：
   `offline_access`、`calendar:calendar`、`calendar:calendar:read`、
   `calendar:calendar.event:create / read / update / delete`
4. **创建版本并发布**（企业自建应用通常需管理员审批）
5. App 内 **设置 → 飞书** → 填 App ID / App Secret → **保存** → **授权**（浏览器完成授权）

> 用 user 级权限 + 用户令牌，只触达**授权人本人**的日历，不碰他人。

### 2. 钉钉（来源）

1. 钉钉日历开启 CalDAV，拿到 **CalDAV 账号 / 密码**（设置内可点「如何获取凭证」查看官方说明）
2. App 内 **设置 → DingTalk** → 填账号 / 密码 → 选**目标飞书日历** → 打开**启用** → 保存
3. 可点 **测试** 验证连接

### 3. 腾讯会议（来源）

同钉钉：腾讯会议日历的 CalDAV 订阅账号 / 密码 → **设置 → Tencent Meeting** → 填写 → 选目标日历 → 启用 → 保存。

### 4. 同步规则

**设置 → 同步规则**：选间隔与窗口，**改动即时保存**，定时器自动按新间隔运行。

---

## 使用

- **立即同步**：日历同步页右上「立即同步」，或托盘菜单「Sync Now」
- **后台**：保持运行即按间隔自动同步；关窗不停
- **退出**：macOS `Cmd-Q` 或 Dock 右键退出；Windows 托盘 → 退出
- **更新**：发现新版本时顶部提示，或在 **设置 → 关于** 手动检查

---

## 二次开发

技术栈 Flutter（Dart），`lib/core`（逻辑）+ `lib/ui`（界面）分层。

```bash
flutter pub get
flutter test          # 单元测试
flutter run -d macos  # 或 -d windows
flutter build macos --release
flutter build windows --release
```

模块：`core/storage`（SQLite）、`core/security`（加密）、`core/caldav`（钉钉/腾讯抓取）、`core/feishu`（OAuth + API）、`core/sync`（同步引擎）、`core/service`（编排）、`core/i18n`（多语言）。设计文档见 `docs/`。

CI 在每次 push 构建 macOS + Windows；打 `v*` 标签自动发 Release。
