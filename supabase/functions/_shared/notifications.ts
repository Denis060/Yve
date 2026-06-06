// notify() — the single chokepoint for everything Yve sends.
//
// Every email, in-app banner, and future push notification flows
// through this function. Product code calls:
//
//   await notify(userId, 'trial_ending_24h', { trial_end });
//
// notify() then:
//   1. Looks up the event's registry entry → category, channels, copy.
//   2. Loads the user's notification_preferences.
//   3. Applies per-category opt-in/opt-out, quiet hours, and frequency
//      caps. Each gate that drops the message writes a notification_events
//      row with the right `status` so we can audit later.
//   4. For surviving channels: sends to Resend (email) and/or writes
//      an in_app_notifications row (future, stubbed today).
//   5. Records the final outcome.
//
// Adding a new notification = add an entry to EVENT_REGISTRY below.
// Nothing else changes. The router doesn't care what the event is.

import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';

import { getServiceClient } from './service_client.ts';

// ─────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────

export type Category = 'transactional' | 'continuity' | 'recap' | 'async';
export type Channel = 'email' | 'in_app';

export type EventType =
  | 'magic_link'
  | 'trial_started'
  | 'trial_ending_24h'
  | 'trial_converted'
  | 'payment_failed'
  | 'subscription_canceled'
  | 'polish_complete'
  | 'materials_processed'
  | 'session_idle_3d'
  | 'mid_semester_checkin'
  | 'semester_recap';

export type Status =
  | 'sent'
  | 'partial'
  | 'skipped_preference'
  | 'skipped_frequency'
  | 'skipped_quiet_hours'
  | 'skipped_suppressed'
  | 'failed';

export interface NotifyResult {
  eventId: number | null;
  status: Status;
  channelsAttempted: Channel[];
  error?: string;
}

/// Compose the user-facing strings for an event. Pure function — no
/// templating yet (we'll move to React Email / MJML in Phase 6.2).
/// Returns nulls for channels that don't apply.
export interface RenderedEvent {
  email?: {
    subject: string;
    /// Minimal HTML — short body, big code if any, single calm tone.
    html: string;
    /// Plain-text fallback. Often the html stripped of tags is fine.
    text: string;
  };
  inApp?: {
    title: string;
    body: string;
    /// Optional deep link the in-app card opens when tapped.
    actionPath?: string;
  };
}

interface EventConfig {
  category: Category;
  channels: Channel[];
  /// Per-event hard cap above the category cap. Most events use the
  /// category default (defined in FREQUENCY_CAPS). A few special-case
  /// events override (e.g. magic_link has no cap — it's invited).
  perEventCapPer7Days?: number | null;
  /// Render the event into user-facing text. Pure — no I/O.
  render: (payload: Record<string, unknown>) => RenderedEvent;
}

// ─────────────────────────────────────────────────────────────────────
// Event registry — the single place new notifications get defined
// ─────────────────────────────────────────────────────────────────────

const SIGN_OFF_TEXT = '— Yve ✦';

const codeBlock = (token: string) =>
  `<p style="font-family: 'SFMono-Regular', Menlo, Consolas, monospace; ` +
  `font-size: 28px; letter-spacing: 8px; font-weight: 600; margin: 24px 0;">` +
  `${escapeHtml(token)}</p>`;

const wrap = (innerHtml: string) =>
  // Single-column, no banner, no images. Reads cleanly in plain-text
  // clients too. The ✦ is the only visual mark.
  `<div style="font-family: -apple-system, system-ui, sans-serif; ` +
  `font-size: 15px; line-height: 1.55; color: #1a1a2e; max-width: 540px;">` +
  innerHtml +
  `<p style="color:#6b7280; font-size: 13px; margin-top: 32px;">${SIGN_OFF_TEXT}</p>` +
  `</div>`;

