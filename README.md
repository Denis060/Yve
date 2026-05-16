# Yve

A calm, intelligent AI learning workspace. Scan an assignment, ask Yve a question, organize what you learn — all powered by Claude.

Yve is for students, working adults, nursing and allied-health learners, ESL learners, and certification candidates. Most users arrive urgently and stay because the workspace makes their semester easier.

## Stack

- **Flutter** (Android + iOS + Web from one codebase) — `mobile/`
- **Supabase** (Postgres, auth, file storage, Edge Functions in Deno/TypeScript) — `supabase/`
- **Anthropic Claude API** — invoked server-side from Supabase Edge Functions so your API key never ships to the client

## Folder layout

```
StudyBuddy/                      Repo root (legacy path; the product is Yve)
├── mobile/                       Flutter app (run on Android, iOS, web)
│   ├── lib/
│   │   ├── main.dart             App entry, theme, launch gate
│   │   ├── config/env.dart       Supabase URL + anon key
│   │   ├── theme/                Design tokens — colors, spacing, theme
│   │   ├── models/               Subjects, materials, chat messages, sessions
│   │   ├── services/             Supabase + AI client wrappers, in-memory stores
│   │   ├── screens/              One file per screen (home, subjects, scan, chat, tools, profile, onboarding)
│   │   └── widgets/              Shared UI pieces (bottom nav, card, pill)
│   └── pubspec.yaml
├── supabase/
│   ├── config.toml               Local Supabase project config
│   ├── functions/
│   │   ├── _shared/
│   │   │   ├── anthropic.ts      Claude API client (tool use, prompt caching, image content)
│   │   │   ├── yve_modes.ts      Per-mode system prompts + structured-output tool schema
│   │   │   ├── voyage.ts         Voyage embeddings client + paragraph-greedy chunker
│   │   │   ├── retrieval.ts      Subject-materials cosine-similarity retrieval
│   │   │   ├── vision.ts         Vision tool schema + Yve's scan-analysis system prompt
│   │   │   └── docx.ts           Server-side .docx unzip + word/document.xml extractor
│   │   ├── yve-chat/             Every chat surface calls this — persists sessions,
│   │   │                         writes observations, grounds materials-mode chats
│   │   ├── ingest-material/      Text/URL ingest → chunk → embed → store
│   │   ├── vision-ingest/        Photo → classify → OCR → action ladder → pre-loaded session
│   │   ├── yve-recap/            Weekly observations + activity → warm structured recap
│   │   ├── infer-profile/        Chat history → auto-inferred adaptation notes
│   │   ├── create-checkout-session/  Stripe Checkout session for the Yve Plus upgrade
│   │   └── stripe-webhook/       Stripe events → subscriptions table sync
│   └── migrations/
│       ├── 0001_init.sql               Profiles
│       ├── 0002_yve_features.sql       Legacy study_sessions feature expansion
│       ├── 0003_conversion_engine.sql  Per-turn conversion-engine columns (superseded by 0004)
│       ├── 0004_subject_memory.sql     Subjects + materials + chat_sessions + observations + pgvector
│       ├── 0005_retention.sql              Review queue + daily activity views
│       ├── 0006_learner_profile.sql        Per-user adaptation substrate
│       ├── 0007_auto_inferred_profile.sql  auto_observed_patterns + auto_voice_notes columns
│       ├── 0008_voice_preference.sql       read_aloud preference for the voice slice
│       ├── 0009_hands_free.sql             hands_free preference for the auto-listen loop
│       ├── 0010_notifications_preference.sql notifications_enabled for local review nudges
│       └── 0011_subscriptions.sql           subscriptions + daily_usage for the Plus tier
├── .env.example                  Copy to .env and fill in real keys
└── README.md
```

## First-time setup

### 1. Flutter app

```powershell
cd C:\Apps\StudyBuddy\mobile
flutter create .                  # auto-adds android/, ios/, web/, etc.
flutter pub get
flutter run -d chrome             # or: flutter run (picks first connected device)
```

### 2. Supabase

1. Sign up at https://supabase.com and create a project (free tier is fine).
2. Install the Supabase CLI: https://supabase.com/docs/guides/cli
3. From this folder:
   ```powershell
   supabase login
   supabase link --project-ref <your-project-ref>
   supabase db push                 # runs migrations
   supabase functions deploy yve-chat
   supabase functions deploy ingest-material
   supabase functions deploy vision-ingest
   supabase functions deploy yve-recap
   supabase functions deploy infer-profile
   supabase functions deploy create-checkout-session
   supabase functions deploy stripe-webhook --no-verify-jwt
   ```
