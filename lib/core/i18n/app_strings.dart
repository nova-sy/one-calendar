import '../models/models.dart';

/// Supported UI languages. Chinese is the default.
enum AppLanguage {
  zh,
  en;

  /// BCP-47 locale code used by Flutter's [Locale] and intl date formatting.
  String get localeCode => switch (this) {
        AppLanguage.zh => 'zh',
        AppLanguage.en => 'en',
      };

  /// Name shown in the language switcher (always in the language itself).
  String get nativeName => switch (this) {
        AppLanguage.zh => '中文',
        AppLanguage.en => 'English',
      };

  static AppLanguage fromCode(String? code) => switch (code) {
        'en' => AppLanguage.en,
        'zh' => AppLanguage.zh,
        _ => AppLanguage.zh,
      };
}

/// All user-facing strings, resolved per [AppLanguage].
///
/// Add new strings as getters here and provide both translations in the
/// [zh] and [en] const instances below.
class AppStrings {
  final AppLanguage language;
  const AppStrings(this.language);

  static const AppStrings zh = AppStrings(AppLanguage.zh);
  static const AppStrings en = AppStrings(AppLanguage.en);

  static AppStrings of(AppLanguage language) =>
      language == AppLanguage.en ? en : zh;

  bool get _zh => language == AppLanguage.zh;

  // --- Navigation ---
  String get navCalendarSync => _zh ? '日历同步' : 'Calendar Sync';
  String get navSettings => _zh ? '设置' : 'Settings';

  // --- Update banner / tray / general ---
  String get appName => 'ONE CALENDAR';
  String updateAvailableBanner(String version) =>
      _zh ? '发现新版本（$version）。' : 'A new version ($version) is available.';
  String get later => _zh ? '稍后' : 'Later';
  String get update => _zh ? '更新' : 'Update';
  String get trayOpenDashboard => _zh ? '打开主界面' : 'Open Dashboard';
  String get traySyncNow => _zh ? '立即同步' : 'Sync Now';
  String get trayQuit => _zh ? '退出 ONE CALENDAR' : 'Quit ONE CALENDAR';

  // --- Calendar sync page ---
  String get syncPageTitle => _zh ? '同步日历到飞书' : 'Calendar Sync to Feishu';
  String get syncPageSubtitle => _zh
      ? '单向创建、更新与删除同步。'
      : 'Single-direction create, update, and delete sync.';
  String get syncNow => _zh ? '立即同步' : 'Sync Now';
  String get cardStatus => _zh ? '状态' : 'Status';
  String get cardLastSync => _zh ? '上次同步' : 'Last Sync';
  String get cardSyncWindow => _zh ? '同步窗口' : 'Sync Window';
  String get cardLastChanges => _zh ? '最近变更' : 'Last Changes';
  String get runtimeLog => _zh ? '运行日志' : 'Runtime Log';
  String get noActivityYet => _zh ? '暂无活动。' : 'No activity yet.';

  String get statusIdle => _zh ? '空闲' : 'Idle';
  String get statusRunning => _zh ? '同步中' : 'Running';
  String statusFailed(String message) =>
      _zh ? '失败：$message' : 'Failed: $message';
  String get neverSynced => _zh ? '从未' : 'Never';
  String days(int n) => _zh ? '$n 天' : '$n days';

  // --- Settings page ---
  String get settingsTitle => _zh ? '设置' : 'Settings';

  // Language section
  String get languageSection => _zh ? '语言' : 'Language';
  String get languageLabel => _zh ? '界面语言' : 'Interface language';

  // Feishu section
  String get feishuSection => 'Feishu';
  String get appIdLabel => _zh ? 'App ID（AK）' : 'App ID (AK)';
  String get appSecretLabel => _zh ? 'App Secret（SK）' : 'App Secret (SK)';
  String get redirectUriHint => _zh
      ? '请在飞书应用中注册以下重定向地址：\nhttp://127.0.0.1:17865/callback'
      : 'Register this redirect URI in your Feishu app:\nhttp://127.0.0.1:17865/callback';
  String get saveApp => _zh ? '保存应用' : 'Save app';
  String get authorize => _zh ? '授权' : 'Authorize';
  String get authorized => _zh ? '已授权' : 'Authorized';
  String get notAuthorized => _zh ? '未授权' : 'Not authorized';
  String get appCredentialsSaved =>
      _zh ? 'App ID 和 Secret 已保存' : 'App ID and Secret saved';
  String get authorizedSuccessfully =>
      _zh ? '授权成功' : 'Authorized successfully';