export const EVENT_REGISTRY: Record<EventType, EventConfig> = {
  // ── transactional (no opt-out, no quiet hours, no cap) ──────────
  magic_link: {
    category: 'transactional',
    channels: ['email'],
    perEventCapPer7Days: null, // user-invited, never throttled
    render: (p) => {
      const code = (p.code as string) ?? '';
      return {
        email: {
          subject: 'Your Yve sign-in code',
          html: wrap(
            `<p>Welcome back to Yve.</p>` +
              `<p>Your sign-in code:</p>` +
              codeBlock(code) +
              `<p>This code expires in 10 minutes.</p>`,
          ),
          text:
            `Welcome back to Yve.\n\n` +
            `Your sign-in code: ${code}\n\n` +
            `This code expires in 10 minutes.\n\n${SIGN_OFF_TEXT}`,
        },
      };
    },
  },

  trial_started: {
    category: 'transactional',
    channels: ['email'],
    render: (p) => {
      const planLabel = (p.plan_label as string) ?? 'Pro';
      const trialEnd = p.trial_end_human as string | undefined;
      const endingLine = trialEnd
        ? `Your 3-day trial runs through <strong>${escapeHtml(trialEnd)}</strong>.`
        : 'Your 3-day trial is on the clock.';
      const endingLineText = trialEnd
        ? `Your 3-day trial runs through ${trialEnd}.`
        : 'Your 3-day trial is on the clock.';
      return {
        email: {
          subject: `Welcome to Yve ${planLabel}`,
          html: wrap(
            `<p>Welcome to Yve ${escapeHtml(planLabel)}.</p>` +
              `<p>${endingLine} If you stay, your card will be charged on day 3 — we'll send a reminder 24 hours before. If you'd rather not, cancel anytime in your account; your work stays put either way.</p>` +
              `<p>While your trial is active, you have:</p>` +
              `<ul>` +
                `<li>Unlimited daily chats and scans</li>` +
                `<li>Up to 10,000-word polish runs</li>` +
                `<li>Unlimited subjects to organize your semester</li>` +
              `</ul>` +
              `<p>Make Yve yours — add your subjects, drop in materials, and ask anything.</p>`,
          ),
          text:
            `Welcome to Yve ${planLabel}.\n\n` +
            `${endingLineText} If you stay, your card will be charged on day 3 ` +
            `— we'll send a reminder 24 hours before. If you'd rather not, cancel ` +
            `anytime in your account; your work stays put either way.\n\n` +
            `While your trial is active, you have:\n` +
            `  - Unlimited daily chats and scans\n` +
            `  - Up to 10,000-word polish runs\n` +
            `  - Unlimited subjects to organize your semester\n\n` +
            `Make Yve yours — add your subjects, drop in materials, and ask anything.\n\n${SIGN_OFF_TEXT}`,
        },
      };
    },
  },

  trial_ending_24h: {
    category: 'transactional',
    channels: ['email', 'in_app'],
    render: (p) => {
      const planLabel = (p.plan_label as string) ?? 'Pro';
      return {
        email: {
          subject: 'Your Yve trial ends tomorrow',
          html: wrap(
            `<p>Your 3-day trial of ${escapeHtml(planLabel)} ends tomorrow.</p>` +
              `<p>If you stay, your card will be charged then. If you'd rather not, you can cancel anytime before then in your account — no charge, your work stays where it is.</p>`,
          ),
          text:
            `Your 3-day trial of ${planLabel} ends tomorrow.\n\n` +
            `If you stay, your card will be charged then. If you'd rather not, ` +
            `you can cancel anytime before then in your account — no charge, ` +
            `your work stays where it is.\n\n${SIGN_OFF_TEXT}`,
        },
        inApp: {
          title: 'Trial ends tomorrow',
          body: `Your ${planLabel} trial wraps up in less than 24 hours.`,
          actionPath: '/settings/billing',
        },
      };
    },
  },

  trial_converted: {
    category: 'transactional',
    channels: ['email'],
    render: (p) => {
      const planLabel = (p.plan_label as string) ?? 'Pro';
      return {
        email: {
          subject: `You're on Yve ${planLabel}`,
          html: wrap(
            `<p>Your trial converted — welcome to Yve ${escapeHtml(planLabel)}.</p>` +
              `<p>Your work, your subjects, and your memory carry forward unchanged.</p>` +
              `<p>You can manage billing anytime in your account.</p>`,
          ),
          text:
            `Your trial converted — welcome to Yve ${planLabel}.\n\n` +
            `Your work, your subjects, and your memory carry forward unchanged.\n\n` +
            `You can manage billing anytime in your account.\n\n${SIGN_OFF_TEXT}`,
        },
      };
    },
  },

  payment_failed: {
    category: 'transactional',
    channels: ['email'],
    render: (_p) => ({
      email: {
        subject: 'A small hiccup with your Yve payment',
        html: wrap(
          `<p>Your last Yve payment didn't go through. Stripe will keep trying for the next 21 days.</p>` +
            `<p>In the meantime your work is safe and your access continues. The fastest fix is usually to update your card from your account.</p>`,
        ),
        text:
          `Your last Yve payment didn't go through. Stripe will keep trying ` +
          `for the next 21 days.\n\nIn the meantime your work is safe and ` +
          `your access continues. The fastest fix is usually to update your ` +
          `card from your account.\n\n${SIGN_OFF_TEXT}`,
      },
    }),
  },

  subscription_canceled: {
    category: 'transactional',
    channels: ['email'],
    render: (p) => {
      const until = (p.access_until as string) ?? 'the end of your period';
      return {
        email: {
          subject: 'Your Yve subscription has been canceled',
          html: wrap(
            `<p>Your Yve subscription is canceled. Your access continues through ${escapeHtml(until)}.</p>` +
              `<p>Your subjects, sessions, and polished drafts stay where they are. If you come back, everything will still be here.</p>`,
          ),
          text:
            `Your Yve subscription is canceled. Your access continues through ${until}.\n\n` +
            `Your subjects, sessions, and polished drafts stay where they are. ` +
            `If you come back, everything will still be here.\n\n${SIGN_OFF_TEXT}`,
        },
      };
    },
  },

  // ── async (invited) ────────────────────────────────────────────
  polish_complete: {
    category: 'async',
    channels: ['email', 'in_app'],
    render: (p) => {
      const preview = (p.preview as string) ?? 'your draft';
      return {
        email: {
          subject: 'Your polished draft is ready',
          html: wrap(
            `<p>Your polished version of "${escapeHtml(preview)}" is waiting in Yve.</p>`,
          ),
          text:
            `Your polished version of "${preview}" is waiting in Yve.\n\n${SIGN_OFF_TEXT}`,
        },
        inApp: {
          title: 'Polished draft ready',
          body: preview,
          actionPath: (p.session_path as string | undefined) ?? '/',
        },
      };
    },
  },

  materials_processed: {
    category: 'async',
    channels: ['email', 'in_app'],
    render: (p) => {
      const name = (p.material_name as string) ?? 'your material';
      return {
        email: {
          subject: `"${name}" is indexed and searchable`,
          html: wrap(
            `<p>Yve finished indexing "${escapeHtml(name)}". It's now searchable from any of your chats in Materials mode.</p>`,
          ),
          text:
            `Yve finished indexing "${name}". It's now searchable from any of your chats in Materials mode.\n\n${SIGN_OFF_TEXT}`,
        },
        inApp: {
          title: 'Materials indexed',
          body: name,
          actionPath: (p.subject_path as string | undefined) ?? '/',
        },
      };
    },
  },

  // ── continuity (Phase 6.2; copy here as placeholder) ───────────
  session_idle_3d: {
    category: 'continuity',
    channels: ['email'],
    render: (p) => {
      const subjectName = (p.subject_name as string) ?? 'your work';
      return {
        email: {
          subject: `${subjectName} — still on your mind?`,
          html: wrap(
            `<p>Your last session with ${escapeHtml(subjectName)} paused a few days ago.</p>` +
              `<p>Pick up exactly where you left off when you're ready.</p>`,
          ),
          text:
            `Your last session with ${subjectName} paused a few days ago.\n\n` +
            `Pick up exactly where you left off when you're ready.\n\n${SIGN_OFF_TEXT}`,
        },
      };
    },
  },

  mid_semester_checkin: {
    category: 'continuity',
    channels: ['email'],
    render: (p) => {
      const concept = (p.primary_concept as string) ?? 'what you\'ve been studying';
      return {
        email: {
          subject: 'A quick mid-semester check',
          html: wrap(
            `<p>You've been spending time on ${escapeHtml(concept)} lately.</p>` +
              `<p>Want me to build a focused review queue before midterms?</p>`,
          ),
          text:
            `You've been spending time on ${concept} lately.\n\n` +
            `Want me to build a focused review queue before midterms?\n\n${SIGN_OFF_TEXT}`,
        },
      };
    },
  },

  // ── recap (Phase 6.2 — the design pinnacle) ────────────────────
  semester_recap: {
    category: 'recap',
    channels: ['email'],
    render: (p) => {
      // Placeholder body; Phase 6.2 will rebuild this as the design
      // pinnacle email (template + concept-tag rollup).
      const subjectsCount = (p.subjects_count as number) ?? 0;
      const sessionsCount = (p.sessions_count as number) ?? 0;
      return {
        email: {
          subject: 'Your semester with Yve',
          html: wrap(
            `<p>This semester you and Yve worked through ${sessionsCount} sessions across ${subjectsCount} subjects.</p>` +
              `<p>A fuller look at what you built is waiting in the app.</p>`,
          ),
          text:
            `This semester you and Yve worked through ${sessionsCount} sessions across ${subjectsCount} subjects.\n\n` +
            `A fuller look at what you built is waiting in the app.\n\n${SIGN_OFF_TEXT}`,
        },
      };
    },
  },
};

