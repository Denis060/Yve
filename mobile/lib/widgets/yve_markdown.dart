// Unified rendering layer for Yve's rich output: markdown + LaTeX,
// inline and display, sanitized before it ever hits a renderer so
// nothing leaks raw to the user.
//
// Pipeline per call:
//
//   1. Split the input into top-level segments along $$...$$ fences.
//   2. Each text segment is further inspected: if it contains inline
//      $...$ math, render the whole segment as a RichText paragraph
//      with WidgetSpans for the math (so "Let $x$ be the unknown"
//      truly flows mid-sentence). Otherwise render as MarkdownBody.
//   3. Each math segment passes through [sanitizeLatex] which strips
//      \tag{...}, \label{...}, \nonumber, and converts top-level
//      align*-style blocks to aligned (which flutter_math_fork
//      supports). Then Math.tex.
//
// Anything malformed in the LaTeX falls back to a monospace render
// of the raw source — never crashes the bubble.

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_math_fork/flutter_math.dart';

import '../theme/yve_colors.dart';
import '../theme/yve_spacing.dart';

class YveMarkdownBody extends StatelessWidget {
  const YveMarkdownBody({
    super.key,
    required this.data,
    required this.styleSheet,
    this.onTapLink,
    this.selectable = true,
  });

  final String data;
  final MarkdownStyleSheet styleSheet;
  final MarkdownTapLinkCallback? onTapLink;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    // Two-pass split: first peel off $$...$$ display math, then within
    // each text block peel off markdown tables. The pipe-syntax tables
    // never appear inside display-math fences, so the order is safe.
    final List<_Block> rawBlocks = _splitDisplayMath(data);
    final List<_Block> blocks = <_Block>[];
    for (final _Block b in rawBlocks) {
      if (b is _TextBlock) {
        blocks.addAll(_splitTables(b.text));
      } else {
        blocks.add(b);
      }
    }
    if (blocks.length == 1 && blocks.first is _TextBlock) {
      return _TextBlockView(
        text: (blocks.first as _TextBlock).text,
        styleSheet: styleSheet,
        onTapLink: onTapLink,
        selectable: selectable,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: blocks.map((b) {
        if (b is _TextBlock) {
          final String trimmed = b.text.trim();
          if (trimmed.isEmpty) return const SizedBox.shrink();
          return _TextBlockView(
            text: trimmed,
            styleSheet: styleSheet,
            onTapLink: onTapLink,
            selectable: selectable,
          );
        }
        if (b is _DisplayMathBlock) {
          return _MathBlockView(latex: b.latex);
        }
        if (b is _TableBlock) {
          return _TableBlockView(table: b, styleSheet: styleSheet);
        }
        return const SizedBox.shrink();
      }).toList(growable: false),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Top-level splitter — $$...$$ display math vs everything else
// ─────────────────────────────────────────────────────────────────────

abstract class _Block {}
class _TextBlock extends _Block {
  _TextBlock(this.text);
  final String text;
}
class _DisplayMathBlock extends _Block {
  _DisplayMathBlock(this.latex);
  final String latex;
}
class _TableBlock extends _Block {
  _TableBlock({
    required this.headers,
    required this.rows,
    required this.alignments,
  });
  /// Column header text (raw markdown — may contain inline math).
  final List<String> headers;
  /// Row data. Each row has [headers.length] cells (short rows are
  /// padded with empty strings during parse).
  final List<List<String>> rows;
  /// Column alignment from the markdown separator row.
  final List<TextAlign> alignments;
}

List<_Block> _splitDisplayMath(String input) {
  final List<_Block> out = <_Block>[];
  final RegExp display = RegExp(r'\$\$([\s\S]+?)\$\$');
  int cursor = 0;
  for (final RegExpMatch m in display.allMatches(input)) {
    if (m.start > cursor) {
      out.add(_TextBlock(input.substring(cursor, m.start)));
    }
    out.add(_DisplayMathBlock(m.group(1)!.trim()));
    cursor = m.end;
  }
  if (cursor < input.length) {
    out.add(_TextBlock(input.substring(cursor)));
  }
  if (out.isEmpty) out.add(_TextBlock(input));
  return out;
}

// ─────────────────────────────────────────────────────────────────────
// Table splitter — detect GFM `| a | b |` syntax inside text blocks
// and pull each one out so it can render as a proper Flutter Table
// instead of ASCII-bar text via flutter_markdown's default styling.
// ─────────────────────────────────────────────────────────────────────

List<_Block> _splitTables(String input) {
  // A markdown table looks like:
  //
  //   | a | b | c |
  //   |---|:--:|--:|
  //   | 1 | 2 | 3 |
  //   | 4 | 5 | 6 |
  //
  // Match: a header row (pipe-delimited), a separator row whose cells
  // are all dashes (with optional colons for alignment), and one or
  // more data rows.
  //
  // The separator regex is intentionally lenient — Yve occasionally
  // emits a malformed separator like `|---|` for a 3-column table.
  // We accept anything that looks broadly like a separator row (a
  // dash-only block between pipes) and the parser pads alignment to
  // match the actual header column count.
  final RegExp tableRe = RegExp(
    r'(?:^|\n)'
    r'([ \t]*\|.*\|[ \t]*\n)'                                    // header
    r'([ \t]*\|[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*\n)' // separator
    r'((?:[ \t]*\|.*\|[ \t]*\n?)+)',                              // body
    multiLine: true,
  );
  final List<_Block> out = <_Block>[];
  int cursor = 0;
  for (final RegExpMatch m in tableRe.allMatches(input)) {
    if (m.start > cursor) {
      out.add(_TextBlock(input.substring(cursor, m.start)));
    }
    final _TableBlock? table = _parseTable(
      headerLine: m.group(1)!,
      separatorLine: m.group(2)!,
      bodyLines: m.group(3)!,
    );
    if (table != null) {
      out.add(table);
    } else {
      // Parse failed — fall back to original literal text so the user
      // sees the raw markdown rather than nothing.
      out.add(_TextBlock(m.group(0)!));
    }
    cursor = m.end;
  }
  if (cursor < input.length) {
    out.add(_TextBlock(input.substring(cursor)));
  }
  if (out.isEmpty) out.add(_TextBlock(input));
  return out;
}

_TableBlock? _parseTable({
  required String headerLine,
  required String separatorLine,
  required String bodyLines,
}) {
  final List<String> headers = _splitRow(headerLine);
  if (headers.isEmpty) return null;
  final int colCount = headers.length;

  // Alignment from separator: `:---` left, `:---:` center, `---:` right.
  // Yve occasionally emits a separator row with fewer cells than the
  // header (e.g. `|---|` under a 3-column header). Pad the alignment
  // list with sensible defaults rather than rejecting the whole table.
  final List<String> sepCells = _splitRow(separatorLine);
  final List<TextAlign> alignments = List<TextAlign>.generate(colCount, (i) {
    if (i >= sepCells.length) return TextAlign.left;
    final String c = sepCells[i].trim();
    final bool leftColon = c.startsWith(':');
    final bool rightColon = c.endsWith(':');
    if (leftColon && rightColon) return TextAlign.center;
    if (rightColon) return TextAlign.right;
    return TextAlign.left;
  });

  final List<List<String>> rows = <List<String>>[];
  for (final String line in bodyLines.split('\n')) {
    if (line.trim().isEmpty) continue;
    final List<String> cells = _splitRow(line);
    if (cells.isEmpty) continue;
    while (cells.length < colCount) {
      cells.add('');
    }
    rows.add(cells.sublist(0, colCount));
  }
  if (rows.isEmpty) return null;
  return _TableBlock(headers: headers, rows: rows, alignments: alignments);
}

/// Split a `| a | b | c |` row into its cells. Strips surrounding
/// whitespace and optional trailing pipe. We accept both `| a | b |`
/// (canonical GFM) and `| a | b` (missing trailing pipe) since some
/// model outputs forget the closing pipe.
///
/// Returns a *growable* list — `_parseTable` pads short rows with
/// empty strings via `cells.add('')`, which throws
/// `UnsupportedError: Cannot add to a fixed-length list` otherwise.
List<String> _splitRow(String line) {
  String s = line.trim();
  if (!s.startsWith('|')) return const <String>[];
  // Strip leading and (optional) trailing pipe.
  s = s.substring(1);
  if (s.endsWith('|')) s = s.substring(0, s.length - 1);
  return s.split('|').map((c) => c.trim()).toList();
}

// ─────────────────────────────────────────────────────────────────────
// Text block — choose between MarkdownBody (no inline math) and our
// RichText path (has inline math)
// ─────────────────────────────────────────────────────────────────────

// Inline math: $...$ that isn't a currency value. Lookbehind/-ahead
// guards keep "$5" and "$1.50/mo" out of math mode.
final RegExp _inlineMath = RegExp(r'(?<![\$\w])\$([^\$\n]+?)\$(?![\d\w])');

class _TextBlockView extends StatelessWidget {
  const _TextBlockView({
    required this.text,
    required this.styleSheet,
    required this.onTapLink,
    required this.selectable,
  });

  final String text;
  final MarkdownStyleSheet styleSheet;
  final MarkdownTapLinkCallback? onTapLink;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final bool hasInlineMath = _inlineMath.hasMatch(text);
    if (!hasInlineMath) {
      return MarkdownBody(
        data: text,
        selectable: selectable,
        onTapLink: onTapLink,
        styleSheet: styleSheet,
      );
    }
    // Has inline math. Render each paragraph (split by blank line) as
    // RichText with WidgetSpans for the math; non-math paragraphs go
    // through MarkdownBody so lists / headings / code blocks still work.
    final List<String> paragraphs = text
        .split(RegExp(r'\n\n+'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (int i = 0; i < paragraphs.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: YveSpacing.sm),
          _inlineMath.hasMatch(paragraphs[i])
              ? _InlineMathParagraph(
                  text: paragraphs[i],
                  baseStyle: styleSheet.p ??
                      const TextStyle(
                        fontSize: 14,
                        color: YveColors.textPrimary,
                        height: 1.6,
                      ),
                )
              : MarkdownBody(
                  data: paragraphs[i],
                  selectable: selectable,
                  onTapLink: onTapLink,
                  styleSheet: styleSheet,
                ),
        ],
      ],
    );
  }
}

/// A single paragraph that contains inline math. Built as RichText so
/// math flows mid-sentence. Supports basic markdown spans inside the
/// text portions: **bold**, *italic*, `code`. More advanced markdown
/// (lists, headings, links) doesn't appear mid-paragraph in practice;
/// if it does, the user gets the literal characters and we can extend
/// the parser later.
class _InlineMathParagraph extends StatelessWidget {
  const _InlineMathParagraph({required this.text, required this.baseStyle});
  final String text;
  final TextStyle baseStyle;

