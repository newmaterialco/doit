# End-to-end demo: "Email my landlord rent is late"

This is the canonical first demo. It exercises every piece of the system:
auth, RLS, the runner, Hermes, Composio OAuth, push, and live thinking.

## Prerequisites (one-time)

Follow these in order. Each links to the file with the full instructions.

1. **Supabase** — create the project and apply the schema.
   See [`supabase/README.md`](supabase/README.md).
2. **Apple Developer** — enable Sign in with Apple for the Supabase project
   (same file). Also create an **APNs auth key (`.p8`)** under Keys, download
   it, and note the Key ID + your Team ID.
3. **Cloud VM** — provision a Hetzner or DigitalOcean ~4GB Ubuntu box and
   install Hermes.
4. **Nous Portal** — `hermes setup --portal` on the VM (gives Hermes the LLM
   plus web/image/TTS tools).
5. **Composio** — sign up at <https://composio.dev> and copy the backend
   project API key. It is used by the Edge Function and to create the per-user
   Composio session MCP URL for Hermes.
6. **Edge Function** — deploy:
   ```bash
   supabase functions deploy integrations
   supabase secrets set COMPOSIO_API_KEY=ck_xxx
   ```
7. **Create your Hermes profile** on the VM — follow steps 5-6 in
   [`hermes/setup.md`](hermes/setup.md). End state: one `hermes-<name>` systemd
   service is `active (running)`, `hermes -p <name> -z "Reply OK"` works, and
   there's a `user_hermes` row keyed to your Supabase user uuid.
8. **Deploy the runner** — step 8 in `hermes/setup.md`. Watch
   `journalctl -u doit-runner -f` to confirm "doit runner online".
9. **Configure the iOS app**:
   - Open [`ios/doit/doit.xcodeproj`](ios/doit/doit.xcodeproj) in Xcode.
   - Edit [`ios/doit/doit/Supabase/SupabaseConfig.swift`](ios/doit/doit/Supabase/SupabaseConfig.swift)
     with your project URL + anon key.
   - In Signing & Capabilities: select your team, ensure **Sign in with Apple**
     and **Push Notifications** capabilities are present (the entitlements file
     already declares them).
   - Build & run on a real device (push notifications don't work in the
     simulator).

## The demo (60 seconds)

1. **Sign in** — Tap "Sign in with Apple", confirm with Face ID.
2. **Allow notifications** — Tap "Allow" when prompted.
3. **Connect Gmail (proactive)** — Tap the gear icon top-left -> Integrations
   list. Tap **Connect** next to Gmail. A Google OAuth screen opens; sign in
   and approve. The row flips to **Connected**. The same sheet can also connect
   Google Calendar, Drive, Docs, Sheets, and the other curated toolkits. Close
   Settings.

   _Skipping this step is fine — the agent will prompt for it inline when it
   needs it._

4. **Create the todo** — Tap **+**, type
   > Email my landlord that rent will be 3 days late this month. Be polite,
   > apologize, and ask if there's a partial-payment option. The landlord's
   > address is in my recent emails.

   Tap **Save**.
5. **Tap the todo -> Do it.** The status flips to **Working...** and the
   Activity section starts filling in with steps in real time:
   - "Search Gmail for landlord contact"
   - "Draft email"
   - "Send email"

   Each row appears as the agent calls that tool.
6. **Lock your phone.** Wait a few seconds.
7. **Push notification arrives:** "Done — Email my landlord that rent will be
   3 days late..."
8. Tap the push -> jumps back into the todo. Final step shows the summary of
   what was sent.

## The "needs auth" path

If you skipped step 3 (connecting Gmail proactively):

5. Tap "Do it". After a few seconds the status flips to **Needs you** (orange).
6. A push appears: "Connect an account — Tap to authorize so the agent can
   finish."
7. Tap into the todo -> hit "Connect your account" -> Google OAuth -> approve.
8. Tap **Do it** again -> the agent picks up where it left off and finishes.

## The "needs your input" path (approval / choice / question)

For todos that involve sending, posting, deleting, booking, or anything else
that's externally visible or irreversible, the agent pauses and asks before
acting. Walk through it like this:

1. Create a todo like "Email my landlord rent will be 3 days late." Tap
   **Do it**.
2. The agent researches, drafts the email, and stops. The todo flips to
   **Needs you** (orange) in the Doing column and a push appears.
3. Tap into the todo. The detail view shows a "Needs your input" card with
   the draft (To / Subject / Body) plus the agent's buttons — typically
   **Send**, **Rewrite**, and **Cancel**.