// ─────────────────────────────────────────────────────────────────────
// Category defaults — frequency caps + quiet-hours respect
// ─────────────────────────────────────────────────────────────────────

interface CategoryRules {
  perCategoryCapPer7Days: number | null;
  respectsQuietHours: boolean;
  respectsPreference: boolean;
}

const CATEGORY_RULES: Record<Category, CategoryRules> = {
  transactional: {
    // Transactional emails are never throttled and never gated on
    // preference. Magic-link OTPs and billing dignity emails must
    // always go through.
    perCategoryCapPer7Days: null,
    respectsQuietHours: false,
    respectsPreference: false,
  },
  continuity: {
    // Hard cap: 1 continuity email per user per week. Cap is
    // intentionally tight; restraint is the strategy.
    perCategoryCapPer7Days: 1,
    respectsQuietHours: true,
    respectsPreference: true,
  },
  recap: {
    // Recap is at most ~3/year per user (one per term). The cap
    // exists as belt-and-braces against a misfiring scheduler.
    perCategoryCapPer7Days: 1,
    respectsQuietHours: true,
    respectsPreference: true,
  },
  async: {
    // Async-completion emails are invited (user took an action and
    // is waiting). Loose cap to prevent runaway if something goes
    // wrong server-side.
    perCategoryCapPer7Days: 5,
    respectsQuietHours: false,
    respectsPreference: true,
  },
};

