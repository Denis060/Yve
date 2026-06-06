# R8 / ProGuard keep rules for Yve.
#
# Each block here exists because R8's release-mode minification has
# stripped something a runtime library needed reflectively. Adding a
# new block is a real, observable bug — keep them documented so we
# remember WHY each one is here.

# ── Gson generic type tokens ─────────────────────────────────────────
# flutter_local_notifications stores scheduled notification metadata
# via Gson with TypeToken<List<SchedNotificationInfo>>. R8 erases the
# generic parameter info, Gson then throws "Missing type parameter."
# at runtime when it tries to deserialize. Captured in Sentry as
# `PlatformException(error, Missing type parameter., ...)` originating
# from FlutterLocalNotificationsPlugin.cancel() (2026-05-18).
-keepattributes Signature
-keepattributes *Annotation*
-keep class com.google.gson.reflect.TypeToken
-keep class * extends com.google.gson.reflect.TypeToken
-keep class com.dexterous.flutterlocalnotifications.models.** { *; }
-keep class com.dexterous.flutterlocalnotifications.** { *; }

# ── Flutter framework + plugins ──────────────────────────────────────
# Belt-and-suspenders for Flutter's own plugin registry + the
# androidx.* classes plugins reflect into.
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# ── Supabase / okhttp / kotlinx-serialization ────────────────────────
# Supabase Android SDK uses Kotlin serialization which reflects on
# @Serializable classes; R8 sometimes strips the synthetic descriptors.
-keepattributes RuntimeVisibleAnnotations
-keep,includedescriptorclasses class **$$serializer { *; }
-keepclassmembers class * {
    *** Companion;
}
-keepclasseswithmembers class * {
    kotlinx.serialization.KSerializer serializer(...);
}