  @override
  Widget build(BuildContext context) {
    // Pre-scan the whole text for inline formatting (**bold**, *italic*,
    // `code`) so spans can cross math boundaries. Otherwise a string
    // like "**Step 3 — Divide by $n$ or $n - 1$.**" gets split into
    // three text fragments by the math walker, each containing only
    // half of a `**...**` pair, and the markers render literally.
    final _StyledText styled = _stripInlineMarkup(text);
    final List<InlineSpan> spans = <InlineSpan>[];
    int cursor = 0;
    for (final RegExpMatch m in _inlineMath.allMatches(styled.text)) {
      if (m.start > cursor) {
        spans.addAll(_spansForRange(styled, cursor, m.start, baseStyle));
      }
      spans.add(_inlineMathSpan(m.group(1)!.trim(), baseStyle));
      cursor = m.end;
    }
    if (cursor < styled.text.length) {
      spans.addAll(_spansForRange(styled, cursor, styled.text.length, baseStyle));
    }
    return SelectableText.rich(TextSpan(children: spans));
  }
}

/// Per-character style state for a string after inline markdown markers
/// have been stripped. Lets us slice the stripped text at arbitrary
/// (math) boundaries without losing track of which characters were
/// inside `**...**`, `*...*`, or `` `...` `` pairs.
class _CharStyle {
  const _CharStyle({this.bold = false, this.italic = false, this.code = false});
  final bool bold;
  final bool italic;
  final bool code;

