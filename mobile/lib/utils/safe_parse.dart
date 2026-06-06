// Safe parsing helpers for inputs coming from the network or DB.
//
// Bare `DateTime.parse(x)` throws `_FormatException` on empty string,
// null-as-string-"null", or any malformed input. That exception leaks
// to the UI as raw infrastructure ("_FormatException: Invalid date
// format") which breaks trust immediately.
//
// All timestamp parsing in the app goes through these helpers so a
// single bad payload never crashes a render. The dev log records
// every failed parse so real-world bad data is visible without
// shipping the exception to the user.

import 'dart:developer' as developer;

/// Parse an ISO-8601 timestamp, returning null on any failure
/// (null input, empty string, malformed format, etc.). Always safe.
///
/// Pass [context] to identify the call site in dev logs — e.g.
/// `parseTimestampOrNull(raw, context: 'entitlement.current_period_end')`.
DateTime? parseTimestampOrNull(Object? raw, {String? context}) {
  if (raw == null) return null;
  if (raw is DateTime) return raw;
  final String s = raw.toString().trim();
  if (s.isEmpty) return null;
  // Postgres sometimes returns timestamps without timezone in a form
  // DateTime.parse handles natively, sometimes with +00 instead of Z.
  // tryParse handles both shapes and returns null for anything else.
  final DateTime? parsed = DateTime.tryParse(s);
  if (parsed == null) {
    developer.log(
      'parseTimestampOrNull: rejected ${_truncate(s, 60)}',
      name: context == null ? 'yve.parse' : 'yve.parse.$context',
      level: 900, // WARNING
    );
  }
  return parsed;
}

/// Parse an ISO-8601 timestamp, returning [fallback] on any failure.
/// Use this for non-nullable model fields where we'd rather see "now"
/// or a sentinel than crash. Logs every fallback so we know real-world
/// data has issues.
DateTime parseTimestampOr(
  Object? raw, {
  required DateTime fallback,
  String? context,
}) {
  final DateTime? parsed = parseTimestampOrNull(raw, context: context);
  return parsed ?? fallback;
}

String _truncate(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max - 1)}…';
