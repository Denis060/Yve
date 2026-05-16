import 'package:flutter/foundation.dart';

/// One day's chat activity. Used for the calm 7-dot strip in the Home
/// greeting — no streak, no judgment, just "you showed up these days".
@immutable
class DailyActivity {
  const DailyActivity({required this.day, required this.messageCount});

  final DateTime day;
  final int messageCount;

  factory DailyActivity.fromRow(Map<String, dynamic> row) {
    return DailyActivity(
      day: DateTime.parse(row['day'] as String),
      messageCount: (row['message_count'] as int?) ?? 0,
    );
  }
}

/// Builds the 7-dot strip ending today. Missing days get a zero-count entry
/// so the strip is always exactly 7 dots regardless of when the user started.
List<DailyActivity> weekStrip(List<DailyActivity> raw) {
  final DateTime today = DateTime.now();
  final DateTime todayDate = DateTime(today.year, today.month, today.day);
  final Map<String, DailyActivity> byDay = <String, DailyActivity>{};
  for (final DailyActivity d in raw) {
    final DateTime k = DateTime(d.day.year, d.day.month, d.day.day);
    byDay[k.toIso8601String()] = d;
  }
  return <DailyActivity>[
    for (int i = 6; i >= 0; i--)
      _resolveDay(
        todayDate.subtract(Duration(days: i)),
        byDay,
      ),
  ];
}

DailyActivity _resolveDay(
  DateTime day,
  Map<String, DailyActivity> byDay,
) {
  return byDay[day.toIso8601String()] ?? DailyActivity(day: day, messageCount: 0);
}