  bool sameStyleAs(_CharStyle other) =>
      bold == other.bold && italic == other.italic && code == other.code;
}

class _StyledText {
  _StyledText({required this.text, required this.styles});
  final String text;
  /// Parallel to `text` — `styles[i]` describes the styling of character
  /// `text[i]` after the markdown markers are stripped.
  final List<_CharStyle> styles;
}

/// Walk the input once, stripping out `**bold**`, `*italic*`, and
/// `` `code` `` markers while building a per-character style array. The
/// resulting text is what we feed to the math splitter; the style array
/// gives us the styling for any sub-range we need to render.
_StyledText _stripInlineMarkup(String input) {
  final StringBuffer text = StringBuffer();
  final List<_CharStyle> styles = <_CharStyle>[];
  bool bold = false, italic = false, code = false;
  int i = 0;
  final int n = input.length;
  while (i < n) {
    // Bold marker `**` toggles only when followed by non-`*` content.
    if (i + 1 < n && input[i] == '*' && input[i + 1] == '*') {
      bold = !bold;
      i += 2;
      continue;
    }
    // Italic `*` — single, not paired up as bold.
    if (input[i] == '*') {
      italic = !italic;
      i++;
      continue;
    }
    // Inline code `` ` ``.
    if (input[i] == '`') {
      code = !code;
      i++;
      continue;
    }
    text.write(input[i]);
    styles.add(_CharStyle(bold: bold, italic: italic, code: code));
    i++;
  }
  // If we exit with bold/italic still on (unmatched markers), the
  // remaining chars just retain whatever style they got at the time.
  return _StyledText(text: text.toString(), styles: styles);
}

/// Emit InlineSpans for a sub-range of `styled` (between math
/// insertions), grouping consecutive characters that share the same
/// style into a single TextSpan.
List<InlineSpan> _spansForRange(
  _StyledText styled,
  int start,
  int end,
  TextStyle baseStyle,
) {
  if (end <= start) return const <InlineSpan>[];
  final List<InlineSpan> out = <InlineSpan>[];
  int runStart = start;
  _CharStyle runStyle = styled.styles[start];
  for (int i = start + 1; i < end; i++) {
    if (!styled.styles[i].sameStyleAs(runStyle)) {
      out.add(TextSpan(
        text: styled.text.substring(runStart, i),
        style: _applyStyle(baseStyle, runStyle),
      ));
      runStart = i;
      runStyle = styled.styles[i];
    }
  }
  out.add(TextSpan(
    text: styled.text.substring(runStart, end),
    style: _applyStyle(baseStyle, runStyle),
  ));
  return out;
}

TextStyle _applyStyle(TextStyle base, _CharStyle cs) {
  TextStyle s = base;
  if (cs.bold) s = s.copyWith(fontWeight: FontWeight.w700);
  if (cs.italic) s = s.copyWith(fontStyle: FontStyle.italic);
  if (cs.code) {
    s = s.copyWith(
      fontFamily: 'monospace',
      backgroundColor: YveColors.primarySurface,
    );
  }
  return s;
}

InlineSpan _inlineMathSpan(String latex, TextStyle baseStyle) {
  return WidgetSpan(
    alignment: PlaceholderAlignment.middle,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: Math.tex(
        sanitizeLatex(latex),
        // Match surrounding prose size visually; flutter_math sizes its
        // own glyphs from this textStyle.
        textStyle: baseStyle.copyWith(fontSize: baseStyle.fontSize),
        mathStyle: MathStyle.text,
        onErrorFallback: (FlutterMathException _) => Text(
          latex,
          style: baseStyle.copyWith(
            fontFamily: 'monospace',
            color: YveColors.textSecondary,
          ),
        ),
      ),
    ),
  );
}

