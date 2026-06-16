# Supabase

Auth, database, Realtime, and Edge Functions for doit.

## One-time project setup

1. Create a Supabase project at <https://supabase.com>. Note the project URL
   and the `anon` and `service_role` keys.
2. **Enable Sign in with Apple**:
   - In your Apple Developer account, create a Services ID, enable
     "Sign in with Apple", and add the Return URL Supabase shows you
     (`https://<project>.supabase.co/auth/v1/callback`).
   - In Supabase Dashboard -> Authentication -> Providers -> Apple, paste the
     Services ID (Client ID) and the generated client secret (or use the
     "generate from key" helper with your Apple `.p8` Sign in with Apple key).
     For native iOS sign-in, include both the Services ID and app bundle ID in
     the Supabase Client IDs field, comma-separated, for example:
     `com.newmaterial.doit.auth,com.newmaterial.doit` (Services ID + native app
     bundle ID). Example with legacy IDs:
     `co.supabase.<project-ref>.auth,do.it.doit.app`.
3. Apply the schema:

   ```bash
   # using the Supabase CLI (recommended)
   supabase link --project-ref <ref>
   supabase db push
   ```

   Or paste `migrations/0001_init.sql` into the SQL editor.

4. **Realtime** is enabled by the migrations and publishes `todos`,
   `todo_steps`, `todo_interactions`, `todo_artifacts`, `todo_messages`,
   `cron_jobs`, `cron_job_interactions`, and `cron_job_messages`. In
   Dashboard -> Database -> Replication, verify they are listed.

   The iOS app subscribes to a `user_id=eq.<userID>` slice of those tables
   in [`ios/doit/doit/Supabase/TodoRealtimeHub.swift`](../ios/doit/doit/Supabase/TodoRealtimeHub.swift)
   and routes the events through `TodoStore`. See
   [`/docs/task-realtime.md`](../docs/task-realtime.md) for the full
   contract. If you add a new table that the iOS list needs to render live,
   add it to the `supabase_realtime` publication in a new migration *and*
   extend the hub + store — don't try to poll from a view.

## Per-user onboarding (invite codes)

Onboarding is automated. A new user signs in with Apple, enters an invite
code on the onboarding screen, and the VM-side provisioner builds their
agent (Hermes profile + Composio session + `user_hermes` row) within a
minute.

### Admin dashboard (recommended)

See **[`docs/local-admin-dashboard.md`](../docs/local-admin-dashboard.md)** for
setup, usage, API reference, and troubleshooting.

Open [`admin/index.html`](../admin/index.html) in a browser. Paste your
`ADMIN_SECRET` and the function URL on first load.

```bash
# from repo root
supabase db push                                    # admin_* RPC migrations
supabase functions deploy admin
supabase secrets set ADMIN_SECRET=<long random string>
```

Keep `ADMIN_SECRET` out of git. Lock the dashboard when done (Lock button
clears the secret from the browser session).

### Manual SQL fallback

You can still mint codes in the SQL editor (service_role):

```sql
-- single-use code
insert into invite_codes (code, note) values ('FRIEND-ABC123', 'for alice');

-- 10-use code that expires at the end of the month
insert into invite_codes (code, max_uses, expires_at, note)
values ('LAUNCH-PARTY', 10, '2026-07-01', 'launch batch');
```

The flow under the hood:

1. The app calls the `onboarding` Edge Function (`redeem` action), which
   atomically validates + consumes the code via the `redeem_invite_code`
   RPC and inserts a `pending` row into `user_provisioning`.
2. The runner's provisioner loop claims the row, creates the Hermes
   profile / Composio session / systemd unit on the VM, upserts
   `user_hermes`, and flips the row to `ready`.
3. The app watches the row over Realtime and drops the user into the task
   list when it goes `ready`. On failure the row goes `failed` with an
   error; the in-app retry re-queues it without consuming another use.

Users who were provisioned manually before invite codes existed are
backfilled as `ready` by the migration (and by the `status` action as a
fallback), so they never see the invite screen.

**Watchdog queries** (run occasionally, or when something seems off):

```sql
-- users stuck in provisioning (> 10 min) or failed
select user_id, status, error, claimed_at, updated_at
from user_provisioning
where status = 'failed'
   or (status in ('pending', 'provisioning')
       and created_at < now() - interval '10 minutes');

-- todos running past their lease (runner crash / wedge)
select id, user_id, title, run_claimed_at
from todos
where status = 'running'
  and (run_claimed_at is null or run_claimed_at < now() - interval '10 minutes');

-- current port allocation (gaps are fine; collisions are impossible)
select profile_name, api_port from user_hermes order by api_port;
```

If a user is stuck `failed` and the in-app retry doesn't fix it, repair
from the VM: `python -m runner.provision_cli --user-id <uuid>` (see
`../runner/README.md`).

