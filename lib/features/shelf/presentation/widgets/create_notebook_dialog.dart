// lib/features/shelf/presentation/widgets/create_notebook_dialog.dart
import 'package:flutter/material.dart';
import '../../../../app/theme/app_theme.dart';
import '../../../../core/i18n/app_strings.dart';
import '../../domain/models/notebook.dart';

class CreateNotebookDialog extends StatefulWidget {
  final ValueChanged<({String title, Color color})> onCreate;
  const CreateNotebookDialog({super.key, required this.onCreate});

  @override
  State<CreateNotebookDialog> createState() => _CreateNotebookDialogState();
}

class _CreateNotebookDialogState extends State<CreateNotebookDialog> {
  final TextEditingController _titleController = TextEditingController();
  Color _selectedColor = Notebook.presetCoverColors.first;

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(s.newNotebook, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 標題輸入框
            TextField(
              controller: _titleController,
              autofocus: true,
              decoration: InputDecoration(
                labelText: s.notebookName,
                hintText: s.untitledNotebook,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 20),

            // 封面顏色挑選
            Text(s.chooseCoverColor, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: context.cs.onSurface)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 10,
              children: Notebook.presetCoverColors.map((color) {
                final isSelected = _selectedColor == color;
                return GestureDetector(
                  onTap: () => setState(() => _selectedColor = color),
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isSelected ? Colors.blueAccent : context.cs.outlineVariant,
                        width: isSelected ? 3 : 1.5,
                      ),
                    ),
                    child: isSelected ? const Icon(Icons.check, size: 18, color: Colors.white) : null,
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(s.cancel, style: const TextStyle(color: Colors.grey)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.blueAccent,
            foregroundColor: Colors.white,
            elevation: 0,
          ),
          onPressed: () {
            widget.onCreate((
              title: _titleController.text,
              color: _selectedColor,
            ));
            Navigator.pop(context);
          },
          child: Text(s.create),
        ),
      ],
    );
  }
}