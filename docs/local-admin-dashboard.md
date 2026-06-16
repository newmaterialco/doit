# Local admin dashboard

Operator-facing web UI for doit: user list, usage stats, invite code
management, and one-click code generation. No build step — a single static
HTML file talks to a Supabase Edge Function.

**Files:**

| Path | Role |
| --- | --- |
| [`admin/index.html`](../admin/index.html) | Dashboard UI (open in any browser) |
| [`supabase/functions/admin/index.ts`](../supabase/functions/admin/index.ts) | JSON API (`summary`, `users`, `invites`, `feedback`, `tasks`, `create_invite`) |
| [`supabase/migrations/20240601000027_admin_user_stats.sql`](../supabase/migrations/20240601000027_admin_user_stats.sql) | Postgres RPCs for aggregates |
| [`supabase/migrations/20240601000030_admin_todos_list.sql`](../supabase/migrations/20240601000030_admin_todos_list.sql) | Paginated task list RPC |

## Quick start

1. **Deploy once** (if not already done — see [First-time deploy](#first-time-deploy)).
2. Open [`admin/index.html`](../admin/index.html) in a browser (double-click
   from Finder, or `open admin/index.html`).
3. On the login screen, enter:
   - **Admin secret** — the `ADMIN_SECRET` Edge Function secret (not the
     Supabase service_role key).
   - **Function URL** — defaults to
     `https://qjeutitqgdsasccxfxdy.supabase.co/functions/v1/admin` for the
     live project; change if you use another Supabase project.
4. Click **Open dashboard**. The secret is stored in `sessionStorage` for
   this browser tab session only.
5. Click **Lock** when finished to clear the secret from the browser.

## What you can do

### Overview

Summary cards at the top:

- **Users** — accounts in `auth.users`
- **Provisioned** — rows in `user_hermes` (agent ready)
- **Todos** — total tasks across all users
- **Total tokens** — sum of `todos.total_tokens`
- **Pending provision** — `user_provisioning` in `pending` or `provisioning`
- **Unused invites** — codes with `use_count = 0` and not expired
- **Exhausted codes** — codes where `use_count >= max_uses`
- **Feedback** — total beta feedback submissions
- **Feedback (7d)** — submissions in the last 7 days

### Feedback

Beta users submit feedback from **Settings → Feedback** in the iOS app.

| Column | Meaning |
| --- | --- |
| **When** | Submission timestamp |
| **Message** | User's report (truncated in table; full text in hover title) |
| **User** | Supabase user id prefix |
| **Email** | Contact email if the user opted in; otherwise "Not shared" |
| **Device** | App version and iOS version |

### Tasks

Browse every todo users have created — what they asked Doit to do, when, and
by whom. Loads independently from the rest of the dashboard (50 per page).

| Column | Meaning |
| --- | --- |
| **Created** | `todos.created_at` |
| **User** | Sign-in email from `auth.users` |
| **Request** | Raw prompt (`original_title`, falling back to `title`); hover for full text and preparation summary |
| **Status** | Current todo status |
| **Integration** | Composio toolkit slug if the prep phase picked one (e.g. `gmail`) |
| **Tokens** | `todos.total_tokens` for that task |

**Filters:** text search (prompt or preparation summary), user, status,
integration slug. **Clear** resets all filters. **Previous** / **Next**
paginate through the full result set.

Operator-only: same privacy model as Feedback — you see verbatim user
prompts to understand product usage during beta.

### Invite codes

The invite table shows every row in `invite_codes` plus who redeemed each code.

| Column | Meaning |
| --- | --- |
| **Code** | The invite string users enter in the iOS onboarding screen |
| **Status** | `Unused`, `Partial`, `Exhausted`, or `Expired` |
| **Uses** | `use_count / max_uses` (e.g. `1/1`, `3/10`) |
| **Note** | Operator label you set when minting |
| **Expires** | Optional expiry date |
| **Created** | When the code was minted |
| **Redeemers** | Email, provisioning status, and redemption time for each user who used this code |

**Filter:** All / Unused only / Used only.

**Generate code:** Fill optional note, max uses (default 1), and optional
expiry, then click **Generate code**. New codes look like `DOIT-XXXXXXXX`
(auto-generated). Use **Copy** on the banner to share the code.

Redemption data comes from `user_provisioning.invite_code` joined to
`auth.users.email`. Users provisioned manually before invite codes existed
may have no code in this table.

### Users

Per-user row merged from Auth + Postgres aggregates:

| Column | Source |
| --- | --- |
| **Email** | Sign in with Apple (may be a private relay address) |
| **Signed up** | `auth.users.created_at` |
| **Provisioning** | `user_provisioning.status` (`ready`, `failed`, …) |
| **Invite used** | Code they redeemed, if any |
| **Profile** | Hermes profile name (`user_hermes.profile_name`) |
| **Todos** | Done / total (failed count in parentheses) |
| **Tokens** | Sum of `todos.total_tokens` for that user |
| **Last active** | Latest `todos.updated_at` |

Rows with **failed** provisioning are highlighted.

## First-time deploy

From the repo root, with the Supabase CLI linked to your project:

```bash
supabase db push
supabase functions deploy admin
supabase secrets set ADMIN_SECRET="$(openssl rand -hex 24)"
```

Save the secret somewhere safe (password manager). It is **not** stored in
the repo. To rotate:

```bash
supabase secrets set ADMIN_SECRET="<new secret>"
```

Then re-enter the new value in the dashboard login screen.

The admin function also needs `SUPABASE_SERVICE_ROLE_KEY` (same as other
Edge Functions). That is usually already set if `onboarding` works.

### Updating the dashboard

After pulling admin dashboard changes (new RPC or Edge Function action):

```bash
supabase db push                                    # applies pending migrations
supabase functions deploy admin
```

No runner deploy, iOS rebuild, or secret rotation needed unless this is a
fresh project.

## API reference (for debugging)

All actions are `POST` to the function URL with JSON body `{ "action": "…" }`.

**Headers required:**

| Header | Value |
| --- | --- |
| `Content-Type` | `application/json` |
| `Authorization` | `Bearer <anon key>` |
| `apikey` | `<anon key>` (same as iOS app — public, RLS-scoped) |
| `X-Admin-Secret` | Your `ADMIN_SECRET` |

**Actions:**

| Action | Body | Response |
| --- | --- | --- |
| `summary` | — | Counts for dashboard overview |
| `users` | — | `{ users: [...] }` |
| `invites` | — | `{ invites: [...] }` with `status` and `redeemers` |
| `feedback` | — | `{ feedback: [...] }` (latest 200, newest first) |
| `tasks` | `limit?`, `offset?`, `search?`, `status?`, `user_id?`, `connection_slug?` | `{ tasks: [...] }` (paginated, newest first; each row includes `total_count`) |
| `create_invite` | `note?`, `max_uses?`, `expires_at?`, `code?` | `{ invite: {...} }` |

Example (replace secret and use your project anon key):

```bash
curl -s -X POST "https://qjeutitqgdsasccxfxdy.supabase.co/functions/v1/admin" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <anon>" \
  -H "apikey: <anon>" \
  -H "X-Admin-Secret: <ADMIN_SECRET>" \
  -d '{"action":"summary"}'
```

List tasks (paginated, optional filters):

```bash
curl -s -X POST "https://qjeutitqgdsasccxfxdy.supabase.co/functions/v1/admin" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <anon>" \
  -H "apikey: <anon>" \
  -H "X-Admin-Secret: <ADMIN_SECRET>" \
  -d '{"action":"tasks","limit":50,"offset":0,"search":"email","status":"done"}'
```

## Security notes

- **`ADMIN_SECRET`** is the only operator credential. Do not commit it,
  paste it in Slack, or ship it in the iOS app.
- The **anon key** in the HTML is public (same as the iOS binary). It only
  satisfies the Supabase gateway; the Edge Function rejects requests without
  a valid `X-Admin-Secret`.
- **`invite_codes`** has RLS with no client policies — only service_role
  (Edge Function) can read or write codes.
- **Lock** clears the secret from `sessionStorage`; closing the tab also
  clears it unless you re-open in the same session.
- For a fixed deployment URL, consider hosting `index.html` on the VM behind
  nginx basic auth (optional follow-up).

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `Missing authorization header` | Dashboard sends anon key automatically; hard-refresh if using an old cached HTML file |
| `unauthorized` | Wrong or missing `ADMIN_SECRET` |
| `admin_secret_not_configured` | Run `supabase secrets set ADMIN_SECRET=...` and redeploy if needed |
| Invite list empty | Normal if all users were provisioned before invite codes; generate a new code to verify |
| User has no invite code | Manual provisioning or backfilled `ready` row without redemption |
| Redeemers show relay email | Sign in with Apple private relay — expected |
| Tasks show "Deploy the updated admin function…" | Run `supabase functions deploy admin` |
| Tasks table empty with filters set | Click **Clear** or loosen search/status/user/integration filters |
| `unknown_action` on tasks | Redeploy admin Edge Function; hard-refresh the HTML file |

## Manual SQL fallback

If the dashboard is unavailable, mint codes in the Supabase SQL editor
(service_role):

```sql
insert into invite_codes (code, note) values ('FRIEND-ABC123', 'for alice');

insert into invite_codes (code, max_uses, expires_at, note)
values ('LAUNCH-PARTY', 10, '2026-07-01', 'launch batch');
```

Watchdog queries for stuck provisioning and running todos live in
[`supabase/README.md`](../supabase/README.md).

## Related docs

- [Supabase onboarding & deploy](../supabase/README.md#per-user-onboarding-invite-codes)
- [Runner provisioning](../runner/README.md) — VM-side agent creation after code redemption
