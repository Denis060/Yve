# Yve legal docs

Starter Privacy Policy and Terms of Service, tailored to Yve's actual
data practices (Supabase + Anthropic + Voyage + Stripe + Resend).

## Files

- `privacy.md` — Privacy Policy
- `terms.md`   — Terms of Service

## Important

**These are not legal advice.** They're a defensible baseline written
to match what Yve actually collects and how it actually works. Before
public launch, run them past a lawyer in your jurisdiction — they may
want to tweak retention windows, dispute resolution, governing law,
or add jurisdiction-specific clauses (GDPR Article 28 DPA for EU
processors, CCPA-specific opt-out links for California, etc.).

## Required URLs

Each of these external services needs a public URL pointing at
`privacy.md` and `terms.md`:

| Where | What it needs | Notes |
|---|---|---|
| **Play Console** (Yve listing) | Privacy URL | Required to publish |
| **App Store Connect** (when iOS lands) | Privacy URL | Required to submit |
| **Stripe Dashboard** | Both URLs | Required to enable live mode |
| **Resend Dashboard** | Privacy URL | For email-list compliance |
| **OAuth consent screens** (Google) | Both URLs | Required at production |

## Hosting options

1. **GitHub Pages** — push this repo (or a public mirror) and enable
   Pages on the `docs/` folder. URLs become
   `https://<user>.github.io/<repo>/legal/privacy` etc.
2. **Vercel / Netlify** — drop the `docs/legal/` folder into a new
   project, get a free `*.vercel.app` URL.
3. **Your own domain** — when `app.getyve.com` is live, host these
   under `/legal/privacy` and `/legal/terms`.
4. **Standalone gist** — paste each file into a public GitHub Gist
   and use those URLs (fastest, ugliest).

Anywhere is fine as long as the URL is stable. Don't change the URL
after submitting to a service — they cache it.

## Updating

When you update either file, bump the "Last updated" date at the top
and notify users in-app or by email (see §11 of Privacy / §14 of
Terms). The 14-day notice window is baked in.