## Edge Function: `integrations`

Deployed from `functions/integrations/`. Proxies Composio's REST API so the
Composio API key never reaches the iOS app.

```bash
   # run from the repo root (not supabase/)
   supabase functions deploy integrations
   supabase functions deploy agent-settings
   supabase functions deploy task-suggestions
   supabase functions deploy cron-suggestions
   supabase functions deploy onboarding
   supabase functions deploy admin
   supabase secrets set COMPOSIO_API_KEY=ck_...
   supabase secrets set SUPABASE_SERVICE_ROLE_KEY=<service_role>
   supabase secrets set OPENAI_API_KEY=<openai_key>
   supabase secrets set ADMIN_SECRET=<long random string>
```

The `onboarding` function powers the invite-code flow above: `status`
returns the caller's provisioning row + whether their agent exists, and
`redeem` consumes an invite code. It needs the same
`SUPABASE_SERVICE_ROLE_KEY` secret as the others.

The `admin` function powers the operator dashboard (`admin/index.html`):
`summary`, `users`, `invites`, `feedback`, `tasks`, and `create_invite`
actions. Requires `ADMIN_SECRET` (never ship to iOS).

The `task-suggestions` function powers the iOS homescreen "Suggested" tiles.
It reads recent todo history server-side and calls OpenAI (`OPENAI_SUGGESTIONS_MODEL`,
default `gpt-5.4-mini`) to generate personalized next-task ideas. Requires
`OPENAI_API_KEY` and `SUPABASE_SERVICE_ROLE_KEY` as Edge Function secrets.

The `cron-suggestions` function powers the iOS Scheduled tab "Suggested" tiles.
It reads recent todos, memories, and cron jobs server-side and calls OpenAI with
the same model to generate personalized recurring-automation ideas (weekly digests,
daily monitors, etc.). Requires the same secrets as `task-suggestions`.

The function reads the caller's `auth.uid()` from the JWT and uses it as the
Composio `entity_id`, so each user only sees their own connections.

The `agent-settings` function also uses the caller's JWT, but writes through
`service_role` so users can only choose from Doit's supported provider/model
catalog. Hermes agent models are **OpenRouter-only** for beta: the catalog
returns a single `openrouter` provider with selectable mid-tier models plus
higher-tier models marked `locked: true` (visible in the app, rejected on
`update` with `model_locked`). Provider API keys are global runner secrets,
not app input.

### Beta model deploy

After changing the catalog or migration:

```bash
supabase functions deploy agent-settings
supabase db push   # applies 20240601000028_openrouter_only_models.sql
```

On the runner VM, set provisioning defaults and ensure OpenRouter is configured:

```bash
HERMES_MODEL_PROVIDER=openrouter
HERMES_MODEL_DEFAULT=google/gemini-2.5-flash
OPENROUTER_API_KEY=sk-or-v1-...
```

Push runner code and restart from the repo root:

```bash
./scripts/deploy-runner.sh
```

The script rsyncs `runner/runner/` to the VM and restarts `doit-runner`. It
never overwrites the VM's `.env` — add the vars above to
`/opt/doit/runner/.env` on the VM if they are not already set.

## Keys cheat sheet

| Key | Where it goes | Why |
| --- | --- | --- |
| `anon` | iOS app | RLS-scoped reads/writes |
| `service_role` | Runner (VM env) | bypass RLS to update other users' todos |
| `service_role` | Edge Function secret | save supported model settings server-side |
| `COMPOSIO_API_KEY` | Edge Function secret + VM `.env` for Hermes | OAuth proxy |
| `OPENAI_API_KEY` | Supabase Edge Function secret | transcription (`transcribe-audio`), task suggestions |
| `OPENAI_API_KEY` | Runner (VM env, optional) | memory extraction fallback when `DOIT_MEMORY_MODEL` is set |
| `ANTHROPIC_API_KEY` | Runner (VM env, optional) | kept for future use; not used by Hermes in beta |
| `OPENROUTER_API_KEY` | Runner (VM env) | **required** — all Hermes agent runs in beta |
| `BROWSERBASE_API_KEY` | Runner (VM env) and synced to `~/.hermes/.env` | Browserbase cloud browser sessions for Hermes browser tools and browse.sh CLI |
| `BROWSERBASE_PROJECT_ID` | Runner (VM env) and synced to `~/.hermes/.env` | Browserbase project for managed browser sessions |
| Apple `.p8` (APNs) | Runner (VM env) | push notifications |

The on-demand browse.sh skill bridge is VM-only. It uses the runner's
`BROWSE_SKILL_*` env flags and `hermes/scripts/sync_browse_skill.py`; it does
not require any Supabase secret or schema change.