  // Source section
  String get notSelected => _zh ? '未选择' : 'Not selected';
  String get caldavUsername => _zh ? 'CalDAV 用户名' : 'CalDAV username';
  String get caldavPassword => _zh ? 'CalDAV 密码' : 'CalDAV password';
  String get targetCalendar => _zh ? '目标日历' : 'Target calendar';
  String get enabled => _zh ? '启用' : 'Enabled';
  String get test => _zh ? '测试' : 'Test';
  String saveNamed(String name) => _zh ? '保存 $name' : 'Save $name';
  String get howToGetCredentials =>
      _zh ? '如何获取凭据' : 'How to get credentials';

  // Sync rules section
  String get syncRulesSection => _zh ? '同步规则' : 'Sync rules';
  String get intervalLabel => _zh ? '同步间隔' : 'Interval';
  String get minutes10 => _zh ? '10 分钟' : '10 minutes';
  String get minutes30 => _zh ? '30 分钟' : '30 minutes';
  String get minutes60 => _zh ? '60 分钟' : '60 minutes';
  String get syncWindowLabel => _zh ? '同步窗口' : 'Sync window';
  String get days7 => _zh ? '7 天' : '7 days';
  String get days30 => _zh ? '30 天' : '30 days';
  String get days90 => _zh ? '90 天' : '90 days';
  String get rulesAutoSaved => _zh
      ? '更改会自动保存，并重新安排定时任务。'
      : 'Changes are saved automatically and the timer reschedules.';

  // About section
  String get aboutSection => _zh ? '关于' : 'About';
  String get checkForUpdates => _zh ? '检查更新' : 'Check for updates';
  String get onLatestVersion =>
      _zh ? '已是最新版本。' : 'You are on the latest version.';
  String newVersionAvailable(String version) =>
      _zh ? '发现新版本 $version' : 'New version $version available';

  // --- Revealable secret field ---
  String get hide => _zh ? '隐藏' : 'Hide';
  String get show => _zh ? '显示' : 'Show';

  // --- Calendar source kinds ---
  String sourceName(CalendarSourceKind kind) => switch (kind) {
        CalendarSourceKind.dingtalk => _zh ? '钉钉' : 'DingTalk',
        CalendarSourceKind.tencent => _zh ? '腾讯会议' : 'Tencent Meeting',
      };

  String sourceSetupHint(CalendarSourceKind kind) => switch (kind) {
        CalendarSourceKind.dingtalk => _zh
            ? '在钉钉中：日历 → 设置 → 开启 CalDAV，然后复制用户名和密码。'
            : 'In DingTalk: Calendar → Settings → enable CalDAV, then copy the username and password.',
        CalendarSourceKind.tencent => _zh
            ? '在腾讯会议中：日历 → CalDAV 订阅，然后复制账号和密码。'
            : 'In Tencent Meeting: Calendar → CalDAV subscription, then copy the account and password.',
      };

  // --- Accounts page ---
  String get navAccounts => _zh ? '账户' : 'Accounts';
  String get accountsTitle => _zh ? '账户' : 'Accounts';
  String get addAccount => _zh ? '添加账户' : 'Add account';
  String get editAccount => _zh ? '编辑账户' : 'Edit account';
  String get newAccount => _zh ? '新建账户' : 'New account';
  String get accountLabel => _zh ? '账户名称' : 'Account name';
  String get accountLabelHint => _zh ? '如：工作钉钉' : 'e.g. Work DingTalk';
  String get accountType => _zh ? '类型' : 'Type';
  String get noAccounts =>
      _zh ? '还没有账户。点「添加账户」开始。' : 'No accounts yet. Click "Add account" to begin.';
  String get save => _zh ? '保存' : 'Save';
  String get cancel => _zh ? '取消' : 'Cancel';
  String get edit => _zh ? '编辑' : 'Edit';
  String get delete => _zh ? '删除' : 'Delete';
  String get deleteAccountTitle => _zh ? '删除账户' : 'Delete account';
  String deleteAccountConfirm(String name) => _zh
      ? '确定删除「$name」？已同步到飞书的日程会保留，仅停止该账户的同步。'
      : 'Delete "$name"? Already-synced Feishu events are kept; only this account stops syncing.';
  String get accountEnabled => _zh ? '已启用' : 'Enabled';
  String get accountDisabled => _zh ? '已停用' : 'Disabled';
}