4. In the Supabase dashboard → Project Settings → Edge Functions → Secrets, add:
   - `ANTHROPIC_API_KEY` — from https://console.anthropic.com/
   - `VOYAGE_API_KEY` — from https://www.voyageai.com/ (powers subject materials retrieval)
   - (optional) `ANTHROPIC_VISION_MODEL` — overrides the default `claude-haiku-4-5-20251001` used for scans

### 3. Connect the Flutter app

Copy `.env.example` to `.env` and fill in your Supabase URL and anon key (Supabase dashboard → Project Settings → API). Then update `mobile/lib/config/env.dart`, or pass at build time:

```powershell
flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
```

## Product vision

Yve is **not** a homework dump and not a chatbot wrapper. It's the AI study companion that feels like it was designed specifically for the person holding their phone at 11 PM after a long shift.

Core principles: **Calm, Fast, Warm, Organized, Intelligent, Low-friction**.

The app revolves around five tabs, with **Scan** as the elevated center action because the camera is the highest-frequency path:

```
[ Home ]  [ Subjects ]  [ ◉ Scan ]  [ Tools ]  [ Profile ]
```

See the design spec in `/specs/` for the full color palette, typography, motion, and screen-by-screen wireframes.

## The conversion engine

Every Yve turn doesn't just return text — it returns *structured learning state*. The `yve-chat` Edge Function forces Claude to call a `respond_to_learner` tool whose schema requires:

- `answer` — the markdown response shown to the learner
- `concept_tags` — the teachable units this turn covered (memory feed)
- `post_solve_offer.suggestions` — generated follow-up chips with `kind` ∈ {explain, simplify, example, check, quiz, flashcards, next, harder, easier, related, practice, summarize, cite, tighten, formal, rephrase, save}
- `confidence_signal` — Yve's read of how the learner is doing
- `save_to_subject` — optional subject the exchange likely belongs to

This is what subtly converts *"help me finish"* into *"help me learn"*. Chips are generated by Yve per response, not hardcoded — so they map to the concepts she actually just taught.

## Study modes

The Study tab exposes five modes that change Yve's task framing while keeping the persona constant:

- **Learn** — build understanding concept by concept, with comprehension checks
- **Practice** — ask one question at a time, evaluate, adapt difficulty
- **Assignment** — worked solutions plus the concept ladder
- **Write** — polish and structure that preserves the learner's voice
- **Materials** — answers grounded in the subject's uploaded materials

Modes are not separate features — they're behaviors of the same chat. The learner can switch modes from the chat header without losing context.

## How a turn works (end-to-end)

1. User types or taps a follow-up chip in a Yve Chat session.
2. Flutter sends the full conversation history + the current mode to `yve-chat`.
3. The Edge Function loads the per-mode system prompt and forces Claude to call the structured-output tool.
4. Server logs the structured state (concept_tags, confidence, mode) into `study_sessions`.
5. Flutter renders the markdown answer, the concept tag chips, and the generated follow-up ladder.

This single pipeline serves assignment help, scan follow-up, subject Q&A, quiz drill, and writing polish.

## Subject Memory

Subjects are not folders — they're persistent AI knowledge spaces. The memory layer (migration `0004_subject_memory.sql`) gives every subject:

- **Materials** — text / URL / (soon) PDF / image / doc uploads, chunked and embedded via Voyage AI. Stored in `material_chunks` with pgvector cosine indexing.
- **Concept observations** — every concept Yve teaches you in a subject becomes a row in `concept_observations` keyed by `(user_id, subject_id, concept, confidence_signal)`. The `concept_mastery` view rolls these up into per-concept current-confidence + observation count, which the Practice tab surfaces.
- **Persistent chat sessions** — `chat_sessions` + `chat_messages` replace the old per-turn `study_sessions`. Sessions can be resumed from Home's Continue cards or from a subject's Sessions tab. The chat screen loads message history from `chat_messages` on resume.
- **Grounded materials-mode chats** — when a learner chats inside a subject in `materials` mode (or `learn` / `open` with materials present), the `yve-chat` function embeds the question via Voyage, runs the `match_material_chunks` RPC for top-5 cosine-similar chunks, and prepends them to the system prompt so Yve cites real source text.

