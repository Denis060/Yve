import 'package:flutter_test/flutter_test.dart';
import 'package:yve/services/export_service.dart';

void main() {
  final DateTime at = DateTime(2026, 5, 16, 14, 30);
  final DateTime night = DateTime(2026, 5, 16, 21, 10);

  group('filenameFor — structured filenames, never AI text', () {
    test('subject + title (assignment-style)', () {
      expect(
        filenameFor(
          subjectName: 'Biology',
          sessionTitle: 'Cell Assignment',
          at: at,
        ),
        'Yve_Biology_Cell_Assignment_2026-05-16_14-30',
      );
    });

    test('subject + title (care plan)', () {
      expect(
        filenameFor(
          subjectName: 'Nursing',
          sessionTitle: 'Care Plan',
          at: night,
        ),
        'Yve_Nursing_Care_Plan_2026-05-16_21-10',
      );
    });

    test('polish bubble — no subject, no title (the case the user hit)', () {
      expect(
        filenameFor(
          toolLabel: 'Polish',
          variant: 'Draft',
          at: DateTime(2026, 5, 16, 9, 45),
        ),
        'Yve_Polish_Draft_2026-05-16_09-45',
      );
    });

    test('polish bubble — full analysis variant', () {
      expect(
        filenameFor(
          toolLabel: 'Polish',
          variant: 'Analysis',
          at: DateTime(2026, 5, 16, 9, 45),
        ),
        'Yve_Polish_Analysis_2026-05-16_09-45',
      );
    });

    test('scan flow', () {
      expect(
        filenameFor(
          toolLabel: 'Scan',
          variant: 'Assignment',
          at: DateTime(2026, 5, 16, 22, 5),
        ),
        'Yve_Scan_Assignment_2026-05-16_22-05',
      );
    });

    test('polish with full subject + session title + variant', () {
      expect(
        filenameFor(
          subjectName: 'Biology',
          sessionTitle: 'Cell Assignment',
          toolLabel: 'Polish',
          variant: 'Draft',
          at: at,
        ),
        'Yve_Biology_Cell_Assignment_Draft_2026-05-16_14-30',
      );
    });

    test('absolute fallback when nothing identifying is supplied', () {
      expect(
        filenameFor(at: at),
        'Yve_Document_2026-05-16_14-30',
      );
    });

    test('strips emojis, punctuation, and AI-flavored sentence noise', () {
      expect(
        filenameFor(
          sessionTitle: "Let's work through every section carefully ✦",
          at: at,
        ),
        // Sanitization keeps it a tidy filename — no apostrophe, no emoji.
        // The title part is capped at 40 chars, so "carefully" gets clipped
        // to "carefull" (this is the desired bound — no runaway filenames).
        'Yve_Lets_work_through_every_section_carefull_2026-05-16_14-30',
      );
    });

    test('collapses whitespace runs to single underscores', () {
      expect(
        filenameFor(
          subjectName: '  Biology   ',
          sessionTitle: '  Cell    Assignment  ',
          at: at,
        ),
        'Yve_Biology_Cell_Assignment_2026-05-16_14-30',
      );
    });

    test('caps each part at ~40 chars (no runaway filenames)', () {
      final String longTitle = 'A' * 100;
      final String out = filenameFor(sessionTitle: longTitle, at: at);
      // Title segment is bounded; total filename stays under 80 chars.
      expect(out.length, lessThanOrEqualTo(80));
      expect(out.startsWith('Yve_AAAA'), isTrue);
      expect(out.endsWith('_2026-05-16_14-30'), isTrue);
    });

    test('pads single-digit month/day/hour/minute', () {
      expect(
        filenameFor(
          subjectName: 'Biology',
          at: DateTime(2026, 1, 5, 4, 7),
        ),
        'Yve_Biology_2026-01-05_04-07',
      );
    });

    test('empty strings treated as null (no leading/trailing underscores)', () {
      expect(
        filenameFor(
          subjectName: '',
          sessionTitle: '   ',
          toolLabel: 'Polish',
          at: at,
        ),
        'Yve_Polish_2026-05-16_14-30',
      );
    });

    test('symbols-only inputs are dropped, not kept as empty segments', () {
      expect(
        filenameFor(
          subjectName: '!!!',
          sessionTitle: '???',
          toolLabel: 'Polish',
          variant: 'Draft',
          at: at,
        ),
        'Yve_Polish_Draft_2026-05-16_14-30',
      );
    });
  });
}
