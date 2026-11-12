// lib/app/settings/settings_dialog.dart
//
// 全域設定視窗 (書架頁右上角的齒輪)。
// 目前有：主題 (跟隨系統 / 淺色 / 深色)、語言 (跟隨系統 / 繁體中文 / English)。
// 之後要加新設定：在 AppSettings 加欄位，然後在 [_SettingsBody] 多放一個 _Section 即可。
import 'package:flutter/material.dart';

import '../../core/i18n/app_strings.dart';
import '../theme/app_theme.dart';
import 'app_settings.dart';

class SettingsDialog extends StatelessWidget {
  const SettingsDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (_) => const SettingsDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context); // 語言切換時，這個視窗本身也會立刻換語言
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          const Icon(Icons.settings_outlined, size: 22),
          const SizedBox(width: 8),
          Text(
            s.settings,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ],
      ),
      content: const SizedBox(
        width: 380,
        child: SingleChildScrollView(child: _SettingsBody()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(s.close),
        ),
      ],
    );
  }
}

class _SettingsBody extends StatelessWidget {
  const _SettingsBody();

  @override
  Widget build(BuildContext context) {
    final settings = AppSettingsScope.of(context);
    final s = S.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Section(
          title: s.theme,
          child: SegmentedButton<ThemeMode>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: ThemeMode.system,
                icon: const Icon(Icons.brightness_auto_outlined, size: 18),
                label: Text(s.themeSystem, maxLines: 1),
              ),
              ButtonSegment(
                value: ThemeMode.light,
                icon: const Icon(Icons.light_mode_outlined, size: 18),
                label: Text(s.themeLight, maxLines: 1),
              ),
              ButtonSegment(
                value: ThemeMode.dark,
                icon: const Icon(Icons.dark_mode_outlined, size: 18),
                label: Text(s.themeDark, maxLines: 1),
              ),
            ],
            selected: {settings.themeMode},
            onSelectionChanged: (v) => settings.setThemeMode(v.first),
          ),
        ),
        const SizedBox(height: 20),
        _Section(
          title: s.language,
          child: SegmentedButton<AppLanguage>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: AppLanguage.system,
                label: Text(s.languageSystem, maxLines: 1),
              ),
              ButtonSegment(
                value: AppLanguage.zhTW,
                label: Text(s.languageZhTw, maxLines: 1),
              ),
              ButtonSegment(
                value: AppLanguage.en,
                label: Text(s.languageEn, maxLines: 1),
              ),
            ],
            selected: {settings.language},
            onSelectionChanged: (v) => settings.setLanguage(v.first),
          ),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget child;
  const _Section({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: context.cs.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(width: double.infinity, child: child),
      ],
    );
  }
}
