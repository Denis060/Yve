import 'package:flutter/foundation.dart';

@immutable
class RecapHighlight {
  const RecapHighlight({required this.title, required this.detail});
  final String title;
  final String detail;

  factory RecapHighlight.fromJson(Map<String, dynamic> json) {
    return RecapHighlight(
      title: (json['title'] as String?)?.trim() ?? '',
      detail: (json['detail'] as String?)?.trim() ?? '',
    );
  }
}

@immutable
class RecapFocus {
  const RecapFocus({
    required this.concept,
    required this.why,
    this.subject,
  });

  final String concept;
  final String why;
  final String? subject;

  factory RecapFocus.fromJson(Map<String, dynamic> json) {
    return RecapFocus(
      concept: (json['concept'] as String?)?.trim() ?? '',
      why: (json['why'] as String?)?.trim() ?? '',
      subject: json['subject'] as String?,
    );
  }
}

/// The composed weekly recap from `yve-recap`.
@immutable
class Recap {
  const Recap({
    required this.greeting,
    required this.summary,
    required this.highlights,
    required this.suggestedFocus,
    required this.closing,
    required this.daysActive,
    required this.observationsTotal,
  });

  final String greeting;
  final String summary;
  final List<RecapHighlight> highlights;
  final List<RecapFocus> suggestedFocus;
  final String closing;
  final int daysActive;
  final int observationsTotal;

  bool get isEmpty => daysActive == 0 && observationsTotal == 0;

  factory Recap.fromJson(Map<String, dynamic> json) {
    final List<dynamic> hRaw =
        (json['highlights'] as List<dynamic>?) ?? const <dynamic>[];
    final List<dynamic> fRaw =
        (json['suggested_focus'] as List<dynamic>?) ?? const <dynamic>[];
    return Recap(
      greeting: (json['greeting'] as String?)?.trim() ?? '',
      summary: (json['summary'] as String?)?.trim() ?? '',
      highlights: hRaw
          .whereType<Map<String, dynamic>>()
          .map(RecapHighlight.fromJson)
          .toList(),
      suggestedFocus: fRaw
          .whereType<Map<String, dynamic>>()
          .map(RecapFocus.fromJson)
          .toList(),
      closing: (json['closing'] as String?)?.trim() ?? '',
      daysActive: (json['days_active'] as int?) ?? 0,
      observationsTotal: (json['observations_total'] as int?) ?? 0,
    );
  }
}