/// Convert a plain-text run with minimal markdown markers into a list
/// of TextSpans. Recognizes **bold**, *italic*, `code`. Anything else
/// falls through as plain text — including stray characters that don't
/// look like markdown.
List<InlineSpan> _markdownSpans(String text, TextStyle baseStyle) {
  if (text.isEmpty) return const <InlineSpan>[];
  // Tokenize greedily. Order matters: try bold (**) before italic (*).
  final RegExp pattern = RegExp(
    r'(\*\*([^*\n]+)\*\*)' // **bold**
    r'|(\*([^*\n]+)\*)' // *italic*
    r'|(`([^`\n]+)`)', // `code`
  );
  final List<InlineSpan> spans = <InlineSpan>[];
  int cursor = 0;
  for (final RegExpMatch m in pattern.allMatches(text)) {
    if (m.start > cursor) {
      spans.add(TextSpan(
        text: text.substring(cursor, m.start),
        style: baseStyle,
      ));
    }
    if (m.group(1) != null) {
      spans.add(TextSpan(
        text: m.group(2),
        style: baseStyle.copyWith(fontWeight: FontWeight.w700),
      ));
    } else if (m.group(3) != null) {
      spans.add(TextSpan(
        text: m.group(4),
        style: baseStyle.copyWith(fontStyle: FontStyle.italic),
      ));
    } else if (m.group(5) != null) {
      spans.add(TextSpan(
        text: m.group(6),
        style: baseStyle.copyWith(
          fontFamily: 'monospace',
          backgroundColor: YveColors.primarySurface,
        ),
      ));
    }
    cursor = m.end;
  }
  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor), style: baseStyle));
  }
  return spans;
}

