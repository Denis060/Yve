import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/material_item.dart';
import '../theme/yve_colors.dart';
import '../theme/yve_spacing.dart';
import '../utils/app_error.dart';

class AddMaterialResult {
  const AddMaterialResult({
    required this.kind,
    this.name,
    this.content,
    this.url,
    this.pdfBytes,
    this.docxBytes,
  });

  final MaterialKind kind;
  final String? name;
  final String? content;
  final String? url;
  final Uint8List? pdfBytes;
  final Uint8List? docxBytes;
}

/// Bottom sheet for adding a material to a subject. Note, URL, and PDF
/// ingest are fully wired. Camera capture lives on the Scan tab — pointing
/// here keeps the materials sheet focused on library additions rather than
/// duplicating the magical scan flow.
Future<AddMaterialResult?> showAddMaterialSheet(BuildContext context) {
  return showModalBottomSheet<AddMaterialResult>(
    context: context,
    isScrollControlled: true,
    showDragHandle: false,
    builder: (_) => const _AddMaterialSheet(),
  );
}

class _AddMaterialSheet extends StatefulWidget {
  const _AddMaterialSheet();

  @override
  State<_AddMaterialSheet> createState() => _AddMaterialSheetState();
}

class _AddMaterialSheetState extends State<_AddMaterialSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this);
  final TextEditingController _noteCtrl = TextEditingController();
  final TextEditingController _noteNameCtrl = TextEditingController();
  final TextEditingController _urlCtrl = TextEditingController();

  @override
  void dispose() {
    _tabs.dispose();
    _noteCtrl.dispose();
    _noteNameCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final EdgeInsets viewInsets = MediaQuery.of(context).viewInsets;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 120),
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: SafeArea(
        child: Container(
          decoration: const BoxDecoration(
            color: YveColors.surface,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(28),
              topRight: Radius.circular(28),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(
            YveSpacing.xl,
            YveSpacing.md,
            YveSpacing.xl,
            YveSpacing.xl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: YveColors.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: YveSpacing.md),
              Text(
                'Add material',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 2),
              const Text(
                'Yve will index it so you can ask grounded questions later.',
                style: TextStyle(fontSize: 13, color: YveColors.textSecondary),
              ),
              const SizedBox(height: YveSpacing.md),
              TabBar(
                controller: _tabs,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                indicatorColor: YveColors.primary,
                labelColor: YveColors.primary,
                unselectedLabelColor: YveColors.textTertiary,
                labelStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
                tabs: const <Widget>[
                  Tab(text: 'Note'),
                  Tab(text: 'URL'),
                  Tab(text: 'File'),
                  Tab(text: 'Camera'),
                ],
              ),
              SizedBox(
                height: 280,
                child: TabBarView(
                  controller: _tabs,
                  children: <Widget>[
                    _NoteTab(
                      contentCtrl: _noteCtrl,
                      nameCtrl: _noteNameCtrl,
                      onSubmit: _submitNote,
                    ),
                    _UrlTab(
                      urlCtrl: _urlCtrl,
                      onSubmit: _submitUrl,
                    ),
                    _FileTab(onSubmit: _submitPdf),
                    const _ComingSoonTab(
                      icon: Icons.camera_alt_rounded,
                      title: 'Camera capture',
                      body:
                          'Use the Scan tab (center of the bottom bar) for camera capture — it lands in a chat with the action ladder.',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _submitNote() {
    final String body = _noteCtrl.text.trim();
    if (body.isEmpty) return;
    HapticFeedback.lightImpact();
    Navigator.of(context).pop(
      AddMaterialResult(
        kind: MaterialKind.note,
        name: _noteNameCtrl.text.trim().isEmpty
            ? null
            : _noteNameCtrl.text.trim(),
        content: body,
      ),
    );
  }

  void _submitUrl() {
    final String url = _urlCtrl.text.trim();
    if (url.isEmpty) return;
    HapticFeedback.lightImpact();
    Navigator.of(context).pop(
      AddMaterialResult(kind: MaterialKind.url, url: url),
    );
  }

  void _submitPdf(AddMaterialResult result) {
    HapticFeedback.lightImpact();
    Navigator.of(context).pop(result);
  }
}

class _NoteTab extends StatelessWidget {
  const _NoteTab({
    required this.contentCtrl,
    required this.nameCtrl,
    required this.onSubmit,
  });

  final TextEditingController contentCtrl;
  final TextEditingController nameCtrl;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: YveSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TextField(
            controller: nameCtrl,
            decoration: const InputDecoration(
              hintText: 'Title (optional)',
            ),
          ),
          const SizedBox(height: YveSpacing.sm),
          Expanded(
            child: TextField(
              controller: contentCtrl,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              decoration: const InputDecoration(
                hintText: 'Paste lecture notes, definitions, anything…',
              ),
            ),
          ),
          const SizedBox(height: YveSpacing.sm),
          FilledButton.icon(
            onPressed: onSubmit,
            icon: const Icon(Icons.bolt_rounded),
            label: const Text('Save & index'),
          ),
        ],
      ),
    );
  }
}

class _UrlTab extends StatelessWidget {
  const _UrlTab({required this.urlCtrl, required this.onSubmit});

  final TextEditingController urlCtrl;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: YveSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TextField(
            controller: urlCtrl,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              hintText: 'https://...',
            ),
          ),
          const SizedBox(height: YveSpacing.sm),
          const Text(
            'Yve will fetch the page, strip the chrome, and index the body text.',
            style: TextStyle(fontSize: 12, color: YveColors.textSecondary),
          ),
          const Spacer(),
          FilledButton.icon(
            onPressed: onSubmit,
            icon: const Icon(Icons.link_rounded),
            label: const Text('Fetch & index'),
          ),
        ],
      ),
    );
  }
}

