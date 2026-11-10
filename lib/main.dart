// lib/main.dart
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';

import 'features/canvas/domain/models/canvas_prefs.dart';
import 'features/document/data/storage_service.dart';
import 'features/shelf/presentation/widgets/shelf_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // ★ 還原上次的畫筆 / 顏色 / 頁面顯示方式；讀不到就用預設值，不影響啟動
  try {
    final json = await StorageService.loadCanvasPrefs();
    if (json != null) CanvasPrefs.initial = CanvasPrefs.fromJson(json);
  } catch (e) {
    debugPrint('[main] 讀取畫布設定失敗：$e');
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'CFT Note',
      theme: ThemeData(
        useMaterial3: true,
        primarySwatch: Colors.blue,
      ),
      home: const ShelfPage(), // ★ 首頁進入筆記櫃！
    );
  }
}