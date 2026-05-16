import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Local-only daily review nudges. The substrate is on-device — no FCM, no
/// server scheduling — so this slice ships without Firebase project setup.
/// A future slice can add cross-device + server-event push by registering
/// the device's FCM token alongside the same `notifications_enabled` flag.
class NotificationsService {
  NotificationsService();

  static const int _reviewNudgeId = 1;
  static const String _channelId = 'yve_review_nudge';
  static const String _channelName = 'Daily review nudges';
  static const String _channelDescription =
      'Calm once-a-day check-in when concepts are ready for a refresh.';

  static const int _nudgeHour = 19; // 7pm local
  static const int _nudgeMinute = 0;

  /// The set of messages we rotate through across days so the nudge doesn't
  /// feel like the same line every time. All in Yve's voice — never the
  /// app's. No counts (which would go stale between scheduling and firing).
  static const List<({String title, String body})> _nudgeMessages =
      <({String title, String body})>[
    (
      title: 'Yve',
      body: 'A few concepts are ready for a refresh. 2 minutes?',
    ),
    (
      title: 'Yve',
      body: 'Some things you\'ve worked on are due for a quiet revisit.',
    ),
    (
      title: 'Yve',
      body: 'When you\'re ready — there\'s a small review waiting.',
    ),
  ];

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  /// Callback the launch gate sets to handle taps. When a notification is
  /// the reason the app launched, this fires once on init. Background taps
  /// route through the same callback at tap-time.
  void Function(String? payload)? _onTap;

  Future<void> init({void Function(String? payload)? onTap}) async {
    _onTap = onTap;
    if (_initialized) return;
    tzdata.initializeTimeZones();
    try {
      final String name = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(name));
    } catch (e) {
      if (kDebugMode) print('Timezone lookup failed: $e');
      // Fall back to UTC — scheduling will fire at the wrong wall-clock
      // time but at least won't crash.
      tz.setLocalLocation(tz.getLocation('UTC'));
    }

    const AndroidInitializationSettings androidInit =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const DarwinInitializationSettings iosInit = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(
      const InitializationSettings(android: androidInit, iOS: iosInit),
      onDidReceiveNotificationResponse: (NotificationResponse r) {
        _onTap?.call(r.payload);
      },
    );

    // If the app was *launched* by a notification tap, the response is
    // sitting in getNotificationAppLaunchDetails. Forward it once.
    final NotificationAppLaunchDetails? launch =
        await _plugin.getNotificationAppLaunchDetails();
    if (launch != null && launch.didNotificationLaunchApp) {
      _onTap?.call(launch.notificationResponse?.payload);
    }

    _initialized = true;
  }

  /// Asks the OS for permission to post local notifications. iOS shows a
  /// dialog the first time; Android 13+ also requires runtime permission.
  /// Returns true when the OS reports granted.
  Future<bool> requestPermission() async {
    if (!_initialized) await init();
    final IOSFlutterLocalNotificationsPlugin? ios = _plugin
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>();
    if (ios != null) {
      final bool? ok = await ios.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
      if (ok == false) return false;
    }
    final AndroidFlutterLocalNotificationsPlugin? android = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      final bool? ok = await android.requestNotificationsPermission();
      if (ok == false) return false;
    }
    return true;
  }

  /// Schedule (or reschedule) the next daily review nudge. If [hasDueReviews]
  /// is false, any pending nudge is cancelled instead — we never fire when
  /// there's nothing worth surfacing.
  Future<void> reschedule({required bool hasDueReviews}) async {
    if (!_initialized) await init();
    await _plugin.cancel(_reviewNudgeId);
    if (!hasDueReviews) return;

    final tz.TZDateTime next = _nextFireTime();
    final ({String title, String body}) msg = _pickMessage(next);

    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      // Calm, not aggressive — no full-screen intent, no heads-up override.
    );
    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: false,
      presentSound: true,
    );

    try {
      await _plugin.zonedSchedule(
        _reviewNudgeId,
        msg.title,
        msg.body,
        next,
        const NotificationDetails(android: androidDetails, iOS: iosDetails),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        // iOS legacy interpretation — required by flutter_local_notifications v17.
        // absoluteTime means "at this exact moment in time" (vs. wallClockTime
        // which re-fires when the clock matches in a different timezone).
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        // matchDateTimeComponents lets the same scheduled entry fire daily.
        // We re-evaluate on each app open anyway, but this keeps the nudge
        // alive if the app isn't opened for a stretch.
        matchDateTimeComponents: DateTimeComponents.time,
        payload: 'review_nudge',
      );
    } catch (e) {
      if (kDebugMode) print('Notification schedule failed: $e');
    }
  }

  Future<void> cancelAll() async {
    if (!_initialized) await init();
    await _plugin.cancelAll();
  }

  tz.TZDateTime _nextFireTime() {
    final tz.TZDateTime now = tz.TZDateTime.now(tz.local);
    tz.TZDateTime fire = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      _nudgeHour,
      _nudgeMinute,
    );
    // If today's 7pm has already passed, schedule for tomorrow's 7pm.
    if (!fire.isAfter(now)) {
      fire = fire.add(const Duration(days: 1));
    }
    return fire;
  }

  ({String title, String body}) _pickMessage(tz.TZDateTime when) {
    // Rotate by day-of-year so consecutive days feel different but the
    // pick is deterministic for any given fire-time.
    final int index =
        when.day % _nudgeMessages.length;
    return _nudgeMessages[index];
  }
}

final notificationsServiceProvider = Provider<NotificationsService>((_) {
  return NotificationsService();
});

/// Initializes the notifications plugin once at app startup. Resolves after
/// the plugin is wired and any cold-start tap payload has been forwarded.
/// The launch gate watches this alongside [authReadyProvider] so we always
/// have a notification surface ready before the first chat opens.
final notificationsReadyProvider = FutureProvider<void>((ref) async {
  await ref.read(notificationsServiceProvider).init(
        onTap: (String? payload) {
          // For this slice the only payload is 'review_nudge' and the app
          // already lands on Home, where the revisit queue is visible. A
          // future slice can deep-link directly into a practice chat for
          // the top due concept.
        },
      );
});
