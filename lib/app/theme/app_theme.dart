// lib/app/theme/app_theme.dart
//
// 淺色 / 深色主題。
//  - 通用顏色 (背景、文字、分隔線…) 一律用 Theme.of(context).colorScheme
//  - 這個 App 特有的顏色 (標籤列、工作桌、資料夾卡片…) 放在 [AppColors]，
//    用 `context.appColors` 取得，淺 / 深各一組。
import 'package:flutter/material.dart';

@immutable
class AppColors extends ThemeExtension<AppColors> {
  /// 書架頁面底色
  final Color shelfBackground;

  /// 畫布頁：頂部標籤列底色 / 未選取標籤 / 工具列
  final Color tabBar;
  final Color tabInactive;
  final Color toolbar;
  final Color toolbarIcon;

  /// 畫布頁：紙張以外的「工作桌」底色
  final Color workspace;

  /// 書架資料夾卡片
  final Color folderCard;
  final Color folderCardBorder;

  /// 拖曳時頂端「移到上一層」的放置區
  final Color moveUpBanner;

  const AppColors({
    required this.shelfBackground,
    required this.tabBar,
    required this.tabInactive,
    required this.toolbar,
    required this.toolbarIcon,
    required this.workspace,
    required this.folderCard,
    required this.folderCardBorder,
    required this.moveUpBanner,
  });

  static const light = AppColors(
    shelfBackground: Color(0xFFF7F8FA),
    tabBar: Color(0xFFE9ECEF),
    tabInactive: Color(0xFFDFE3E6),
    toolbar: Colors.white,
    toolbarIcon: Color(0xFF616161), // grey[700]
    workspace: Color(0xFF1E1E1E),
    folderCard: Color(0xFFE8F0FE),
    folderCardBorder: Color(0xFFD2E3FC),
    moveUpBanner: Color(0xFFE3EDFF),
  );

  static const dark = AppColors(
    shelfBackground: Color(0xFF121316),
    tabBar: Color(0xFF17181B),
    tabInactive: Color(0xFF24262A),
    toolbar: Color(0xFF2B2D31),
    toolbarIcon: Color(0xFFBDC1C6),
    workspace: Color(0xFF0E0E10),
    folderCard: Color(0xFF1F2B40),
    folderCardBorder: Color(0xFF2D4263),
    moveUpBanner: Color(0xFF1C2A44),
  );

  @override
  AppColors copyWith({
    Color? shelfBackground,
    Color? tabBar,
    Color? tabInactive,
    Color? toolbar,
    Color? toolbarIcon,
    Color? workspace,
    Color? folderCard,
    Color? folderCardBorder,
    Color? moveUpBanner,
  }) {
    return AppColors(
      shelfBackground: shelfBackground ?? this.shelfBackground,
      tabBar: tabBar ?? this.tabBar,
      tabInactive: tabInactive ?? this.tabInactive,
      toolbar: toolbar ?? this.toolbar,
      toolbarIcon: toolbarIcon ?? this.toolbarIcon,
      workspace: workspace ?? this.workspace,
      folderCard: folderCard ?? this.folderCard,
      folderCardBorder: folderCardBorder ?? this.folderCardBorder,
      moveUpBanner: moveUpBanner ?? this.moveUpBanner,
    );
  }

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    return AppColors(
      shelfBackground: Color.lerp(shelfBackground, other.shelfBackground, t)!,
      tabBar: Color.lerp(tabBar, other.tabBar, t)!,
      tabInactive: Color.lerp(tabInactive, other.tabInactive, t)!,
      toolbar: Color.lerp(toolbar, other.toolbar, t)!,
      toolbarIcon: Color.lerp(toolbarIcon, other.toolbarIcon, t)!,
      workspace: Color.lerp(workspace, other.workspace, t)!,
      folderCard: Color.lerp(folderCard, other.folderCard, t)!,
      folderCardBorder:
          Color.lerp(folderCardBorder, other.folderCardBorder, t)!,
      moveUpBanner: Color.lerp(moveUpBanner, other.moveUpBanner, t)!,
    );
  }
}

class AppTheme {
  AppTheme._();

  /// 淺色：維持原本外觀 (Material 3 + 藍色)
  static ThemeData get light => ThemeData(
        useMaterial3: true,
        primarySwatch: Colors.blue,
        extensions: const [AppColors.light],
      );

  /// 深色
  static ThemeData get dark => ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
        extensions: const [AppColors.dark],
      );
}

extension AppThemeContext on BuildContext {
  ColorScheme get cs => Theme.of(this).colorScheme;
  AppColors get appColors =>
      Theme.of(this).extension<AppColors>() ?? AppColors.light;
  bool get isDarkTheme => Theme.of(this).brightness == Brightness.dark;
}