// ─────────────────────────────────────────────────────────────────────
// Display math block
// ─────────────────────────────────────────────────────────────────────

class _MathBlockView extends StatelessWidget {
  const _MathBlockView({required this.latex});
  final String latex;

  @override
  Widget build(BuildContext context) {
    final String cleaned = sanitizeLatex(latex);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: YveSpacing.sm),
      padding: const EdgeInsets.symmetric(
        horizontal: YveSpacing.md,
        vertical: YveSpacing.md,
      ),
      decoration: BoxDecoration(
        color: YveColors.primarySurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: YveColors.border, width: 1),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Center(
          child: Math.tex(
            cleaned,
            mathStyle: MathStyle.display,
            textStyle: const TextStyle(
              fontSize: 16,
              color: YveColors.textPrimary,
            ),
            onErrorFallback: (FlutterMathException _) => Text(
              latex,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                color: YveColors.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Table block — real Flutter Table widget, math-aware cells,
// worksheet-style styling, horizontal scroll on mobile.
// ─────────────────────────────────────────────────────────────────────

class _TableBlockView extends StatelessWidget {
  const _TableBlockView({
    required this.table,
    required this.styleSheet,
  });

  final _TableBlock table;
  final MarkdownStyleSheet styleSheet;

  @override
  Widget build(BuildContext context) {
    final TextStyle headerStyle = (styleSheet.p ?? const TextStyle()).copyWith(
      fontSize: 13,
      fontWeight: FontWeight.w700,
      color: YveColors.primary,
      height: 1.4,
    );
    final TextStyle cellStyle = (styleSheet.p ?? const TextStyle()).copyWith(
      fontSize: 13,
      color: YveColors.textPrimary,
      height: 1.5,
    );

    // Build header row.
    final TableRow headerRow = TableRow(
      decoration: const BoxDecoration(color: YveColors.primarySurface),
      children: <Widget>[
        for (int i = 0; i < table.headers.length; i++)
          _TableCellView(
            text: table.headers[i],
            align: table.alignments[i],
            style: headerStyle,
            isHeader: true,
          ),
      ],
    );

    // Build data rows.
    final List<TableRow> dataRows = <TableRow>[];
    for (int r = 0; r < table.rows.length; r++) {
      final bool zebra = r.isOdd;
      dataRows.add(TableRow(
        decoration: BoxDecoration(
          color: zebra
              ? YveColors.surface2.withOpacity(0.4)
              : YveColors.surface,
        ),
        children: <Widget>[
          for (int c = 0; c < table.rows[r].length; c++)
            _TableCellView(
              text: table.rows[r][c],
              align: table.alignments[c],
              style: cellStyle,
              isHeader: false,
            ),
        ],
      ));
    }

    final Widget tableWidget = Table(
      border: TableBorder.symmetric(
        outside: const BorderSide(color: YveColors.border, width: 1),
        inside: BorderSide(color: YveColors.border.withOpacity(0.5), width: 0.5),
      ),
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      // intrinsicColumnWidth lets each column size to its content, which
      // is the right default for math/data tables. Wide tables overflow
      // → horizontal scroll wrapper catches it.
      defaultColumnWidth: const IntrinsicColumnWidth(),
      children: <TableRow>[headerRow, ...dataRows],
    );

    return Container(
      margin: const EdgeInsets.symmetric(vertical: YveSpacing.sm),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: YveColors.border, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: MediaQuery.of(context).size.width - 64,
          ),
          child: tableWidget,
        ),
      ),
    );
  }
}

class _TableCellView extends StatelessWidget {
  const _TableCellView({
    required this.text,
    required this.align,
    required this.style,
    required this.isHeader,
  });