// ─────────────────────────────────────────────────────────────────────
// Public API
// ─────────────────────────────────────────────────────────────────────

export interface NotifyOptions {
  /// Override the registry's channel list (e.g. force email-only
  /// even for an event configured to also go in-app).
  channels?: Channel[];
}

export async function notify(
  userId: string,
  eventType: EventType,
  payload: Record<string, unknown>,
  options: NotifyOptions = {},
): Promise<NotifyResult> {
  const config = EVENT_REGISTRY[eventType];
  if (!config) {
    return {
      eventId: null,
      status: 'failed',
      channelsAttempted: [],
      error: `unknown event_type: ${eventType}`,
    };
  }

  const svc = getServiceClient();
  const channelsPlanned = options.channels ?? config.channels;
  const rules = CATEGORY_RULES[config.category];

  // ── Resolve user email + preferences ─────────────────────────────
  const userEmail = await loadUserEmail(svc, userId);
  const prefs = await ensurePreferences(svc, userId);

  // Insert the event row up front so even skipped events are auditable.
  const eventRow = await insertEventRow(svc, {
    userId,
    eventType,
    category: config.category,
    payload,
    channelsPlanned,
  });

  // ── Gate: per-category preference ────────────────────────────────
  if (rules.respectsPreference && !prefs[config.category]) {
    await finalizeEvent(svc, eventRow.id, {
      status: 'skipped_preference',
      channelsAttempted: [],
    });
    return {
      eventId: eventRow.id,
      status: 'skipped_preference',
      channelsAttempted: [],
    };
  }

  // ── Gate: frequency cap ──────────────────────────────────────────
  // Exclude the just-inserted current event row from the count.
  // Without this, the count includes the placeholder ('sent') row we
  // just wrote, so even the first send in a category trips the cap.
  const effectiveCap = config.perEventCapPer7Days !== undefined
    ? config.perEventCapPer7Days
    : rules.perCategoryCapPer7Days;
  if (effectiveCap !== null) {
    const recent = await countRecentEvents(
      svc,
      userId,
      config.category,
      eventRow.id,
    );
    if (recent >= effectiveCap) {
      await finalizeEvent(svc, eventRow.id, {
        status: 'skipped_frequency',
        channelsAttempted: [],
      });
      return {
        eventId: eventRow.id,
        status: 'skipped_frequency',
        channelsAttempted: [],
      };
    }
  }

  // ── Gate: quiet hours ────────────────────────────────────────────
  if (rules.respectsQuietHours && isInQuietHours(prefs)) {
    await finalizeEvent(svc, eventRow.id, {
      status: 'skipped_quiet_hours',
      channelsAttempted: [],
    });
    return {
      eventId: eventRow.id,
      status: 'skipped_quiet_hours',
      channelsAttempted: [],
    };
  }

  // ── Render copy ──────────────────────────────────────────────────
  const rendered = config.render(payload);
  const channelsAttempted: Channel[] = [];
  const errors: string[] = [];

  // ── Email channel ────────────────────────────────────────────────
  if (channelsPlanned.includes('email') && rendered.email && userEmail) {
    if (await isEmailSuppressed(svc, userEmail)) {
      await finalizeEvent(svc, eventRow.id, {
        status: 'skipped_suppressed',
        channelsAttempted: [],
      });
      return {
        eventId: eventRow.id,
        status: 'skipped_suppressed',
        channelsAttempted: [],
      };
    }
    try {
      await sendEmail({
        svc,
        eventId: eventRow.id,
        userId,
        to: userEmail,
        subject: rendered.email.subject,
        html: rendered.email.html,
        text: rendered.email.text,
      });
      channelsAttempted.push('email');
    } catch (e) {
      errors.push(`email: ${(e as Error).message}`);
    }
  }

  // ── In-app channel (stubbed; ships fully with Phase 6.1) ─────────
  if (channelsPlanned.includes('in_app') && rendered.inApp && prefs.in_app) {
    // TODO(phase-6.1): write to in_app_notifications + trigger
    // local push via Realtime broadcast or FCM. For now we just
    // record that we *would* have sent.
    channelsAttempted.push('in_app');
  }

  // ── Finalize ─────────────────────────────────────────────────────
  let finalStatus: Status;
  if (channelsAttempted.length === 0 && errors.length > 0) {
    finalStatus = 'failed';
  } else if (channelsAttempted.length < channelsPlanned.length && errors.length > 0) {
    finalStatus = 'partial';
  } else {
    finalStatus = 'sent';
  }
  await finalizeEvent(svc, eventRow.id, {
    status: finalStatus,
    channelsAttempted,
    error: errors.length > 0 ? errors.join('; ') : undefined,
  });

  return {
    eventId: eventRow.id,
    status: finalStatus,
    channelsAttempted,
    error: errors.length > 0 ? errors.join('; ') : undefined,
  };
}

