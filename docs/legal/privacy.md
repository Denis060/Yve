# Yve Privacy Policy

**Effective date:** 2026-05-17
**Last updated:** 2026-05-17

This Privacy Policy explains what data Yve collects, why we collect it,
who we share it with, and how you can control it. Yve is a calm AI
learning workspace for nursing, allied-health, and adult learners. We
take your data seriously — most of what we collect exists only to make
Yve actually work for you.

> **Plain-English summary.** When you use Yve we store your account,
> the subjects you organize, the materials you upload, and the chats
> you have with Yve. We send those chats to Anthropic so Claude can
> respond. If you upgrade, Stripe handles your payment. You can ask us
> to delete your account at any time and we will — within 30 days,
> permanently.

---

## 1. Who we are

Yve is operated by Yve ("we", "us"). For privacy questions or
account-deletion requests, reach us at **hello@getyve.com**.

---

## 2. What we collect

### Information you give us

- **Account info.** Email address (and, optionally, your display
  name). If you sign in with Google or Apple, we receive your email
  and basic profile info from that provider.
- **Learning content.** Subjects you create, materials you upload
  (PDFs, images, URLs), notes, drafts, and chat messages you send
  to Yve.
- **Voice input.** When you tap the microphone, audio is processed by
  your device's built-in speech-to-text (Apple Speech / Google STT).
  Yve receives the resulting text. We do not store the audio.
- **Camera input.** When you use the Scan feature, the captured image
  is sent to Yve's servers for text extraction, then attached to that
  scan's chat session for context. We do not use scan images for any
  other purpose.
- **Billing info.** If you subscribe to Pro, Stripe collects your
  payment card information directly. We never see your card number; we
  receive only a Stripe customer ID and subscription metadata.

### Information collected automatically

- **Usage events.** Counters of how many chats, scans, and polish runs
  you've used (to enforce plan limits) and whether you've hit a cap.
- **Email delivery events.** When we send you an email (welcome, trial
  reminders, payment receipts), Resend tells us whether it was
  delivered, opened, or marked as spam. We use this to know whether
  to keep sending you that type of email.
- **Authentication state.** Cookies and local storage on the web; the
  Supabase SDK's secure storage on mobile. These keep you signed in.

### Information we do NOT collect

- We do not embed third-party advertising trackers.
- We do not sell your data to anyone, ever.
- We do not train AI models on your conversations. Anthropic's API
  terms preclude using API inputs/outputs for training (as of the
  effective date above), and we do not enroll in any opt-in training
  programs.

---

## 3. Why we collect it (legal bases under GDPR)

| Purpose | Lawful basis |
|---|---|
| Run your account and let you study | Contract (Article 6(1)(b)) |
| Send AI responses through Anthropic / Voyage | Contract |
| Enforce plan limits | Legitimate interests + Contract |
| Bill you for Pro through Stripe | Contract |
| Send transactional email (receipts, trial endings) | Contract |
| Send optional continuity / recap email | Consent (you can opt out) |
| Comply with legal requests | Legal obligation |

If you're in the EU/EEA/UK and we ever rely on consent for something,
you can withdraw it at any time without affecting the lawfulness of
prior processing.

---

## 4. Who we share it with

Yve uses a small set of carefully chosen third parties. Each one
processes a specific slice of your data for the purpose listed below.
Nothing else is shared.

| Provider | Data shared | Why |
|---|---|---|
| **Supabase** (Postgres + Auth + Storage) | Account, subjects, materials, chat history, usage events | Stores your account and everything you create in Yve. Hosted in the United States. |
| **Anthropic** (Claude API) | Chat messages and study-context they reference | Generates Yve's responses. Anthropic's terms preclude training on API data. |
| **Voyage AI** (embeddings) | Snippets of your uploaded materials | Builds the search index that lets Yve retrieve relevant material in your subjects. |
| **Stripe** (payments) | Email, payment card, billing address, subscription status | Handles Pro subscriptions. Stripe is PCI-DSS certified. |
| **Resend** (transactional email) | Email address, subject line of message, delivery/open/click events | Sends transactional and continuity emails. |
| **Google / Apple** (OAuth, optional) | Whatever you authorize during sign-in (email + name only) | Lets you sign in without a password. |

We do not sell your data. We do not share your data for advertising.
If we ever change this, we will notify you before it takes effect and
give you the option to delete your account first.

---

## 5. How long we keep it

| Data | Retention |
|---|---|
| Account, subjects, materials, chats | Until you delete your account, then permanently within 30 days |
| Anonymous (guest) session data | Until claimed by a sign-in OR 90 days of inactivity, whichever first |
| Usage events | 24 months, for cap auditing and plan tuning |
| Stripe billing records | Retained by Stripe per their terms (typically 7 years for tax compliance) |
| Email delivery events | 24 months |
| Backups | Encrypted, rolling 30 days |

Account deletion removes your data from active systems immediately and
from backups within the rolling backup window above.

---

## 6. Your rights

Wherever you live, you can:

- **Access** the data we hold about you — email us and we'll send you a
  machine-readable export.
- **Correct** anything inaccurate via the in-app Profile screen, or by
  emailing us.
- **Delete** your account and all associated data via the in-app
  Profile screen, or by emailing us.
- **Object to** or **restrict** processing for any optional category
  (continuity emails, recap emails) via the in-app notification
  settings.
- **Withdraw consent** at any time where we rely on consent.
- **Lodge a complaint** with your supervisory authority (e.g. an EU/UK
  data protection authority) if you believe we've mishandled your data.

For California residents under the **CCPA**, the same rights apply
under the labels "right to know," "right to delete," "right to opt-out
of sale" (we don't sell, so this is moot), and the right not to be
discriminated against for exercising any of these rights.

To exercise any right, email **hello@getyve.com**. We aim to respond
within 14 days and will not charge you for it.

---

## 7. Cookies and local storage

Yve uses cookies and local storage for:

- **Authentication.** Keeping you signed in (essential).
- **PKCE flow state.** Securing OAuth round-trips (essential).
- **Stripe Checkout.** Stripe sets cookies on its own domain during
  payment — see [Stripe's cookie policy](https://stripe.com/cookies-policy/legal).

Yve does not use cookies for advertising or third-party tracking.

---

## 8. Children

Yve is intended for use by adults and post-secondary students. We do
not knowingly collect personal information from children under 13 (16
in the EU/UK). If you believe a child has created a Yve account,
email hello@getyve.com and we will delete it.

---

## 9. International transfers

Yve's services are hosted in the United States. By using Yve you
acknowledge that your data will be transferred to and processed in the
US. Where required (EU/EEA/UK), we rely on the **Standard Contractual
Clauses** with our processors as the lawful basis for such transfers.

---

## 10. Security

Your data is encrypted in transit (TLS) and at rest (provider-managed
disk encryption on Supabase). Access to production data is limited to
authorized staff for support and operations purposes, audited via
provider access logs. We follow industry-standard practices but no
system is perfectly secure; if a breach affects your data, we will
notify you without undue delay (within 72 hours where GDPR applies).

---

## 11. Changes to this policy

If we make material changes, we'll update the "Last updated" date at
the top and notify you in-app or by email at least 14 days before the
change takes effect.

---

*Questions? Email **hello@getyve.com**.*
