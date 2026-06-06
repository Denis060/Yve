# Deploy `app.getyve.com` on Vercel

End-to-end setup: build Yve web, deploy to Vercel, point your subdomain
at it. ~15 minutes the first time.

After this lands you get four things for free:
1. The Yve web app live at `https://app.getyve.com`
2. Privacy + Terms hosted at `https://app.getyve.com/legal/privacy`
   and `/legal/terms` — real URLs you can submit to Stripe and Play Store
3. `assetlinks.json` served at `/.well-known/assetlinks.json` — the
   file Google needs to verify Yve owns the domain for App Links
   (fixes the Google OAuth Samsung Internet hang for every user)
4. Stripe `success_url` / `cancel_url` on a real HTTPS domain

---

## 1. Install the Vercel CLI (one-time)

```powershell
npm install -g vercel
```

Verify: `vercel --version`.

---

## 2. Log in to Vercel

```powershell
vercel login
```

Opens a browser, sign in with whatever account hosts your other apps.

---

## 3. Deploy the Yve web build

We pre-build locally (Vercel doesn't bundle Flutter natively). The
helper script handles the Flutter build PLUS copies in the static
files Flutter's web build skips (.well-known/, legal/, vercel.json).

```powershell
# Build (handles --base-href quirks + copies static files)
& C:\Apps\StudyBuddy\mobile\scripts\build-web.ps1

# Deploy
cd C:\Apps\StudyBuddy\mobile\build\web

# First deploy (creates the project). Answer the prompts:
#   - "Set up and deploy?"          → yes
#   - "Which scope?"                → your personal/team
#   - "Link to existing project?"   → no (first time)
#   - "What's your project's name?" → yve-app
#   - "In which directory?"         → . (current dir)
#   - "Override settings?"          → no
vercel

# Subsequent deploys to production:
vercel --prod
```

The first command prints a preview URL like
`https://yve-app-abc123.vercel.app`. Open it — Yve should load.

---

## 4. Wire `app.getyve.com` to the deployment

### 4a. In Vercel

Vercel dashboard → your `yve-app` project → **Settings** → **Domains**
→ enter `app.getyve.com` → **Add**.

Vercel shows you the exact DNS record to add. It looks like:

```
Type:  CNAME
Name:  app
Value: cname.vercel-dns.com
```

(The exact value Vercel shows is authoritative — use that, not this.)

### 4b. In Hostinger DNS

Hostinger control panel → **Domains** → `getyve.com` → **DNS / Nameservers**
→ **Manage DNS records** → **Add record**:

| Field | Value |
|---|---|
| Type | `CNAME` |
| Name | `app` |
| Target / Value | `cname.vercel-dns.com` (whatever Vercel showed) |
| TTL | `3600` (or default) |

**Save**.

### 4c. Wait for DNS

Usually 1–5 minutes on Hostinger. Vercel auto-issues a Let's Encrypt
SSL certificate as soon as DNS resolves; the green checkmark in
Vercel's Domains panel means you're live.

Test: open `https://app.getyve.com` in a browser. You should see Yve.

---

## 5. Verify the supporting files are reachable

```
https://app.getyve.com/.well-known/assetlinks.json
https://app.getyve.com/legal/privacy
https://app.getyve.com/legal/terms
```

All three should load. `assetlinks.json` should return JSON; the legal
URLs should render styled HTML pages.

If any 404s, check:
- Did `mobile/web/.well-known/assetlinks.json` make it into the build
  output? `ls mobile/build/web/.well-known/`
- Did `mobile/web/legal/privacy.html` make it? `ls mobile/build/web/legal/`
- Is `mobile/web/vercel.json` in the build? `ls mobile/build/web/vercel.json`

If any of those are missing, the Flutter web build skipped them — they
need to be re-added to `mobile/web/` and rebuilt.

---

## 6. Update Supabase and Stripe

Once `https://app.getyve.com` is live, do these in Supabase (I can run
them via the Management API on request — just say the word):

1. Add `https://app.getyve.com` and `https://app.getyve.com/**` to
   Auth → URL Configuration → Redirect URLs allow-list.
2. Update `site_url` to `https://app.getyve.com`.

And in Google Cloud Console:

3. OAuth client → Authorized JavaScript origins → add
   `https://app.getyve.com`.

Stripe doesn't need any change — the Edge Function picks the success
URL from the platform-aware helper in `entitlement_service.dart`. Once
the domain is live the web flow uses `${Uri.base.origin}/upgrade/success`
which resolves to the right place automatically.

---

## 7. Ongoing deploys

After making changes to the Flutter app:

```powershell
cd C:\Apps\StudyBuddy\mobile
# Build
& "C:\Users\fofan\Downloads\flutter_windows_3.41.9-stable\flutter\bin\flutter.bat" `
  build web --release `
  --dart-define-from-file=dart_defines.json `
  --base-href=/

# Deploy
cd build\web
vercel --prod
```

Should take ~30 seconds end-to-end after the first time.

If you want **automatic deploys on `git push`**, connect the GitHub
repo via Vercel → Project → Settings → Git, and add a build script
that runs the Flutter web build before Vercel takes over. That's a
separate setup — leave it manual for now.

---

## Troubleshooting

**"Domain has not been added"** in Vercel after DNS change
DNS hasn't propagated yet. Wait 5 more minutes. Verify with:
`nslookup app.getyve.com`

**`assetlinks.json` returns HTML instead of JSON**
The SPA fallback rewrite matched it. Check `mobile/web/vercel.json` —
the rewrite rule excludes `/.well-known/` paths.

**Yve loads but shows "Network error" or fails to talk to Supabase**
The build was missing dart-defines. Re-run the build command with
`--dart-define-from-file=dart_defines.json` and verify
`mobile/build/web/main.dart.js` is non-empty.

**Camera / mic don't work on `app.getyve.com`**
They require HTTPS (which Vercel provides automatically). If you're
testing via `vercel dev` locally you'll get HTTP — that's expected;
test the deployed URL instead.