// ─────────────────────────────────────────────────────────────────────
// Internals
// ─────────────────────────────────────────────────────────────────────

interface PrefsRow {
  transactional: boolean;
  continuity: boolean;
  recap: boolean;
  async: boolean;
  in_app: boolean;
  timezone: string;
  quiet_hours_start: string; // 'HH:MM:SS'
  quiet_hours_end: string;
}

async function loadUserEmail(
  svc: SupabaseClient,
  userId: string,
): Promise<string | null> {
  try {
    const { data } = await svc.auth.admin.getUserById(userId);
    return data.user?.email ?? null;
  } catch (e) {
    console.error('loadUserEmail failed', e);
    return null;
  }
}

async function ensurePreferences(
  svc: SupabaseClient,
  userId: string,
): Promise<PrefsRow> {
  // Read or lazy-insert. Defaults match the column defaults in the
  // migration so a missing row = "use defaults".
  const { data } = await svc
    .from('notification_preferences')
    .select(
      'transactional, continuity, recap, async, in_app, timezone, quiet_hours_start, quiet_hours_end',
    )
    .eq('user_id', userId)
    .maybeSingle();
  if (data) return data as PrefsRow;
  await svc.from('notification_preferences').insert({ user_id: userId });
  return {
    transactional: true,
    continuity: true,
    recap: true,
    async: true,
    in_app: true,
    timezone: 'UTC',
    quiet_hours_start: '21:00:00',
    quiet_hours_end: '08:00:00',
  };
}

async function insertEventRow(
  svc: SupabaseClient,
  args: {
    userId: string;
    eventType: EventType;
    category: Category;
    payload: Record<string, unknown>;
    channelsPlanned: Channel[];
  },
): Promise<{ id: number }> {
  const { data, error } = await svc
    .from('notification_events')
    .insert({
      user_id: args.userId,
      event_type: args.eventType,
      category: args.category,
      payload: args.payload,
      channels_planned: args.channelsPlanned,
      status: 'sent', // overwritten by finalizeEvent
    })
    .select('id')
    .single();
  if (error || !data) {
    throw new Error(`notification_events insert failed: ${error?.message}`);
  }
  return { id: data.id as number };
}

