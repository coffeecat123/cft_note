// lib/main.dart
import 'package:flutter/material.dart';

import 'app/settings/app_settings.dart';
import 'app/theme/app_theme.dart';
import 'core/i18n/app_strings.dart';
import 'features/canvas/domain/models/canvas_prefs.dart';
import 'features/document/data/storage_service.dart';
import 'features/shelf/presentation/widgets/shelf_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // ★ 全域設定 (主題 / 語言)：讀不到就用預設值 (跟隨系統)，不影響啟動
  final settings = await AppSettings.load();
  // ★ 還原上次的畫筆 / 顏色 / 頁面顯示方式 / 空白頁背景；讀不到就用預設值，不影響啟動
  try {
    final json = await StorageService.loadCanvasPrefs();
    if (json != null) CanvasPrefs.initial = CanvasPrefs.fromJson(json);
  } catch (e) {
    debugPrint('[main] 讀取畫布設定失敗：$e');
  }
  runApp(MyApp(settings: settings));
}

class MyApp extends StatefulWidget {
  final AppSettings settings;
  const MyApp({super.key, required this.settings});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 語言設為「跟隨系統」時，系統語言改變要立刻跟上
  @override
  void didChangeLocales(List<Locale>? locales) {
    widget.settings.refreshSystemLocale();
  }

  @override
  Widget build(BuildContext context) {
    return AppSettingsScope(
      settings: widget.settings,
      child: ListenableBuilder(
        listenable: widget.settings,
        builder: (context, _) => MaterialApp(
          debugShowCheckedModeBanner: false,
          onGenerateTitle: (ctx) => S.of(ctx).appTitle,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: widget.settings.themeMode,
          home: const ShelfPage(), // ★ 首頁進入筆記櫃！
        ),
      ),
    );
  }
}