4. Tap **Send** to approve. The todo goes back to **Queued** and the runner
   resumes the same Hermes session to actually send the email.
5. Or, type something like "Make it shorter and ask if they accept partial
   payment" into the field and tap **Rewrite**. The agent comes back with a
   new draft for another round of approval.
6. **Cancel** drops the todo into the Cancelled state and stops the agent.

The same loop generalizes to any "agent needs the user" moment — multiple
choice questions, clarifications, destructive confirmations. Each ask shows
up as its own card; only one open card is ever live per todo.

## Cross-todo memory check

This is the demo that proves Hermes' built-in memory is actually doing the
work — not a prompt workaround on our side.

1. Create a todo "Send a test email to my personal email
   gabemitchell93@gmail.com." Tap **Do it**. Approve the draft when prompted.
   In the run's activity feed you should see an "Updating long-term memory:
   add: …" step — that's the agent calling its `memory` tool.
2. Wait for the run to finish, then open **Settings > Memory**. Within a
   few seconds you should see a new "Learned by agent" entry under
   **About you** like "Personal email: gabemitchell93@gmail.com" — that's
   the agent writing to `USER.md` and the runner mirroring it back into
   Supabase.
3. Create a second todo, "Send something short to my personal email about
   coffee." Tap **Do it**, do *not* include the address.
4. The agent should reach the draft step without asking what your personal
   email is. Confirm in the run's activity feed that it either pulled the
   address from memory directly (no `Searching past tasks…` step needed),
   or called `session_search` against the earlier todo's session
   (the activity feed renders that as "Searching past tasks for context:
   personal email"). Because we now rotate `session_id` per todo, the
   second run gets a *fresh* memory snapshot — so a value the agent saved
   on the first run will be visible at the top of the second run's system
   prompt without any other plumbing.

If step 4 fails:

- Check `hermes -p <profile> memory status` on the VM — built-in MEMORY +
  USER files should be active.
- Run `python -m runner.mirror_memory_cli --user-id <uuid>` from the
  runner venv on the VM to backfill Settings > Memory from whatever the
  profile already has on disk. If the entry shows up there but the agent
  still didn't use it, the problem is with memory recall, not memory
  saving.
- Inspect `~/.hermes/profiles/<profile>/memories/USER.md`. The personal
  email entry should be there after step 1; if it isn't, the agent decided
  it wasn't durable enough — try a third "remember my personal email is …"
  todo to force a save, then retry step 3.
- Pin the fact manually in Settings > Memory ("About you" target). On the
  next "Do it" the runner will stage it into `USER.md` before calling
  `/v1/runs`, and the entry will show up tagged **Pinned**.

## What to check if it doesn't work

| Symptom | Where to look |
| --- | --- |
| Sign-in spins forever | Supabase Apple provider config + your Bundle ID matches Services ID. |
| Todo stays "Queued" | `journalctl -u doit-runner -f` — runner not picking up rows. Check `SUPABASE_SERVICE_ROLE_KEY`. |
| Runner logs "no hermes profile" | The `user_hermes` row isn't there for your user_id. |
| Steps stop appearing mid-run | The Hermes systemd service died — `journalctl -u hermes-<name>`. |
| No push notifications | APNs `.p8` not mounted, Team ID wrong, or device not registered (check the `devices` table for your user). |
| "Couldn't load integrations" | Edge Function not deployed or `COMPOSIO_API_KEY` secret not set. |
| Hermes logs `401 Unauthorized` for Composio MCP | The profile is probably using the static `connect.composio.dev/mcp` URL. Generate a Composio v3 session with `Composio().create(user_id=...)` and paste `session.mcp.url` + `session.mcp.headers` into the profile config. |
| OAuth screen errors out | Verify in `hermes mcp` that Composio is connected for the profile; try the manual sanity check in `hermes/setup.md` step 7. |
| Memory tag shows "Sync failed" in Settings > Memory | The profile's `USER.md` or `MEMORY.md` is full or unreachable. Shorten existing entries from the app, or run `hermes -p <profile> memory status` on the VM to confirm built-in memory is enabled. |
| Agent keeps re-asking facts you already taught it | Confirm the runner is on the new build (per-todo `session_id=doit-todo-*`), check `~/.hermes/profiles/<profile>/memories/USER.md` for the fact, and pin it manually in Settings > Memory if Hermes didn't save it on its own. |
| Settings > Memory looks empty even though Hermes "knows" things | Run `python -m runner.mirror_memory_cli --user-id <uuid>` (or `--all`) on the VM to backfill from `USER.md` / `MEMORY.md`. The reverse mirror runs after every todo, but this CLI seeds it without needing a run. |
