import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:share_plus/share_plus.dart';

/// Copy + download utilities for Yve's responses. Cross-platform: on web
/// share_plus triggers a browser download, on mobile it opens the system
/// share sheet so the learner can save anywhere (Files, AirDrop, mail).
class ExportService {
  /// Copy the response text (raw markdown) to the system clipboard.
  Future<void> copyToClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }

  /// Save / share the response as a Markdown file.
  Future<void> shareAsMarkdown({
    required String text,
    required String filename,
  }) async {
    final Uint8List bytes = Uint8List.fromList(utf8.encode(text));
    final XFile file = XFile.fromData(
      bytes,
      name: '$filename.md',
      mimeType: 'text/markdown',
    );
    await Share.shareXFiles(<XFile>[file]);
  }

  /// Save / share the response as a Word-compatible document. We render
  /// the markdown to HTML and ship it with a `.doc` extension — Word
  /// happily opens HTML-as-doc and preserves headings, bold, italic,
  /// lists, links, blockquotes, and inline code. Full Open XML .docx
  /// generation would need a server round-trip and the fidelity gain
  /// isn't worth it for typical assignment-help output.
  Future<void> shareAsWordDoc({
    required String markdownText,
    required String filename,
  }) async {
    final String html = _renderHtml(markdownText);
    final Uint8List bytes = Uint8List.fromList(utf8.encode(html));
    final XFile file = XFile.fromData(
      bytes,
      name: '$filename.doc',
      // Word's MIME for HTML-flavored .doc. application/msword is what
      // makes the OS treat the file as a Word document so it opens in
      // Word rather than a browser.
      mimeType: 'application/msword',
    );
    await Share.shareXFiles(<XFile>[file]);
  }

  /// Markdown → standalone HTML document. The body styles match Yve's
  /// design tokens loosely; Word ignores most CSS but font + base size
  /// give a more polished default than raw HTML defaults.
  String _renderHtml(String markdown) {
    final String body = md.markdownToHtml(
      markdown,
      extensionSet: md.ExtensionSet.gitHubWeb,
    );
    return '''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Yve response</title>
<style>
body { font-family: 'Calibri', 'Segoe UI', sans-serif; font-size: 11pt; line-height: 1.5; color: #1a1a2e; max-width: 720px; }
h1, h2, h3 { color: #1b4332; }
h1 { font-size: 18pt; }
h2 { font-size: 14pt; }
h3 { font-size: 12pt; }
code { font-family: 'Consolas', monospace; background: #f1f3f5; padding: 1px 4px; border-radius: 3px; }
pre { background: #f1f3f5; padding: 10px; border-radius: 6px; overflow-x: auto; }
blockquote { border-left: 3px solid #52b788; margin: 0; padding-left: 12px; color: #6b7280; }
a { color: #1b4332; }
</style>
</head>
<body>
$body
</body>
</html>
''';
  }
}

/// Build a structured filename for an exported Yve artifact. NEVER derives
/// from the AI response text — that produces ChatGPT-flavored filenames like
/// "lets-work-through-every-section.docx" which look unprofessional in a
/// learner's Downloads folder. Components, in priority order:
///
///   Yve_[Subject?]_[Title or ToolLabel]_[Variant?]_[YYYY-MM-DD_HH-mm]
///
/// - [subjectName]   The subject this chat belongs to ("Biology", "Nursing").
/// - [sessionTitle]  The session/assignment title ("Cell Assignment"). When
///                    set, takes precedence over [toolLabel] as the second
///                    segment.
/// - [toolLabel]     What kind of artifact this is, used as the second
///                    segment when no [sessionTitle] is available
///                    ("Polish", "Assignment", "Scan", "Quiz", "Summary").
/// - [variant]       Optional sub-kind appended after subject/title
///                    ("Draft" vs "Analysis" for polish exports).
/// - [at]            Override the timestamp. Defaults to local now.
///
/// All free-form inputs are stripped to word characters + spaces, with
/// spaces collapsed to underscores and capped at ~40 chars each. If subject,
/// title, AND toolLabel are all empty, the file is labelled "Document".
String filenameFor({
  String? subjectName,
  String? sessionTitle,
  String? toolLabel,
  String? variant,
  DateTime? at,
}) {
  final List<String> parts = <String>['Yve'];
  final String? subject = _sanitizeFilenamePart(subjectName);
  final String? title = _sanitizeFilenamePart(sessionTitle);
  final String? tool = _sanitizeFilenamePart(toolLabel);
  final String? variantPart = _sanitizeFilenamePart(variant);

  if (subject != null) parts.add(subject);
  // Title is more specific than toolLabel — prefer it when present.
  if (title != null) {
    parts.add(title);
  } else if (tool != null) {
    parts.add(tool);
  }
  if (variantPart != null) parts.add(variantPart);
  // Last-resort marker when nothing identifying came through.
  if (parts.length == 1) parts.add('Document');

  parts.add(_formatLocalTimestamp(at ?? DateTime.now()));

  String name = parts.join('_');
  // Hard cap so the OS/share-sheet doesn't get angry about absurd lengths.
  if (name.length > 80) name = name.substring(0, 80);
  return name;
}

String? _sanitizeFilenamePart(String? raw) {
  if (raw == null) return null;
  String s = raw.trim();
  if (s.isEmpty) return null;
  // Drop emojis, punctuation, anything not word-char/space/dash.
  s = s
      .replaceAll(RegExp(r'^#{1,6}\s+'), '')
      .replaceAll(RegExp(r'[*_`#]'), '')
      .replaceAll(RegExp(r'[^\w\s-]'), '')
      .replaceAll(RegExp(r'\s+'), '_')
      .replaceAll(RegExp(r'_+'), '_');
  s = s.replaceAll(RegExp(r'^_+|_+$'), '');
  if (s.length > 40) s = s.substring(0, 40).replaceAll(RegExp(r'_+$'), '');
  return s.isEmpty ? null : s;
}

String _formatLocalTimestamp(DateTime t) {
  final DateTime local = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)}'
      '_${two(local.hour)}-${two(local.minute)}';
}
