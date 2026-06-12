# Yve v1.1 — handoff notes (Android + iOS release)

Post-launch enhancements landed on `main` after the iOS 1.0 approval
(2026-06-10). **Web (app.getyve.com) is already deployed with these.**
iOS and Android still need a new build/release to ship them to users.

## What changed so far (all on `main`, shared Flutter code → affects iOS + Android + web)

1. **Live streaming markdown** (`mobile/lib/screens/chat_screen.dart`, `_StreamingText`)
   — Yve's answers now render markdown *as they stream* (headings, bold,
   lists, tables). Previously users saw raw `##`/`**`/`| table |` until the
   message finished. Commit 7386391.

2. **Read-aloud "$1" fix** (`mobile/lib/services/voice_service.dart`, `cleanForSpeech`)
   — `String.replaceAll(regex, r'$1')` does NOT substitute capture groups in
   Dart (unlike JS); it inserted the literal "$1", which the `$`-strip turned
   into "1". So every bold/italic/link/code span was *spoken* as "1"/"$1".
   Fixed all 3 spots with `replaceAllMapped` + `m.group(1)`. Commits 01143b5, 9e1da1f.
   (On-screen text was never affected — only TTS. Word export was always fine.)

3. **Home "Start here" card for new users** (`mobile/lib/screens/home_screen.dart`)
   — brand-new learners (no subjects/sessions) see one big card with two
   large buttons (Scan my homework / Ask Yve a question) instead of the
   compact quick bar. Returning users unchanged. Commit 37fc7ca.

4. **Chat declutter** (`mobile/lib/screens/chat_screen.dart`)
   — topic tags + follow-up chips now render only under Yve's *latest*
   answer (not every past one), and follow-ups cap at 3. Cleaner scroll.
   Commit 2309596.

## Version bump for this update

iOS 1.0 (build 14) is already live. The update is a NEW App Store version.
Use **1.0.1 / build 15** for iOS; bump Android `versionCode` above what's
live. (pubspec stays the source of truth, or override at build time.)

## "What's New" text (for App Store + Play Store release notes)

> • Yve's answers now format beautifully as she types — no more raw symbols.
> • Read-aloud sounds natural and clear.
> • A friendly "Start here" guide for first-time learners.
> • A cleaner, tidier conversation view.

## ANDROID release (build on Windows, where the keystore lives)

The Android upload keystore is NOT in the repo (gitignored). Build on the
Windows machine that published the current Play Store version — it MUST be
signed with the same key or Google rejects the update.

```
git pull
# bump version in pubspec.yaml first, e.g. 0.3.6+13 -> 0.3.7+14
flutter build appbundle --release --dart-define-from-file=dart_defines.json
# upload mobile/build/app/outputs/bundle/release/app-release.aab
# to Play Console -> Production -> Create new release
```

Play requires a higher `versionCode` (the number after `+`) than what's live.

## iOS release (from the Mac)

```
# bump version, then:
flutter build ipa --release --build-number=15 --dart-define-from-file=dart_defines.json
xcrun altool --upload-app --type ios -f build/ios/ipa/yve.ipa -u <appleId> -p <app-specific-password>
# then in App Store Connect: attach build 15 -> Add for Review -> Submit
```

## WEB redeploy (Vercel project `yve-app`, alias app.getyve.com)

```
flutter build web --release --dart-define-from-file=dart_defines.json --base-href=/
# copy static files Flutter's build skips:
cp -R web/{.well-known,legal,auth,checkout,upgrade} build/web/ ; cp web/vercel.json build/web/
cd build/web ; vercel link --yes --project yve-app ; vercel deploy --prod --yes
```

## Still planned for v1.1 (in progress)
- Onboarding: capture the learner's first name → personalize Home (no "Guest learner")
- Scan message-ordering fix (vision-ingest seeds two rows with identical
  `created_at`; `sessions_service` sorts by that one key → order can flip)
- Subject naming: drop the "101" suffix
- Avatar empty-name crash guard (`profile_screen.dart` `friendlyName.substring(0,1)`)
- Accessibility/simplicity pass for non-technical / elderly users

## Backlog (deferred)
- Premium cloud TTS voice (device voice is flat on web; better on iOS Siri)
- Camera-at-launch lifecycle (ScanScreen inits camera at app launch via IndexedStack)
- Home empty state + error-retry; scan "reading…" overlay cancel/timeout
