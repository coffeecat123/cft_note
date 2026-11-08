// lib/main.dart
import 'package:flutter/material.dart';
import 'features/shelf/presentation/widgets/shelf_page.dart';

void main() {
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