import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/export_service.dart';
import '../theme/yve_colors.dart';
import '../theme/yve_spacing.dart';
import '../utils/app_error.dart';
import '../utils/auth_gate.dart';

/// "..." menu rendered next to the speaker icon on completed Yve bubbles.
/// Opens a short sheet with Copy / Save as Markdown / Save as Word.
///
/// On web each "Save" triggers a browser download. On mobile they route
/// through the system share sheet so the learner can drop the file into
/// Files, AirDrop, mail, etc.
///
/// [subjectName], [sessionTitle], and [toolLabel] feed the structured
/// filename builder — see [filenameFor]. They're optional so existing
/// callsites without subject context still work; the filename falls back
/// to the mode/tool label or "Document".
class ResponseActionsMenu extends ConsumerWidget {
  const ResponseActionsMenu({
    super.key,
    required this.text,
    this.subjectName,
    this.sessionTitle,
    this.toolLabel,
  });

  final String text;
  final String? subjectName;
  final String? sessionTitle;
  final String? toolLabel;

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    HapticFeedback.selectionClick();
    final ExportService svc = ExportService();
    final String name = filenameFor(
      subjectName: subjectName,
      sessionTitle: sessionTitle,
      toolLabel: toolLabel,
    );

    await showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext sheetCtx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const SizedBox(height: YveSpacing.sm),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: YveColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: YveSpacing.md),
              ListTile(
                leading: const Icon(Icons.copy_rounded,
                    color: YveColors.primary),
                title: const Text('Copy'),
                subtitle: const Text('Markdown source to clipboard'),
                onTap: () async {
                  Navigator.of(sheetCtx).pop();
                  await svc.copyToClipboard(text);
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Copied to clipboard.')),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.description_rounded,
                    color: YveColors.primary),
                title: const Text('Save as Word'),
                subtitle: const Text('Opens in Microsoft Word'),
                onTap: () async {
                  Navigator.of(sheetCtx).pop();
                  if (!context.mounted) return;
                  await runIfAuthed(
                    context, ref,
                    gateTitle: 'Save your work to Yve',
                    gateBody:
                        'Word exports save your work outside Yve. Create a free account to keep your work safe across devices.',
                    action: () async {
                      try {
                        await svc.shareAsWordDoc(
                          markdownText: text,
                          filename: name,
                        );
                      } catch (e) {
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              AppError.from(e, actionContext: 'export').userMessage,
                            ),
                          ),
                        );
                      }
                    },
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.text_snippet_rounded,
                    color: YveColors.primary),
                title: const Text('Save as Markdown'),
                subtitle: const Text('Plain .md file'),
                onTap: () async {
                  Navigator.of(sheetCtx).pop();
                  if (!context.mounted) return;
                  await runIfAuthed(
                    context, ref,
                    gateTitle: 'Save your work to Yve',
                    gateBody:
                        'Markdown exports save your work outside Yve. Create a free account to keep your work safe across devices.',
                    action: () async {
                      try {
                        await svc.shareAsMarkdown(text: text, filename: name);
                      } catch (e) {
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              AppError.from(e, actionContext: 'export').userMessage,
                            ),
                          ),
                        );
                      }
                    },
                  );
                },
              ),
              const SizedBox(height: YveSpacing.md),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return InkWell(
      onTap: () => _open(context, ref),
      borderRadius: BorderRadius.circular(8),
      child: const Padding(
        padding: EdgeInsets.all(4),
        child: Icon(
          Icons.more_horiz_rounded,
          size: 16,
          color: YveColors.textSecondary,
        ),
      ),
    );
  }
}