async function finalizeEvent(
  svc: SupabaseClient,
  id: number,
  args: { status: Status; channelsAttempted: Channel[]; error?: string },
): Promise<void> {
  await svc
    .from('notification_events')
    .update({
      status: args.status,
      channels_attempted: args.channelsAttempted,
      error: args.error ?? null,
    })
    .eq('id', id);
}

async function countRecentEvents(
  svc: SupabaseClient,
  userId: string,
  category: Category,
  excludeEventId?: number,
): Promise<number> {
  const since = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString();
  let q = svc
    .from('notification_events')
    .select('*', { count: 'exact', head: true })
    .eq('user_id', userId)
    .eq('category', category)
    .in('status', ['sent', 'partial']) // skipped sends don't count
    .gte('created_at', since);
  if (excludeEventId !== undefined) {
    q = q.neq('id', excludeEventId);
  }
  const { count } = await q;
  return count ?? 0;
}

async function isEmailSuppressed(
  svc: SupabaseClient,
  email: string,
): Promise<boolean> {
  const { data } = await svc
    .from('email_suppression')
    .select('email')
    .eq('email', email.toLowerCase())
    .maybeSingle();
  return !!data;
}

function isInQuietHours(prefs: PrefsRow): boolean {
  try {
    // Compute current HH:MM in the user's timezone using Intl.
    const now = new Date();
    const fmt = new Intl.DateTimeFormat('en-GB', {
      timeZone: prefs.timezone,
      hour12: false,
      hour: '2-digit',
      minute: '2-digit',
    });
    const [hh, mm] = fmt.format(now).split(':').map(Number);
    const minutes = hh * 60 + mm;
    const startMin = hhmmToMinutes(prefs.quiet_hours_start);
    const endMin = hhmmToMinutes(prefs.quiet_hours_end);
    if (startMin === endMin) return false;
    // Quiet hours may wrap midnight (21:00 → 08:00).
    if (startMin < endMin) {
      return minutes >= startMin && minutes < endMin;
    } else {
      return minutes >= startMin || minutes < endMin;
    }
  } catch (e) {
    console.error('isInQuietHours failed (bad timezone?)', e);
    return false; // fail open — don't silently drop notifications
  }
}

function hhmmToMinutes(hhmmss: string): number {
  const [hh, mm] = hhmmss.split(':').map(Number);
  return hh * 60 + mm;
}

// ─────────────────────────────────────────────────────────────────────
// Email sending — Resend
// ─────────────────────────────────────────────────────────────────────

const RESEND_API = 'https://api.resend.com/emails';
const FROM_ADDRESS = Deno.env.get('RESEND_FROM') ?? 'Yve ✦ <yve@getyve.com>';
const REPLY_TO = Deno.env.get('RESEND_REPLY_TO') ?? 'hello@getyve.com';

async function sendEmail(args: {
  svc: SupabaseClient;
  eventId: number;
  userId: string;
  to: string;
  subject: string;
  html: string;
  text: string;
}): Promise<void> {
  const apiKey = Deno.env.get('RESEND_API_KEY');
  if (!apiKey) {
    // No-op in environments where Resend isn't configured yet. We
    // still log the event row so the audit trail captures the
    // intent. Dev: visible via developer.log.
    console.warn(
      `[notify] RESEND_API_KEY not set — would have sent "${args.subject}" to ${args.to}`,
    );
    await args.svc.from('email_send_log').insert({
      event_id: args.eventId,
      user_id: args.userId,
      to_email: args.to,
      subject: args.subject,
      state: 'failed',
      state_detail: 'RESEND_API_KEY not configured',
    });
    throw new Error('RESEND_API_KEY not configured');
  }

  const res = await fetch(RESEND_API, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      from: FROM_ADDRESS,
      reply_to: REPLY_TO,
      to: [args.to],
      subject: args.subject,
      html: args.html,
      text: args.text,
    }),
  });
  if (!res.ok) {
    const body = await res.text();
    await args.svc.from('email_send_log').insert({
      event_id: args.eventId,
      user_id: args.userId,
      to_email: args.to,
      subject: args.subject,
      state: 'failed',
      state_detail: body.slice(0, 500),
    });
    throw new Error(`Resend ${res.status}: ${body.slice(0, 200)}`);
  }
  const data = await res.json() as { id?: string };
  await args.svc.from('email_send_log').insert({
    event_id: args.eventId,
    user_id: args.userId,
    resend_id: data.id ?? null,
    to_email: args.to,
    subject: args.subject,
    state: 'sent',
  });
}

// ─────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}
