import '../models/entitlement.dart';

/// Apple In-App Purchase configuration (iOS only).
///
/// iPhone can't use Stripe for digital subscriptions, so on iOS the three
/// Yve Pro plans are sold through Apple IAP via RevenueCat, while web +
/// Android keep Stripe. RevenueCat receives the App Store purchase and
/// reports the unlocked entitlement back to the app; a RevenueCat →
/// Supabase webhook mirrors it into the same `subscriptions` row the
/// Stripe flow writes (the `provider` column already accepts 'apple').
///
/// Apple subscription durations are fixed (1wk/1mo/2mo/3mo/6mo/1yr), so
/// the 4-month "Semester" plan ships on iOS as a 6-month auto-renewing
/// subscription — the closest length that covers a full semester.
///
/// These product IDs must match exactly:
///   1. the products created in App Store Connect, and
///   2. the products attached in the RevenueCat dashboard.
class IapConfig {
  IapConfig._();

  /// RevenueCat entitlement identifier that unlocks Pro. One entitlement
  /// ("pro") is shared by all three products in the RevenueCat dashboard.
  static const String proEntitlement = 'pro';

  /// App Store Connect product IDs, one per plan.
  static const String monthlyId = 'io.getyve.yve.pro.monthly';
  static const String semesterId = 'io.getyve.yve.pro.semester'; // 6-month
  static const String annualId = 'io.getyve.yve.pro.annual';

  /// Maps a purchased App Store product ID back to the app's [Plan] so the
  /// entitlement state + `subscriptions` row stay consistent with Stripe.
  static Plan planForProductId(String productId) {
    switch (productId) {
      case monthlyId:
        return Plan.proMonthly;
      case semesterId:
        return Plan.proSemester;
      case annualId:
        return Plan.proAnnual;
      default:
        return Plan.free;
    }
  }

  /// The App Store product ID for a given plan (used to pre-select the
  /// right RevenueCat package on the pricing screen).
  static String? productIdForPlan(Plan plan) {
    switch (plan) {
      case Plan.proMonthly:
        return monthlyId;
      case Plan.proSemester:
        return semesterId;
      case Plan.proAnnual:
        return annualId;
      case Plan.proTrial:
      case Plan.free:
        return null;
    }
  }
}
