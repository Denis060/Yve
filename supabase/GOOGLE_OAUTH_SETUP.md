# Google OAuth — setup for Yve

Wire "Continue with Google" so it actually signs users in instead of
returning *"Google sign-in isn't available yet."*

Total time: **~10 minutes**. No payment needed (Google Cloud's free
tier covers OAuth client creation indefinitely).

Three steps:
1. Google Cloud Console → create OAuth client → get `client_id` + `client_secret`
2. Supabase Dashboard → Auth → Providers → Google → paste credentials → toggle on
3. (Optional) Hand the credentials to me and I'll do step 2 via the Management API

---

## 1. Create the OAuth client in Google Cloud

### a) Create or pick a Google Cloud project

[console.cloud.google.com](https://console.cloud.google.com) → top-left
project picker → **New Project** if needed → name it `yve-auth` (or
anything).

### b) Configure the OAuth consent screen

Left sidebar → **APIs & Services** → **OAuth consent screen**:

| Field | Value |
|---|---|
| **User type** | External (anyone with a Google account can sign in) |
| **App name** | `Yve` |
| **User support email** | your email |
| **App logo** | optional — upload Yve's ✦ mark if you want |
| **App domain** | `getyve.com` |
| **Developer contact email** | your email |

**Scopes**: click **Add or remove scopes** → check `.../auth/userinfo.email`
and `.../auth/userinfo.profile` (and `openid`). These are the basic
sign-in scopes; nothing more needed.

**Test users**: while the app is in "Testing" state, only test users
you list here can sign in. Add your own Google email + any teammates.
You'll move to "Production" before public launch (one-click; no review
needed for basic scopes).

Save and continue through each step.

### c) Create the OAuth client ID

Left sidebar → **APIs & Services** → **Credentials** → **+ Create
Credentials** → **OAuth client ID**.

| Field | Value |
|---|---|
| **Application type** | Web application |
| **Name** | `Yve web` |
| **Authorized JavaScript origins** | `http://localhost:5173` (dev) and `https://app.getyve.com` (prod when ready) |
| **Authorized redirect URIs** | `https://ftekdhcomxxhbihvsyyw.supabase.co/auth/v1/callback` |

The redirect URI is the most-common-mistake. It MUST point at
Supabase's callback endpoint — Supabase handles the OAuth round-trip
and then forwards the user back to the app via the `redirectTo` we
pass from Flutter. Don't put your app URL here.

Click **Create**. Google shows a modal with your **Client ID** and
**Client Secret**. Copy both — you'll paste them into Supabase next.

---

## 2. Enable Google in Supabase

### Option A — via Supabase Dashboard (recommended)

1. Supabase Dashboard → **Authentication** → **Providers** → **Google**
2. Toggle **Enable Sign in with Google** → ON
3. Paste **Client ID (for OAuth)** = the Google client ID from step 1c
4. Paste **Client Secret (for OAuth)** = the Google secret from step 1c
5. **Authorized Client IDs** = leave blank (web flow doesn't need it)
6. **Skip nonce check** = leave OFF
7. Click **Save**

That's it. The button works immediately — no app restart needed.

### Option B — via Management API (I can do this)

Paste me both values and I'll PATCH the auth config:

```bash
curl -X PATCH "https://api.supabase.com/v1/projects/$REF/config/auth" \
  -H "Authorization: Bearer $PAT" \
  -H "Content-Type: application/json" \
  -d '{
    "external_google_enabled": true,
    "external_google_client_id": "<the client id>",
    "external_google_secret": "<the client secret>"
  }'
```

---

## 3. Smoke test

1. In the app, sign out (so you're back to anonymous)
2. Trigger the auth panel — easiest path: tap **Profile** → "Sign in to save your work" → **Continue with Google**
3. Google's account picker opens
4. Pick your account → redirected back to `localhost:5173` with the new session
5. Verify in Supabase: **Authentication** → **Users** — you should see your real account, no longer anonymous

If you went through the AnonymousContinuationPanel (after hitting a cap), the same Google account picker shows up. After confirm, your guest work carries forward via `linkIdentity` — no data migration.

---

## 4. Going to production

When you have `app.getyve.com` live:

1. Google Cloud → Credentials → your OAuth client → add `https://app.getyve.com` to **Authorized JavaScript origins**
2. OAuth consent screen → **Publish app** (moves from Testing → In production). For basic scopes (email/profile/openid) Google doesn't require a verification review, so this is a one-click change.
3. Test the production flow.

---

## Troubleshooting

**"Google sign-in isn't available yet. Use email instead."**
The Google provider isn't enabled in Supabase. Re-check step 2.

**"redirect_uri_mismatch" error from Google**
The URI in step 1c doesn't exactly match what Supabase sends. It MUST be:
`https://ftekdhcomxxhbihvsyyw.supabase.co/auth/v1/callback`
(no trailing slash, exact project ref).

**"This app isn't verified" warning during sign-in**
Normal while in "Testing" state. You + your test users can click
"Advanced → Continue to Yve" to proceed. The warning goes away
after **Publish app** in step 4.

**Sign-in succeeds but the app shows the same anonymous user**
The session probably hadn't refreshed yet. The
`EntitlementNotifier` listens to `onAuthStateChange` and should pick
it up automatically; if not, hot-reload to force-refresh.