## Auth

Yve uses Supabase **anonymous auth on launch** so every device has a stable `auth.uid()` that all RLS policies anchor on. The Profile tab exposes a "Sign in to keep your work" flow that upgrades the anonymous account to a real email-bound identity *without losing data* — `auth.updateUser({email})` adds the email to the existing user row, so subjects / sessions / observations / materials stay attached.

Two paths through the same auth sheet:

- **Anonymous → email** — first-time upgrade. `updateUser` + 6-digit OTP code (`OtpType.emailChange`). user_id unchanged; everything carries over.
- **Email already on another account** — the link call rejects with `emailAlreadyInUse`, the sheet pivots to a warning screen ("this device's draft data won't carry over") and offers a plain `signInWithOtp` (`OtpType.email`) to switch to the existing account.

**Sign out** drops the session and immediately re-establishes an anonymous one so the app never sees a null uid — the learner returns to a fresh starting state without breaking RLS-protected reads.

### Email delivery

Supabase ships a default SMTP for development. For production, configure custom SMTP under **Supabase dashboard → Auth → Email Settings**. The OTP template can be customized to match Yve's voice; the default works.

Code flow is used over magic links so no deep-link / universal-link platform config is required — the learner types the 6-digit code into the app.

## Scan magic

The Scan tab and the chat attach button both route through `vision-ingest`:

1. Camera or gallery via `image_picker` (handles permissions natively, resizes to 1600px).
2. The Edge Function calls Claude (Haiku for speed) with the image bytes and forces the `analyze_scan` tool: classification (worksheet / textbook / slide / handwritten / equation / article / screenshot / photo / other), structured OCR (LaTeX math preserved, lists / tables / questions kept), concept tags, and a *ranked, content-specific action ladder* (e.g. "Solve problem 3" not "Solve it").
3. The function eagerly creates a `chat_sessions` row pre-loaded with two `chat_messages` — a synthetic user turn carrying the extracted text and Yve's "Here's what I see" reply. The action ladder is converted into the conversion-engine offer shape so chips appear in-chat too.
4. If the scan was filed under a subject, the extracted text is also persisted as an `image` material and embedded via Voyage so future Materials-mode chats can ground against it.
5. The Scan Result sheet renders the thumbnail, the one-line summary, concept chips, and the action tiles. Tapping an action resumes the just-created session in the chosen mode with the action's short prompt pre-filled in the input.

Inside any chat, the attach button routes camera/gallery through the same pipeline — the resulting scan can either *adopt* the current empty chat or open as its own session, depending on whether the conversation has started.

## Retention layer

Yve's memory feeds back into the user's life through three Home surfaces, each driven by the observation data the conversion engine writes on every turn:

- **Activity strip** — 7-dot week visualization in the greeting block. A filled dot means "you opened a chat that day." No streak counter, no penalty for missed days. The accompanying line ("You showed up 4 days this week") is purely descriptive — never judgmental.
- **Revisit queue** — up to 3 concepts whose `next_due_at` (computed by the `concept_review_queue` view from the most recent confidence signal) has passed. Tapping any row opens a practice-mode chat pre-seeded with "Quiz me on X", which writes a fresh observation and advances the schedule. The section is hidden entirely when nothing is due.
- **"How am I doing this week?"** — on-demand tile that calls `yve-recap`. The function aggregates the week's observations + daily activity, asks Claude to compose a warm, structured recap (greeting / summary / highlights / suggested focuses / closing) in Yve's voice, and renders it in a full-screen sheet. Tapping a suggested focus opens a practice chat for that concept.

Schedule (intentionally simple, not full SM-2):
| Latest signal | Next revisit |
|---|---|
| struggling | +1 day |
| partial | +3 days |
| grasped | +7 days |
| unknown | +2 days |

This is predictable enough that Yve can talk about it honestly when asked, and tunable in one SQL view if usage data suggests different intervals.

## Adaptation

Every learner gets a row in `learner_profiles` (lazily created on first save). The profile carries three explicit knobs the learner tunes from the Profile tab:

- **Reading level** — basic / standard / advanced. Affects vocabulary complexity and how much Yve defines inline.
- **Explanation depth** — brief / standard / thorough. Affects response length and whether Yve grounds in examples.
- **Tone** — warm / direct / playful. Subtle shifts in register while keeping the base persona intact.

