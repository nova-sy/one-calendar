import 'package:flutter/widgets.dart';

import '../storage/state_store.dart';
import 'app_strings.dart';

/// Holds the active [AppLanguage], persists it, and notifies listeners on
/// change so the whole [MaterialApp] can rebuild.
class LocaleController extends ChangeNotifier {
  static const _prefKey = 'language';

  final StateStore _store;
  AppLanguage _language;

  LocaleController(this._store)
      : _language = AppLanguage.fromCode(_store.getPreference(_prefKey));

  AppLanguage get language => _language;

  AppStrings get strings => AppStrings.of(_language);

  Locale get locale => Locale(_language.localeCode);

  void setLanguage(AppLanguage language) {
    if (language == _language) return;
    _language = language;
    _store.setPreference(_prefKey, language.localeCode);
    notifyListeners();
  }
}

/// Exposes the [LocaleController] (and resolved [AppStrings]) to the widget
/// tree. Rebuilds dependents when the language changes.
class LocaleScope extends InheritedNotifier<LocaleController> {
  const LocaleScope({
    super.key,
    required LocaleController controller,
    required super.child,
  }) : super(notifier: controller);

  static LocaleController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<LocaleScope>();
    assert(scope?.notifier != null, 'No LocaleScope found in context');
    return scope!.notifier!;
  }
}

/// Convenience accessors so widgets can call `context.strings` / `context.locale`.
extension LocaleScopeX on BuildContext {
  AppStrings get strings => LocaleScope.of(this).strings;
  LocaleController get localeController => LocaleScope.of(this);
}
