// lib/features/shelf/presentation/widgets/shelf_list_row.dart
import 'package:flutter/material.dart';

/// 精簡清單模式 (類似檔案總管「詳細資料」) 的一列。
/// 欄位寬度用常數共用，讓標題列與每一列對得整齊。
class ShelfListRow extends StatelessWidget {
  static const double iconWidth = 44;
  static const double modifiedWidth = 140;
  static const double infoWidth = 96;
  static const double menuWidth = 40;
  static const double rowHeight = 46;

  final Widget leading;
  final String name;
  final String modifiedText;
  final String infoText;
  final bool showInfo;
  final VoidCallback onTap;
  final Widget trailing; // 通常是「更多」選單

  const ShelfListRow({
    super.key,
    required this.leading,
    required this.name,
    required this.modifiedText,
    required this.infoText,
    required this.showInfo,
    required this.onTap,
    required this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final subStyle = TextStyle(fontSize: 12, color: Colors.grey[600]);
    return Material(
      color: Colors.white,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: rowHeight,
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
          ),
          child: Row(
            children: [
              SizedBox(width: iconWidth, child: Center(child: leading)),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Colors.black87,
                  ),
                ),
              ),
              SizedBox(
                width: modifiedWidth,
                child: Text(modifiedText, maxLines: 1, style: subStyle),
              ),
              if (showInfo)
                SizedBox(
                  width: infoWidth,
                  child: Text(infoText, maxLines: 1, style: subStyle),
                ),
              SizedBox(width: menuWidth, child: Center(child: trailing)),
            ],
          ),
        ),
      ),
    );
  }
}