Plus two free-form fields:
- **Patterns Yve should honor** — short notes about how the learner studies ("I always need an example before the formula"). Injected as a profile addendum on every chat turn.
- **My writing voice** — used by Write mode to preserve voice when polishing drafts.

The addendum is built server-side in `_shared/yve_modes.ts` (`buildProfileAddendum`) and prepended to the system prompt only for non-default fields, so the adaptation budget stays small. The next chat turn after a profile change picks up the new instructions automatically.

### Auto-inferred adaptation

The Profile tab also exposes "What Yve has noticed" — short adaptation notes Yve writes herself by observing the learner's chat history. The `infer-profile` Edge Function pulls the last ~50 chat messages, the concept mastery rollup, and recent session timestamps, then forces a `record_observations` tool that fills in two free-form fields: `auto_observed_patterns` (general adaptation tips) and `auto_voice_notes` (Write-mode voice samples, only if present). Stored in `auto_*` columns alongside the user-set ones; the chat addendum prefers user-set values and falls back to auto-inferred ones, so the learner can always override Yve's read of them. Triggered manually from the Profile tab's Refresh button for now; a background trigger after N turns ships in a later slice.

Home also gets a **presence card** — a single contextual line from Yve that resolves locally based on time-of-day, last-session age, due-review count, and weekly activity. Templated rather than LLM-generated for instant render; future iterations can cache a daily Yve-composed line. Examples: *"Morning. What are we working on?"*, *"Welcome back. Want a soft restart, or pick up where you were?"*, *"Studying late. I'll keep it short and useful."*

## Streaming responses

Yve's answers stream token-by-token. The chat experience now feels alive rather than waiting on a spinner.

The pipeline is a deliberate two-call split:

1. **Stream the answer** via `streamClaude` in `_shared/anthropic.ts`. Plain-text generation (no forced tool) flows back as NDJSON `{"type":"text","delta":"..."}` events. The pre-first-token state renders as a pulsing accent dot inside the in-flight Yve bubble; subsequent deltas append with a soft blinking caret following the last character.
2. **Extract metadata** after the answer completes. A fast Haiku call with the forced `extract_metadata` tool reads the full conversation + the just-streamed answer and emits concept tags, generated offer chips, confidence signal, and the optional save-to-subject suggestion. The client receives this as a `{"type":"metadata", ...}` event and resolves the chips + concept tags under the answer a heartbeat later.

Why two calls instead of streaming the tool's `partial_json`: parsing partial JSON mid-stream is brittle, and the Haiku metadata call benefits from prompt caching so the cost overhead is small. The natural UX rhythm — answer arrives, then chips resolve underneath — falls out of the architecture rather than being designed around it.

The client uses `package:http` directly (Supabase SDK's `.invoke()` doesn't expose streams) and parses NDJSON via `LineSplitter`. The chat screen tracks an `_activeStream` `StreamSubscription` and cancels it on dispose so navigating away mid-stream is clean.

## PDF + DOCX ingest

Both formats work end-to-end via the same vision pipeline as photo scans. Two entry points:

- **Subject Workspace → Add material → File** picks a PDF or .docx (up to 25 MB), routes through `ingest-material`, then chunks + embeds via Voyage and stores it. The file lands in the materials list, retrievable from later Materials-mode chats.
- **Chat attach → File** picks a PDF or .docx and routes through `vision-ingest`. Same magical flow as photo scans — classify (textbook / article / slide / etc.), OCR with structure preserved, generate the ranked action ladder, pre-load a chat session.

Text extraction:
- **PDFs** are handled natively by Claude via a `document` content block (`media_type: 'application/pdf'`). Limits: 32 MB / 100 pages per file.
- **DOCX** files are unzipped server-side via JSZip (a .docx is just a ZIP with XML inside). `_shared/docx.ts` walks `word/document.xml`, preserves paragraph + line-break structure, strips XML tags, decodes entities. The extracted text is then either chunked + embedded directly (ingest-material) or handed to Claude as a text block for classification + action ladder (vision-ingest). No Claude call is needed for the extraction itself, so DOCX ingest is faster and cheaper than PDF.

The client caps both at 25 MB to keep the base64 payload under Edge Function budget.

## Voice

