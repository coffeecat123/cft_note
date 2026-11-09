// lib/features/canvas/presentation/widgets/screenshot_sheet.dart
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../pdf_import_export/services/image_export_service.dart';

/// 截圖完成後的底部面板：預覽 + 複製 / 分享 / 存到相簿 / 儲存檔案
class ScreenshotSheet extends StatefulWidget {
  final Uint8List png;
  final String fileName;

  const ScreenshotSheet({super.key, required this.png, required this.fileName});

  static Future<void> show(
    BuildContext context, {
    required Uint8List png,
    required String fileName,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ScreenshotSheet(png: png, fileName: fileName),
    );
  }

  @override
  State<ScreenshotSheet> createState() => _ScreenshotSheetState();
}

class _ScreenshotSheetState extends State<ScreenshotSheet> {
  bool _busy = false;

  /// 統一處理：忙碌狀態、錯誤提示、成功後關閉面板
  Future<void> _run(
    Future<bool> Function() action, {
    String? successMessage,
    bool closeOnSuccess = true,
  }) async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _busy = true);
    try {
      final ok = await action();
      if (!mounted) return;
      if (ok) {
        if (successMessage != null) {
          messenger.showSnackBar(SnackBar(content: Text(successMessage)));
        }
        if (closeOnSuccess) navigator.pop();
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('操作失敗：$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Rect? _originOf(BuildContext btnContext) {
    final box = btnContext.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  Widget build(BuildContext context) {
    final maxPreviewH = MediaQuery.of(context).size.height * 0.4;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── 1. 補回：圖片預覽區塊 ───────────────────
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxPreviewH),
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F3F6),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                padding: const EdgeInsets.all(8),
                child: Image.memory(widget.png, fit: BoxFit.contain),
              ),
            ),
            const SizedBox(height: 16),

            // ── 2. 自動縮排的按鈕列 ─────────────────────
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Row(
                  children: [
                    if (ImageExportService.canCopyImage)
                      Expanded(
                        child: _action(
                          Icons.copy_rounded,
                          '複製',
                          () => _run(
                            () => ImageExportService.copyPngToClipboard(
                              widget.png,
                            ),
                            successMessage: '已複製圖片到剪貼簿',
                            closeOnSuccess: true,
                          ),
                        ),
                      ),
                    Expanded(
                      child: Builder(
                        builder: (btnCtx) => _action(
                          Icons.ios_share,
                          '分享',
                          () => _run(() async {
                            await ImageExportService.sharePng(
                              widget.png,
                              widget.fileName,
                              origin: _originOf(btnCtx),
                            );
                            return true;
                          }),
                        ),
                      ),
                    ),
                    if (ImageExportService.canSaveToGallery)
                      Expanded(
                        child: _action(
                          Icons.photo_library_outlined,
                          '存到相簿',
                          () => _run(
                            () async {
                              final ok = await ImageExportService.saveToGallery(
                                widget.png,
                                widget.fileName,
                              );
                              if (!ok && mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('沒有相簿存取權限，請到系統設定開啟'),
                                  ),
                                );
                              }
                              return ok;
                            },
                            successMessage: '已存到相簿',
                            closeOnSuccess: true,
                          ),
                        ),
                      ),
                    Expanded(
                      child: _action(
                        Icons.save_alt,
                        '儲存檔案',
                        () => _run(
                          () => ImageExportService.savePng(
                            widget.png,
                            widget.fileName,
                          ),
                          successMessage: '截圖已儲存',
                          closeOnSuccess: true,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ── 3. 補回：忙碌處理時的進度條 ─────────────
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(minHeight: 2),
              ),
          ],
        ),
      ),
    );
  }

  Widget _action(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: _busy ? null : onTap,
      child: Padding(
        // 將 horizontal 拿掉（或設為最小 2~4），只保留 vertical 內距
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: Colors.blue.withAlpha(25),
              child: Icon(icon, color: Colors.blueAccent),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: const TextStyle(fontSize: 12),
              maxLines: 1, // 避免小螢幕折行
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