class _FileTab extends StatefulWidget {
  const _FileTab({required this.onSubmit});
  final ValueChanged<AddMaterialResult> onSubmit;

  @override
  State<_FileTab> createState() => _FileTabState();
}

class _FileTabState extends State<_FileTab> {
  bool _picking = false;
  String? _fileName;
  int? _fileSize;
  Uint8List? _bytes;
  bool _isDocx = false;
  String? _error;

  // Anthropic's limit is 32 MB; we cap a little lower so the base64 payload
  // stays under the Edge Function's request budget.
  static const int _maxBytes = 25 * 1024 * 1024;

  Future<void> _pick() async {
    setState(() {
      _picking = true;
      _error = null;
    });
    try {
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const <String>['pdf', 'docx'],
        withData: true,
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) {
        return; // user cancelled
      }
      final PlatformFile file = result.files.first;
      if (file.bytes == null) {
        setState(() {
          _error = 'Couldn\'t read the file. Try a different one.';
        });
        return;
      }
      if (file.bytes!.lengthInBytes > _maxBytes) {
        setState(() {
          _error =
              'That file is over 25 MB. Try a smaller one (single chapters work best).';
        });
        return;
      }
      final bool isDocx = file.name.toLowerCase().endsWith('.docx');
      setState(() {
        _fileName = file.name;
        _fileSize = file.bytes!.lengthInBytes;
        _bytes = file.bytes;
        _isDocx = isDocx;
      });
    } catch (e) {
      setState(() => _error =
          AppError.from(e, actionContext: 'file_pick').userMessage);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _submit() {
    final Uint8List? bytes = _bytes;
    if (bytes == null) return;
    widget.onSubmit(AddMaterialResult(
      kind: _isDocx ? MaterialKind.doc : MaterialKind.pdf,
      name: _fileName,
      pdfBytes: _isDocx ? null : bytes,
      docxBytes: _isDocx ? bytes : null,
    ));
  }

  String _humanSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: YveSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (_bytes == null) ...<Widget>[
            OutlinedButton.icon(
              onPressed: _picking ? null : _pick,
              icon: _picking
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: YveColors.primary,
                      ),
                    )
                  : const Icon(Icons.upload_file_rounded),
              label: Text(_picking ? 'Opening picker…' : 'Choose a PDF or .docx'),
            ),
            const SizedBox(height: YveSpacing.sm),
            const Text(
              'Up to 25 MB. Yve reads the file, extracts the text, and indexes it for retrieval.',
              style: TextStyle(fontSize: 12, color: YveColors.textSecondary),
            ),
          ] else ...<Widget>[
            Container(
              padding: const EdgeInsets.all(YveSpacing.md),
              decoration: BoxDecoration(
                color: _isDocx ? YveColors.tintBlue : YveColors.tintRed,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: <Widget>[
                  Icon(
                    _isDocx
                        ? Icons.description_rounded
                        : Icons.picture_as_pdf_rounded,
                    color: YveColors.textPrimary,
                  ),
                  const SizedBox(width: YveSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          _fileName ?? (_isDocx ? 'Word document' : 'PDF'),
                          style: text.titleSmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (_fileSize != null)
                          Text(
                            _humanSize(_fileSize!),
                            style: const TextStyle(
                              fontSize: 12,
                              color: YveColors.textSecondary,
                            ),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () => setState(() {
                      _bytes = null;
                      _fileName = null;
                      _fileSize = null;
                      _isDocx = false;
                    }),
                  ),
                ],
              ),
            ),
          ],
          if (_error != null) ...<Widget>[
            const SizedBox(height: YveSpacing.sm),
            Text(
              _error!,
              style: const TextStyle(fontSize: 12, color: YveColors.error),
            ),
          ],
          const Spacer(),
          if (_bytes != null)
            FilledButton.icon(
              onPressed: _submit,
              icon: const Icon(Icons.bolt_rounded),
              label: Text(_isDocx ? 'Index this document' : 'Index this PDF'),
            ),
        ],
      ),
    );
  }
}

class _ComingSoonTab extends StatelessWidget {
  const _ComingSoonTab({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: YveSpacing.md,
        vertical: YveSpacing.xl,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(icon, size: 40, color: YveColors.textTertiary),
          const SizedBox(height: YveSpacing.md),
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            body,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 13,
              color: YveColors.textSecondary,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}
