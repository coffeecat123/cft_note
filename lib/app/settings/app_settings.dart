// lib/app/settings/app_settings.dart
//
// 全域設定 (目前：主題、語言)。
//  - main() 啟動時 load()，讀不到就用預設值
//  - 變更後立即生效 (notifyListeners) 並寫入 cft_app_settings.json
//  - 之後要加新的全域設定，只要在這裡加欄位 + toJson / fromJson 即可
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/i18n/app_strings.dart';
import '../../features/document/data/storage_service.dart';

class AppSettings extends ChangeNotifier {
  ThemeMode _themeMode;
  AppLanguage _language;

  AppSettings({
    this._themeMode = ThemeMode.system,
    this._language = AppLanguage.system,
  }) {
    _syncCurrentStrings();
  }

  ThemeMode get themeMode => _themeMode;
  AppLanguage get language => _language;

  /// 目前生效的字串表 (語言為「跟隨系統」時依系統語系決定)
  S get strings => S.forLanguage(_language);

  void setThemeMode(ThemeMode mode) {
    if (mode == _themeMode) return;
    _themeMode = mode;
    _save();
    notifyListeners();
  }

  void setLanguage(AppLanguage language) {
    if (language == _language) return;
    _language = language;
    _syncCurrentStrings();
    _save();
    notifyListeners();
  }

  /// 系統語言在 App 執行中被改掉 (語言設為「跟隨系統」時) 也要跟上
  void refreshSystemLocale() {
    if (_language != AppLanguage.system) return;
    final before = S.current;
    _syncCurrentStrings();
    if (!identical(before, S.current)) notifyListeners();
  }

  void _syncCurrentStrings() => S.current = strings;

  // ------------------------------------------------------------
  // 存取
  // ------------------------------------------------------------
  Map<String, dynamic> toJson() => {
        'themeMode': _themeMode.name,
        'language': _language.name,
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      themeMode: ThemeMode.values.firstWhere(
        (m) => m.name == json['themeMode'],
        orElse: () => ThemeMode.system,
      ),
      language: AppLanguage.values.firstWhere(
        (l) => l.name == json['language'],
        orElse: () => AppLanguage.system,
      ),
    );
  }

  /// 讀取失敗一律回傳預設值，不影響啟動
  static Future<AppSettings> load() async {
    try {
      final json = await StorageService.loadAppSettings();
      if (json != null) return AppSettings.fromJson(json);
    } catch (e) {
      debugPrint('[AppSettings] 讀取全域設定失敗：$e');
    }
    return AppSettings();
  }

  void _save() => unawaited(StorageService.saveAppSettings(toJson()));
}

/// 把 [AppSettings] 放進 Widget tree：`S.of(context)` 靠它在語言變更時重建畫面
class AppSettingsScope extends InheritedNotifier<AppSettings> {
  const AppSettingsScope({
    super.key,
    required AppSettings settings,
    required super.child,
  }) : super(notifier: settings);

  static AppSettings? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AppSettingsScope>()
      ?.notifier;

  static AppSettings of(BuildContext context) {
    final s = maybeOf(context);
    assert(s != null, 'AppSettingsScope 不在 Widget tree 中');
    return s!;
  }
}
