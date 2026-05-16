// DOCX text extraction.
//
// A .docx file is a ZIP archive with a predictable structure — the body
// text lives in `word/document.xml` inside <w:t> elements. We unzip with
// JSZip (pure JS, runs cleanly in Deno via esm.sh) and lift the text with
// a small regex pass that preserves paragraph and line-break structure.
//
// This is intentionally lightweight: we lose styling, table boundaries get
// flattened, but the textual content survives — which is what retrieval +
// concept-tagging actually need.

import JSZip from 'https://esm.sh/jszip@3.10.1';

export async function extractDocxText(bytes: Uint8Array): Promise<string> {
  let zip: JSZip;
  try {
    zip = await JSZip.loadAsync(bytes);
  } catch (e) {
    throw new Error(
      'That doesn\'t look like a valid .docx file. Try re-saving from Word.',
    );
  }
  const docFile = zip.file('word/document.xml');
  if (!docFile) {
    throw new Error(
      'Couldn\'t find word/document.xml inside the .docx — is it a Word file?',
    );
  }
  const xml = await docFile.async('string');
  return _parseDocumentXml(xml);
}

/// Minimal XML→text walker tuned for the OOXML document.xml shape.
///
/// Pulls every `<w:t>` text run, joins runs within a paragraph, breaks on
/// `<w:p>` paragraph boundaries, honors explicit `<w:br/>` line breaks,
/// and decodes the handful of named XML entities Word emits.
export function _parseDocumentXml(xml: string): string {
  // Mark paragraph + line breaks with sentinel newlines before we strip
  // any tags. (Doing it after stripping would lose the structure.)
  const withBreaks = xml
    .replace(/<w:p[\s>][^]*?<\/w:p>/g, (match) => {
      // Replace <w:br/> inside the paragraph with single newlines, then
      // append a double newline after the whole paragraph.
      const lineBroken = match.replace(/<w:br\s*\/?>/g, '\n');
      return `${lineBroken}\n\n`;
    })
    .replace(/<w:br\s*\/?>/g, '\n');

  // Strip all remaining XML tags. Whatever's left is text content.
  const stripped = withBreaks.replace(/<[^>]+>/g, '');

  // Decode the common XML entities. Word doesn't use the full HTML set —
  // these five cover practically every real document we'll see.
  const decoded = stripped
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&#(\d+);/g, (_m, n) => String.fromCharCode(Number(n)));

  // Collapse: run-internal whitespace squeeze, then no more than two
  // consecutive newlines (one paragraph break).
  return decoded
    .replace(/[ \t]+/g, ' ')
    .replace(/ ?\n ?/g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}
