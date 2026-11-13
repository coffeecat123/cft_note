// lib/app/settings/app_info.dart
//
// 「App 資訊」視窗 (設定視窗裡語言選項下方的按鈕會開啟它)：版本 + GitHub 連結。
// 版本號由 package_info_plus 在執行時讀取 (來源是 pubspec.yaml 的 `version: x.y.z+n`)。
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/i18n/app_strings.dart';
import '../theme/app_theme.dart';

class AppInfo {
  AppInfo._();

  static const String githubUrl = 'https://github.com/coffeecat123/cft_note';
  static const String githubLabel = 'github.com/coffeecat123/cft_note';
}

class AppInfoDialog extends StatefulWidget {
  const AppInfoDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (_) => const AppInfoDialog(),
    );
  }

  @override
  State<AppInfoDialog> createState() => _AppInfoDialogState();
}

class _AppInfoDialogState extends State<AppInfoDialog> {
  late final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();

  /// 用系統瀏覽器開啟；開不了就略過，不影響視窗
  Future<void> _openGithub() async {
    try {
      await launchUrl(
        Uri.parse(AppInfo.githubUrl),
        mode: LaunchMode.externalApplication,
      );
    } catch (e) {
      debugPrint('[AppInfo] 無法開啟 GitHub：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final cs = context.cs;

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          const Icon(Icons.info_outline, size: 22),
          const SizedBox(width: 8),
          Text(
            s.appInfo,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ],
      ),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 讀取失敗或尚未讀完時顯示 "—"
            FutureBuilder<PackageInfo>(
              future: _packageInfo,
              builder: (context, snap) => _InfoRow(
                label: s.appVersion,
                child: Text(
                  snap.data?.version ?? '—',
                  style: const TextStyle(fontSize: 14),
                ),
              ),
            ),
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: _openGithub,
              child: _InfoRow(
                label: 'GitHub',
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        AppInfo.githubLabel,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14, color: cs.primary),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.open_in_new, size: 14, color: cs.primary),
                  ],
                ),
              ),
            ),
          ],
        ),
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

class _InfoRow extends StatelessWidget {
  final String label;
  final Widget child;
  const _InfoRow({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant),
          ),
          const SizedBox(width: 16),
          Flexible(child: child),
        ],
      ),
    );
  }
}