Yve listens and speaks via device-native engines — `speech_to_text` (Siri's Speech.framework on iOS / Google STT on Android) for input, `flutter_tts` for output. No cloud STT/TTS dependencies; nothing leaves the device for the voice surface itself.

- **Input** — a mic button sits between the text field and the send button in every chat. Tap to start, tap to stop; the icon pulses red while listening, the placeholder switches to "Listening…", and recognized text appends to whatever was already typed (so the learner can type a setup sentence then dictate the rest).
- **Output** — every Yve bubble carries a small speaker icon next to her "Yve" label. Tap to play, tap again to stop. While a message is still streaming the icon is dimmed (no point speaking a chunk that's about to change). When `read_aloud` is on in the Profile, completed Yve turns auto-play the moment the metadata event arrives.
- **Adapts when she's heard, not read** — the `read_aloud` boolean ships in the chat addendum so Yve drops markdown structures that don't read aloud well, prefers flowing sentences over bullet lists, and keeps answers a touch shorter so they don't outrun the listener.
- **Cross-bubble safety** — the `VoiceService` enforces single-stream playback: starting one message cancels any other that was speaking, and the speaker icon on every bubble subscribes to the same "currently speaking message id" stream so only the active bubble shows the stop state.

### Hands-free conversation

Toggleable from Profile (requires "Read aloud" to be on). When active, the chat closes the voice loop:

1. Yve finishes speaking → TTS `setCompletionHandler` fires → chat checks the profile + idle state → starts STT
2. The learner speaks → recognized text fills the input
3. The recognizer auto-finalizes on silence → chat sees `listeningChanged = false` while `_inAutoLoop` is true → if there's text, auto-sends; if empty, surfaces a calm "Hands-free paused — no voice detected. Tap the mic to resume." snackbar

A small in-chat banner ("Hands-free • listening for you" / "…Yve will listen after she speaks") sits under the mode switcher whenever the loop is live. The pill carries a session-scoped **Pause** action that suppresses the loop for this chat without flipping the persistent preference — useful when the learner wants Yve to stop interrupting them but doesn't want to dig into Profile.

Safety guards in the orchestration: the loop won't fire while sending / scanning / loading history / listening, won't loop after error responses, and won't loop on Yve's italic mode-switch whispers (only on real Yve turns ending in the assistant role).

### Platform setup

The voice packages need OS-level permission declarations. After running `flutter create .`, add:

- **iOS** `ios/Runner/Info.plist`:
  - `NSMicrophoneUsageDescription` — "Yve uses the mic when you tap the voice button to speak your questions."
  - `NSSpeechRecognitionUsageDescription` — "Yve transcribes what you say so you can dictate questions hands-free."
- **Android** `android/app/src/main/AndroidManifest.xml`:
  - `<uses-permission android:name="android.permission.RECORD_AUDIO" />`

Without these, `VoiceService.ensureSttReady()` returns false and the chat surfaces a "Voice input isn't available on this device" snackbar.

## Notifications

Yve schedules **local** daily review nudges via `flutter_local_notifications` — no Firebase project, no FCM, no server-side scheduler. The substrate is on-device for this slice; a future slice can layer FCM in for cross-device + server-event push by registering each device's token alongside the same `notifications_enabled` flag.

**Behavior:**
- Single preference on the Profile tab — *"Daily review nudge"*. Tapping prompts the OS permission first; if denied, the toggle stays off and a calm snackbar explains how to enable it in system settings.
- The `AppShell` listens to `profileProvider` and `reviewQueueProvider`; any change triggers `NotificationsService.reschedule(hasDueReviews: ...)`. The scheduler cancels any pending nudge first, then schedules one for the next 7pm local time *only if there are concepts actually due*. Silent days (review queue empty) post no notification.
- Three message variants rotate by day-of-month so the line doesn't feel canned: *"A few concepts are ready for a refresh. 2 minutes?"* / *"Some things you've worked on are due for a quiet revisit."* / *"When you're ready — there's a small review waiting."* No counts (they'd go stale between scheduling and firing).
- Tap → opens the app. For this slice the landing is Home, where the revisit queue is visible. A future iteration can deep-link directly into a practice chat for the top due concept via the `'review_nudge'` payload.

### Platform setup (notifications)

- **iOS** `ios/Runner/Info.plist` already prompts at runtime via the plugin; no extra plist key is strictly required. To support critical-alert delivery later, add `UIBackgroundModes` with `remote-notification`.
- **Android** `android/app/src/main/AndroidManifest.xml`:
  - `<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />` (Android 13+)
  - `<uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM" />` and `<uses-permission android:name="android.permission.USE_EXACT_ALARM" />` if you want exact 7pm firing on Android 12+ (the plugin will fall back to `inexact` when these are missing — usually within ~15 min of target).
  - `<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />` so scheduled nudges survive a device reboot.
  - Add the plugin's reboot + scheduled receivers per the `flutter_local_notifications` README.

Without these declarations, the toggle still appears but the OS prompt will be denied silently on Android 13+, and reboots will clear pending nudges.

## Subscription & credits

Yve Plus, $X/month via Stripe Checkout. Calm monetization shape:

- **Free**: 10 chat turns per UTC day. Every other feature (scan, materials, voice, retention, recap, infer-profile) stays available — only the per-turn Claude calls are gated so the urgent-assignment learner can solve their problem without paying.
- **Plus**: unlimited turns. Same Yve, no quotas to count against.

Per-user state lives in `subscriptions` (current plan + Stripe IDs + period end) and `daily_usage` (per-day chat-turn counter). The shared helper `_shared/entitlements.ts` exposes `loadEntitlement` + `loadChatQuota` + `incrementChatTurns`; `yve-chat` runs them in this order:

1. Load entitlement (lazy-defaults to free/active for anonymous + new users)
2. Load today's chat quota; if exceeded, emit `{"type":"quota_exceeded","plan":"free","used":10,"limit":10,"reset_at":"..."}` and close the stream
3. Run the answer as normal
4. After streaming completes, `incrementChatTurns` bumps the counter (only on the free plan)

The client treats `quota_exceeded` as a typed event (not an error): the chat surface drops the empty Yve placeholder, restores the learner's draft into the input, and renders an inline `QuotaExceededCard` — *"You've used today's free turns. I reset tomorrow. Or unlock unlimited and stop counting."* with an "Unlock Yve Plus" button that opens `showUpgradeSheet`.

**Upgrade flow:**
- `EntitlementNotifier.launchCheckout()` calls `create-checkout-session`, gets a Stripe URL, opens it in the OS browser via `url_launcher`
- Stripe Checkout collects payment; on success it redirects to `STRIPE_SUCCESS_URL` (a static "thanks — return to the app" page)
- Stripe webhook fires `checkout.session.completed` → `stripe-webhook` upserts `subscriptions` with `plan='plus'`, `provider='stripe'`, and the Stripe IDs
- When the learner returns to the app, `AppShell.didChangeAppLifecycleState` fires on resume and calls `entitlementProvider.refresh()` — the next chat turn sees Plus

**Anonymous users** can't be charged (no stable identity to attach a subscription to). The upgrade sheet detects this and pivots the CTA to "Sign in to continue" — the existing auth sheet from slice 10 handles the link flow, then the learner returns and re-opens the upgrade sheet.

**Stripe configuration:**

- Create a recurring Price in the Stripe dashboard for the Yve Plus plan
- Set Supabase Edge Function secrets: `STRIPE_SECRET_KEY`, `STRIPE_PRICE_ID`, `STRIPE_WEBHOOK_SECRET`, `STRIPE_SUCCESS_URL`, `STRIPE_CANCEL_URL`
- Register the webhook endpoint in Stripe dashboard → Developers → Webhooks pointing at `https://<project>.supabase.co/functions/v1/stripe-webhook`
- Subscribe to events: `checkout.session.completed`, `customer.subscription.updated`, `customer.subscription.deleted`
- Deploy `stripe-webhook` with `--no-verify-jwt` (Stripe doesn't send a Supabase JWT; signature verification happens inside the function via `STRIPE_WEBHOOK_SECRET`)

**iOS App Store note:** Apple requires digital-content subscriptions to use Apple IAP via StoreKit. Production iOS builds will need a RevenueCat layer that talks to StoreKit on-device and pushes entitlement updates into the same `subscriptions` row (the `provider` column already accepts `'apple'`). That's a future slice; Stripe-only ships fine for web + Android.

## What's not built yet

- Google / Apple OAuth sign-in (email OTP works today)
- Cross-device data migration when signing into an existing account from a fresh anonymous device (today the anonymous draft data stays orphaned in Postgres)
- Cross-device + server-event push via FCM (local daily review nudges work today)
- Background auto-inference trigger (manual Refresh works today; periodic update lands later)
- Apple IAP via RevenueCat (Stripe Checkout works today on web + Android; iOS App Store deployment will need this)
- Stripe Customer Portal cancel / manage flow (cancellation today happens server-side via the Stripe dashboard)