  final String text;
  final TextAlign align;
  final TextStyle style;
  final bool isHeader;

  @override
  Widget build(BuildContext context) {
    final bool hasInlineMath = _inlineMath.hasMatch(text);
    final Widget content = hasInlineMath
        ? _InlineMathCellView(text: text, baseStyle: style, align: align)
        : RichText(
            textAlign: align,
            text: TextSpan(children: _markdownSpans(text, style)),
          );
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: YveSpacing.md,
        vertical: 10,
      ),
      child: Align(
        alignment: _alignmentFromTextAlign(align),
        child: content,
      ),
    );
  }

  AlignmentGeometry _alignmentFromTextAlign(TextAlign a) {
    switch (a) {
      case TextAlign.center:
        return Alignment.center;
      case TextAlign.right:
      case TextAlign.end:
        return Alignment.centerRight;
      default:
        return Alignment.centerLeft;
    }
  }
}

/// A table cell that contains inline math. Same approach as
/// _InlineMathParagraph but simpler — single line, no paragraph split.
class _InlineMathCellView extends StatelessWidget {
  const _InlineMathCellView({
    required this.text,
    required this.baseStyle,
    required this.align,
  });

  final String text;
  final TextStyle baseStyle;
  final TextAlign align;

  @override
  Widget build(BuildContext context) {
    // Same approach as _InlineMathParagraph — strip markdown markers
    // first so bold/italic can span math boundaries inside a cell.
    final _StyledText styled = _stripInlineMarkup(text);
    final List<InlineSpan> spans = <InlineSpan>[];
    int cursor = 0;
    for (final RegExpMatch m in _inlineMath.allMatches(styled.text)) {
      if (m.start > cursor) {
        spans.addAll(_spansForRange(styled, cursor, m.start, baseStyle));
      }
      spans.add(_inlineMathSpan(m.group(1)!.trim(), baseStyle));
      cursor = m.end;
    }
    if (cursor < styled.text.length) {
      spans.addAll(_spansForRange(styled, cursor, styled.text.length, baseStyle));
    }
    return RichText(
      textAlign: align,
      text: TextSpan(children: spans),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// LaTeX sanitizer — strip macros flutter_math_fork doesn't support
// ─────────────────────────────────────────────────────────────────────

/// Normalize LaTeX input before passing to flutter_math_fork.
///
/// What we remove (silently):
///   - \tag{...} / \tag*{...}        : equation numbering (presentation)
///   - \label{...}                   : cross-reference labels
///   - \nonumber                     : kill equation number on a line
///   - \notag                        : same
///
/// What we convert:
///   - \begin{align*}…\end{align*}   → \begin{aligned}…\end{aligned}
///   - \begin{align}…\end{align}     → \begin{aligned}…\end{aligned}
///   - \begin{equation*}…\end{...}   → unwrap (display math is already
///                                     wrapped by our $$...$$ split)
///   - \begin{equation}…\end{...}    → unwrap
///
/// flutter_math_fork doesn't support `align`/`align*` as a top-level
/// environment but does support `aligned`. The wrappers are
/// presentational artifacts that don't change semantics.
String sanitizeLatex(String latex) {
  String out = latex;

  // Strip \tag and friends (with or without star, with or without
  // argument). We do these first so they don't trip up later regex.
  out = out.replaceAll(RegExp(r'\\tag\*?\s*\{[^}]*\}'), '');
  out = out.replaceAll(RegExp(r'\\label\s*\{[^}]*\}'), '');
  out = out.replaceAll(RegExp(r'\\nonumber'), '');
  out = out.replaceAll(RegExp(r'\\notag'), '');

  // align → aligned (supported inside math mode by flutter_math_fork).
  out = out.replaceAllMapped(
    RegExp(r'\\begin\{align\*?\}([\s\S]*?)\\end\{align\*?\}'),
    (m) => '\\begin{aligned}${m.group(1)}\\end{aligned}',
  );

  // equation wrappers — already inside $$...$$, so just unwrap.
  out = out.replaceAllMapped(
    RegExp(r'\\begin\{equation\*?\}([\s\S]*?)\\end\{equation\*?\}'),
    (m) => (m.group(1) ?? '').trim(),
  );

  // Trim stray whitespace from the substitutions.
  return out.trim();
}
