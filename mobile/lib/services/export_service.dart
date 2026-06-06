import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

  /// Save / share the response as a real Microsoft Word `.docx`
  /// document with native OMML (Office Math Markup Language) equations.
  ///
  /// Math handling: `$$...$$` and inline `$...$` LaTeX are converted
  /// server-side by the `export-docx` Edge Function into native Word
  /// equation objects. The result equations are vector-scaled,
  /// clickable (Word's equation editor opens on double-click), and
  /// survive round-trips through Word, Google Docs, and Pages without
  /// turning into raster screenshots.
  ///
  /// If the server-side conversion fails for any reason (network,
  /// 5xx, etc.) we fall back to the legacy HTML-as-doc path with
  /// CodeCogs PNG images so the user always gets *something*.
  Future<void> shareAsWordDoc({
    required String markdownText,
    required String filename,
  }) async {
    try {
      final FunctionResponse res = await Supabase.instance.client.functions
          .invoke(
        'export-docx',
        body: <String, String>{
          'markdown': markdownText,
          'title': filename,
        },
      );
      if (res.status == 200 && res.data is List<int>) {
        final Uint8List bytes = Uint8List.fromList(res.data as List<int>);
        final XFile file = XFile.fromData(
          bytes,
          name: '$filename.docx',
          mimeType:
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        );
        await Share.shareXFiles(<XFile>[file]);
        return;
      }
    } catch (_) {
      // Fall through to the legacy HTML path.
    }
    // Legacy fallback: HTML-as-doc with CodeCogs PNG math. Lower
    // fidelity but always works as long as the device has a browser
    // engine to render the share preview.
    final String html = _renderHtml(markdownText);
    final Uint8List bytes = Uint8List.fromList(utf8.encode(html));
    final XFile file = XFile.fromData(
      bytes,
      name: '$filename.doc',
      mimeType: 'application/msword',
    );
    await Share.shareXFiles(<XFile>[file]);
  }

  /// Markdown → standalone HTML document tuned for Word/Google Docs
  /// import. The output is designed to LOAD like a printable academic
  /// document, not a mobile web page:
  ///
  ///   • `@page` rules so Word treats the file as Letter-sized with
  ///     margins (not as a giant continuous web canvas).
  ///   • Calibri 11pt body, line-height 1.5 — matches Word's default
  ///     document so the import doesn't need re-styling.
  ///   • Math `<img>` tags use HTML width/height attributes (not just
  ///     CSS) because Word's HTML parser respects attributes more
  ///     reliably than inline styles, and respects neither very well
  ///     for display math (the historical "giant equation floating in
  ///     the center" bug).
  ///   • Inline math is locked to 18px tall (~1 line of 11pt text) so
  ///     it sits on the baseline instead of inflating row height.
  ///   • Display math is bounded by max-height: 80px so a one-line
  ///     formula doesn't render as a 200px banner.
  String _renderHtml(String markdown) {
    final String mathProcessed = _replaceMathWithImages(markdown);
    final String body = md.markdownToHtml(
      mathProcessed,
      extensionSet: md.ExtensionSet.gitHubWeb,
    );
    return '''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Yve response</title>
<style>
  /* @page makes Word treat this as a paginated Letter document, not a
     continuous-scroll webpage. 1-inch margins all around match the
     academic-paper default. */
  @page { size: 8.5in 11in; margin: 1in; }

  body {
    font-family: Calibri, 'Segoe UI', Arial, sans-serif;
    font-size: 11pt;
    line-height: 1.5;
    color: #111;
    /* Removed max-width entirely — let Word handle page width via @page.
       The web cap was leaking into the document as a 720px column. */
  }

  p { margin: 0 0 10pt; }

  h1 { font-size: 18pt; color: #1b4332; margin: 18pt 0 8pt; font-weight: 600; }
  h2 { font-size: 14pt; color: #1b4332; margin: 16pt 0 6pt; font-weight: 600; }
  h3 { font-size: 12pt; color: #1b4332; margin: 12pt 0 4pt; font-weight: 600; }

  ul, ol { margin: 0 0 10pt 24pt; padding: 0; }
  li { margin-bottom: 4pt; }

  code {
    font-family: Consolas, 'Courier New', monospace;
    font-size: 10pt;
    background: #f3f4f6;
    padding: 1pt 4pt;
    border-radius: 2pt;
  }
  pre {
    font-family: Consolas, 'Courier New', monospace;
    font-size: 10pt;
    background: #f3f4f6;
    padding: 8pt;
    border-radius: 4pt;
    white-space: pre-wrap;
  }
  pre code { background: transparent; padding: 0; }

  blockquote {
    border-left: 2pt solid #52b788;
    margin: 8pt 0;
    padding: 0 12pt;
    color: #4b5563;
  }

  a { color: #1b4332; }

  /* Inline math sits on the text baseline at ~one line height.
     We pin height in the IMG attribute too — Word respects the attr. */
  img.yve-math-inline {
    vertical-align: middle;
  }

  /* Display math: block-level, centered, with vertical breathing room.
     Capped max-height stops single-line equations from rendering as
     200px banners. Word respects max-width / max-height on images. */
  div.yve-math-block {
    text-align: center;
    margin: 12pt 0;
  }
  img.yve-math-display {
    max-width: 90%;
  }
</style>
</head>
<body>
$body
</body>
</html>
''';
  }

  /// Replace `\$\$...\$\$` and inline `\$...\$` math with `<img>` tags
  /// served by CodeCogs. Two separate IMG classes (inline vs display)
  /// so the document CSS + width/height attributes can keep sizing
  /// consistent in Word.
  String _replaceMathWithImages(String input) {
    // Display math first (greedy). `$$` boundaries are unambiguous.
    String out = input.replaceAllMapped(
      RegExp(r'\$\$([\s\S]+?)\$\$'),
      (Match m) {
        final String latex = (m.group(1) ?? '').trim();
        return '\n\n<div class="yve-math-block">${_mathImg(latex, display: true)}</div>\n\n';
      },
    );
    // Inline math — don't touch currency-like patterns (mirrors the
    // in-app inline regex).
    out = out.replaceAllMapped(
      RegExp(r'(?<![\$\w])\$([^\$\n]+?)\$(?![\d\w])'),
      (Match m) {
        final String latex = (m.group(1) ?? '').trim();
        return _mathImg(latex, display: false);
      },
    );
    return out;
  }

  String _mathImg(String latex, {required bool display}) {
    // Consistent DPI for both display and inline so Word doesn't get
    // wildly different pixel sizes for math at the same logical size.
    // No `\large` modifier — that was the source of "giant equations
    // floating in the center". KaTeX/LaTeX default size matches body
    // text at 11pt when paired with the height attribute below.
    final String prefix = display
        ? r'\dpi{150}\bg_white '
        : r'\dpi{150}\bg_white ';
    final String encoded = Uri.encodeComponent('$prefix$latex');
    final String alt =
        latex.replaceAll('"', '&quot;').replaceAll('<', '&lt;');
    final String cls = display ? 'yve-math-display' : 'yve-math-inline';
    // HTML width/height attributes — Word respects these even when it
    // strips most CSS. Inline pinned to 18px (~one line of 11pt body).
    // Display gets a height cap so single-line formulas don't blow up;
    // max-width via CSS keeps multi-line ones from spilling off the page.
    final String sizeAttr = display ? 'height="44"' : 'height="18"';
    return '<img class="$cls" $sizeAttr '
        'src="https://latex.codecogs.com/png.latex?$encoded" '
        'alt="$alt" />';
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
