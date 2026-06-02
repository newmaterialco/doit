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

## Per-user onboarding

For each friend you onboard:

1. Have them sign in once with Apple from the app so a row in `auth.users` is
   created. Grab their `user_id` from Dashboard -> Authentication.
2. Create a Hermes profile on the VM: `hermes profile create <name>` (see
   `../hermes/setup.md`). Note its API port and `API_SERVER_KEY`.
3. Insert their mapping (run from SQL editor, requires service_role):

   ```sql
   insert into user_hermes (user_id, profile_name, api_port, api_key, composio_entity)
   values (
     '<user-uuid>',
     '<profile-name>',
     8643,
     '<API_SERVER_KEY value>',
     '<user-uuid>'  -- use the same uuid as the Composio entity id
   );
   ```

## Edge Function: `integrations`

Deployed from `functions/integrations/`. Proxies Composio's REST API so the
Composio API key never reaches the iOS app.

```bash
   supabase functions deploy integrations
   supabase functions deploy agent-settings
   supabase secrets set COMPOSIO_API_KEY=ck_...
   supabase secrets set SUPABASE_SERVICE_ROLE_KEY=<service_role>
```

The function reads the caller's `auth.uid()` from the JWT and uses it as the
Composio `entity_id`, so each user only sees their own connections.

The `agent-settings` function also uses the caller's JWT, but writes through
`service_role` so users can only choose from Doit's supported provider/model
catalog. Provider API keys are global runner secrets, not app input.

## Keys cheat sheet

| Key | Where it goes | Why |
| --- | --- | --- |
| `anon` | iOS app | RLS-scoped reads/writes |
| `service_role` | Runner (VM env) | bypass RLS to update other users' todos |
| `service_role` | Edge Function secret | save supported model settings server-side |
| `COMPOSIO_API_KEY` | Edge Function secret + VM `.env` for Hermes | OAuth proxy |
| `OPENAI_API_KEY` | Runner (VM env) | global Doit-paid OpenAI models |
| `ANTHROPIC_API_KEY` | Runner (VM env) | global Doit-paid Claude models |
| Apple `.p8` (APNs) | Runner (VM env) | push notifications |
