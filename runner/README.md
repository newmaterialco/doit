# runner

Thin always-on worker that bridges Supabase and Hermes. No web server, no auth,
no public ports — outbound calls only.

## What it does

A single async loop:

1. Polls Supabase for `todos.status = 'requested'` (atomically claims one by
   flipping it to `running`).
2. Looks up the user's Hermes endpoint in `user_hermes`.
3. Applies any pending Settings > Model change to that user's Hermes profile.
4. Stages any pending user-pinned memories into the profile's `memories/USER.md`
   or `memories/MEMORY.md` so Hermes picks them up in this run's frozen
   snapshot, and surfaces the same entries in the prompt so the agent can
   curate them via its `memory` tool (see "Memory" below).
5. Optionally pre-installs a matching browse.sh skill into `~/.hermes/skills`
   for browser-heavy tasks before Hermes starts, so the skill is visible during
   the run.
6. `POST http://127.0.0.1:<port>/v1/runs` with the todo text + a system prompt,
   using a per-todo `session_id = doit-todo-<uuid>` and a per-user
   `X-Hermes-Session-Key = doit-user:<uuid>` header. The per-todo session id
   matters because Hermes injects MEMORY.md/USER.md as a *frozen* snapshot at
   session start; rotating it per todo guarantees the next run sees the
   latest memory writes. Cross-todo continuity comes from `session_search`
   (FTS5 over `state.db`) and the per-profile memory files.
7. Consumes `GET /v1/runs/{id}/events` (Server-Sent Events).
8. Translates Hermes events into rows in `todo_steps` and status changes on
   `todos`. The iOS app sees them live via Supabase Realtime. `memory` and
   `session_search` tool calls get their own activity-feed labels so it's
   easy to confirm the agent is actually using its memory.
9. After the run, mirrors Hermes' updated `USER.md` / `MEMORY.md` back into
   Supabase so Settings > Memory shows what the agent has learned.
10. Sends APNs pushes on the key moments: **needs Gmail auth**, **needs your
   input**, **done**, **failed**.

Concurrently it polls the todo's status — if the user sets it to `cancelled`,
the runner calls `POST /v1/runs/{id}/stop` and exits the inner loop cleanly.

If the agent decides it needs the user before continuing (a draft to approve,
a clarification, a choice) it stops calling tools and emits a structured
`[[DOIT_INTERACTION]]` block in its final reply. The runner parses that
block, writes a `todo_interactions` row, flips the todo to `needs_input`, and
sends a push. When the user replies in the app, the interaction row is set to
`responded` and the todo goes back to `requested`. On the next claim the
runner reads the response and resumes the same Hermes session with the user's
choice woven into the prompt.

## Layout

```
runner/
|-- runner/
|   |-- __main__.py     entrypoint (python -m runner)
|   |-- runner.py       main loop (bounded worker pool) + per-todo orchestration
|   |-- scheduler.py    TaskPool + per-user gates (staging locks, run caps, deferred restarts)
|   |-- provision.py    automated agent provisioning (invite-code onboarding)
|   |-- provision_cli.py one-shot CLI to provision/repair a single user
|   |-- hermes.py       /v1/runs client + SSE parser
|   |-- hermes_memory.py read/write Hermes' MEMORY.md and USER.md files
|   |-- mirror_memory_cli.py one-shot CLI to backfill Settings > Memory
|   |-- prompt.py       per-todo prompt + per-todo session id helpers
|   |-- events.py       map Hermes events -> todo_steps + status
|   |-- db.py           Supabase REST (service_role)
|   |-- model_settings.py apply app-selected model settings to Hermes profiles
|   |-- push.py         APNs (aioapns)
|   |-- config.py       env loading
|-- requirements.txt
|-- Dockerfile
|-- .env.example
```

## Local run

```bash
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env  # fill in real values
python -m runner
```

## Environment

The runner reads secrets from `runner/.env` on the VM. Keep this file out of
git; `runner/.env.example` is the committed template.

Core values:

| Variable | Purpose |
| --- | --- |
| `SUPABASE_URL` | Supabase project URL |
| `SUPABASE_SERVICE_ROLE_KEY` | Server-only key used by the runner to bypass RLS |
| `HERMES_PROFILES_DIR` | Root directory for per-user Hermes profiles |
| `HERMES_RESTART_COMMAND_TEMPLATE` | Restart command used after profile config changes |
| `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` / `OPENROUTER_API_KEY` | Global Doit-paid model provider keys |
| `BROWSERBASE_API_KEY` / `BROWSERBASE_PROJECT_ID` | Browserbase credentials for Hermes browser automation and browse.sh CLI sessions |
| `BROWSE_SKILL_AUTO_INSTALL` | Enables runner preflight install of matching browse.sh skills before Hermes starts |
| `BROWSE_SKILL_INSTALL_TIMEOUT_SECS` | Timeout for browse.sh skill discovery/install bridge commands |
| `BROWSE_SKILL_MIN_CONFIDENCE` | Reserved threshold for future browse.sh ranking metadata; keep `0` today |
| `BROWSE_SKILL_SYNC_SCRIPT` | Optional override for the bridge script path, defaulting to `/opt/doit/hermes/scripts/sync_browse_skill.py` in the VM layout |
| `APNS_*` | Push notification credentials |
| `MAX_CONCURRENT_RUNS` | Worker pool size across all users (default 8; `1` reproduces the old strictly-sequential behavior) |
| `MAX_RUNS_PER_USER` | Per-user cap so one user can't occupy the whole pool (default 2) |
| `PROVISIONER_ENABLED` | Enables the in-process provisioner loop for invite-code onboarding (default true) |
| `COMPOSIO_API_KEY` | Required by the provisioner to create per-user Composio tool-router sessions |
| `MAX_PROVISIONED_USERS` | Capacity guard: provisioning refuses past this count so a leaked invite code can't melt the VM (default 100) |
| `HERMES_PORT_RANGE_START` | First API port for newly provisioned gateways (default 8643) |
| `HERMES_BIN` / `HERMES_PROFILE_TEMPLATE_DIR` | Hermes binary and profile template paths for the provisioner |
| `HERMES_START_COMMAND_TEMPLATE` | Gateway start command (default `sudo systemctl enable --now hermes@{profile}`) |
| `HERMES_MODEL_PROVIDER` / `HERMES_MODEL_DEFAULT` / `HERMES_MODEL_BASE_URL` | Model block written into new profiles |
| `HERMES_USER_CHAR_LIMIT` / `HERMES_MEMORY_CHAR_LIMIT` | On-disk caps for `USER.md` / `MEMORY.md` (defaults 4000 / 8000) |
| `MEMORY_CONSOLIDATE_WITH_MODEL` | Optional LLM merge when deterministic dedupe is not enough (default off) |

## Memory capacity rollout

After deploying runner changes that raise memory limits:

1. Add `HERMES_USER_CHAR_LIMIT=4000` and `HERMES_MEMORY_CHAR_LIMIT=8000` to the VM `runner/.env` and restart `doit-runner`.
2. Patch live Hermes profiles and restart gateways: `./scripts/patch-hermes-memory-limits.sh`
3. Re-queue rows that failed with the old tiny caps: `python -m runner.requeue_failed_memories_cli --all`

The runner evicts oldest agent-authored on-disk entries before user-pinned facts when a file is full, and runs a deterministic near-duplicate merge when a file is ≥85% full after each todo mirror.

## Concurrency model

The main loop is a bounded asyncio worker pool (`MAX_CONCURRENT_RUNS`
slots). Claimed todos, prep passes, and cron runs each become a task in the
pool; per-user state lives in a `UserGate`:

- a **staging lock** held only during short critical sections (model apply,
  memory staging, browse-skill prefetch, post-run memory mirror) — the long
  SSE-consumption middle runs unlocked, which is what lets one user have
  multiple tasks in flight;
- an **active-run count** capped at `MAX_RUNS_PER_USER`;
- **deferred gateway restarts**: a model change or browse-skill install
  that needs a `hermes@<profile>` restart waits until the user's other runs
  finish instead of killing them mid-run.

Crash recovery: claimed work carries a lease (`todos.run_claimed_at`,
heartbeated during the run). On startup or poll, `running` rows with a
stale lease are reclaimed, so a runner crash can delay a task but never
strand it.

## Provisioning repair

The provisioner is idempotent — re-running a `failed` user verifies and
repairs each step (profile dir, Composio session, config, port, systemd
unit, health check) rather than duplicating. The in-app retry button does
this automatically; for manual surgery on the VM:

```bash
cd /opt/doit/runner
.venv/bin/python -m runner.provision_cli --user-id <uuid>
```

Browserbase is read by Hermes from the global `~/.hermes/.env`, not directly
from `runner/.env`. After adding or rotating `BROWSERBASE_API_KEY` and
`BROWSERBASE_PROJECT_ID` in `runner/.env`, sync them on the VM:

```bash
cd /path/to/repo
python3 hermes/scripts/sync_browserbase_env.py --restart
```

This updates `~/.hermes/.env` with mode `600` and restarts the `hermes@*`
gateway services so both Hermes `browser_*` tools and terminal-driven `browse`
CLI commands can use Browserbase.

The on-demand browse.sh bridge lives at `hermes/scripts/sync_browse_skill.py`.
When `BROWSE_SKILL_AUTO_INSTALL=true`, the runner calls it before execution for
browser-heavy tasks, installs the best matching catalog skill into
`~/.hermes/skills`, and restarts that Hermes profile before `start_run`.
Manual smoke test:

```bash
python3 /opt/doit/hermes/scripts/sync_browse_skill.py --query "cheap flights SFO JFK"
hermes skills list | grep search-flights
```

## Tests

Pure-python checks (no Supabase / Hermes / network) for the bits that are
easy to regress without noticing — start with the interaction-block parser:

```bash
python -m unittest discover -s tests -v
```

## Deploy on the VM (systemd)

See `../hermes/setup.md` for the full provisioning runbook. The runner is the
last step there.

### Shipping a change

After the first-time systemd setup is done, deploying a new version is a
one-liner from the repo root on your dev machine:

```bash
./scripts/deploy-runner.sh
```

That rsyncs `runner/runner/`, `hermes/scripts/`, and bundled `hermes/skills/`
to the VM, installs bundled skills into `~/.hermes/skills`, and restarts
`doit-runner`. It
deliberately excludes `.venv` (platform-specific) and `.env` (real secrets
live only on the VM), so it's safe to re-run.

Targeting a different VM is just env overrides — the defaults match the
current droplet:

```bash
DOIT_VM_HOST=root@<other-ip> DOIT_VM_PATH=/srv/doit/runner \
  ./scripts/deploy-runner.sh
```

If `requirements.txt` changed, ssh in once afterwards and refresh the venv:

```bash
ssh "$DOIT_VM_HOST" '
  cd /opt/doit/runner &&
  .venv/bin/pip install -r requirements.txt &&
  systemctl restart doit-runner
'
```

## Notes

- The runner uses Supabase's **service_role** key so its writes bypass RLS.
  Keep that key off the iOS app at all costs — it's server-only.
- **The iOS app sees runner writes via Supabase Realtime, not via APNs.**
  Realtime is the primary in-app refresh path; APNs is only used when the
  app is backgrounded or closed. If you add a new column or table the iOS
  list needs to render live, make sure it's on the `supabase_realtime`
  publication. See [`/docs/task-realtime.md`](../docs/task-realtime.md) for
  the contract.
- For the "thinking timeline" we deliberately ignore token-by-token deltas
  (they'd be too noisy) and emit one row per **tool started** + **tool result**,
  plus a single **final** row at the end. Good UX, low write volume.
- OAuth detection: when a tool emits text that looks like a Composio OAuth
  redirect URL, the runner writes a `oauth_needed` step + flips status to
  `needs_auth` + fires a push. The iOS app opens the URL via
  `ASWebAuthenticationSession` and the user just re-taps "Do it" once they're
  back. (Composio holds the OAuth tokens server-side, so the next run sees the
  connection already in place.)
- Ask-the-user interactions: the system prompt teaches Hermes to pause before
  irreversible or externally visible actions and emit a JSON block wrapped in
  `[[DOIT_INTERACTION]] ... [[/DOIT_INTERACTION]]`. The block carries
  `kind` (`approval` | `choice` | `question` | `confirmation`), a short
  `prompt`, optional `content` (for example an email draft as
  `{"subject":"…","body":"…","to":["…"]}`), and `options` like
  `[{"id":"send","label":"Send","style":"primary"}, …]`. The runner writes
  one row into `todo_interactions`, supersedes any previous open row, sets
  the todo to `needs_input`, and pushes "Needs your input". When the user
  taps an option (and optionally types freeform), the iOS app updates the
  row to `responded` and flips the todo back to `requested`. The runner's
  resume path (see `_build_resume_prompt`) replays the original prompt,
  payload, and the user's response into a fresh Hermes run reusing the
  same `session_id=todo-{id}` so the conversation stays coherent. Option
  `id="cancel"` is a special case: the runner short-circuits and marks the
  todo `cancelled` without starting a new Hermes run.
- Artifacts (user-visible deliverables): when a task produces something the
  user should see at a glance — a created Google Sheet/Doc link, a sent
  email, a calendar invite, or a short text result — the agent wraps each
  one in `[[DOIT_ARTIFACT]] ... [[/DOIT_ARTIFACT]]` in its final reply. The
  block carries `key` (stable per-todo id for updates), `type`
  (`link` | `email` | `calendar` | `text`), a short `title`, and a
  type-specific `payload` (e.g. `{"url":"…","provider":"googlesheets"}` for
  link). The runner parses every block via `parse_artifacts`, strips them
  from the rendered final step so the chat stays clean, and upserts one
  row per `key` into `todo_artifacts` (unique on `(todo_id, artifact_key)`).
  The iOS detail view subscribes to that table and renders each artifact
  as a compact card under the task title. The agent can re-emit a block
  with the same `key` in a later turn to update an existing card in place.
- Model settings: the iOS app writes allowlisted choices through the
  `agent-settings` Edge Function. The runner reads pending settings with
  `service_role`, copies Doit's global provider key from `OPENAI_API_KEY` or
  `ANTHROPIC_API_KEY` into that user's Hermes profile `.env`, updates
  `~/.hermes/profiles/<profile>/config.yaml`, restarts `hermes@<profile>`
  (deferred until the user's other in-flight runs finish), then marks the
  setting applied.
- Memory: we lean on Hermes' built-in persistent memory instead of
  re-injecting facts into every prompt. Session strategy and sync details:
  - **Per-todo `session_id`** (`doit-todo-<uuid>` for execution,
    `doit-prep-<uuid>` for prep). Hermes freezes `USER.md` and `MEMORY.md`
    as a snapshot at session start and never refreshes mid-session, so a
    fresh session per todo is what guarantees the next run sees the latest
    memory writes. Cross-todo continuity comes from `session_search`
    (FTS5 over `state.db`) and the per-profile memory files, not from a
    shared session id.
  - **Per-user `X-Hermes-Session-Key`** header
    (`doit-user:<uuid>`). Hermes uses this to scope external long-term
    memory providers (Honcho, Mem0, …) independently of the
    transcript-scoped session id. Built-in memory is per-profile so the
    key is future-proofing for now.
  - **Before each run**: pending user-pinned rows from Supabase `memories`
    (`source='user'`, `sync_status='pending'`) are staged into the matching
    `~/.hermes/profiles/<profile>/memories/{USER,MEMORY}.md` file with
    fingerprints, marked `synced`, and also forwarded into the prompt as a
    short "user-pinned memories — confirm/consolidate via your memory tool"
    block. Direct file write + tool-curation prompt together is the
    pragmatic Phase 4 compromise: the entry lands on disk for sure, and
    Hermes still gets a chance to dedupe/replace with its own judgment.
  - **After each run**: the same files are read back and any new
    agent-curated entries are upserted into Supabase as `source='hermes'`;
    Hermes-authored rows whose fingerprints have vanished from disk are
    deleted so Settings > Memory mirrors the agent's current state.
    User-pinned rows are never deleted by the mirror.
  - **Observability**: `memory` and `session_search` tool calls render
    with friendly labels ("Updating long-term memory…", "Searching past
    tasks for context…") in the activity feed, so a glance at the run
    timeline tells you whether the agent is actually using its memory.
  - **Backfill**: see `python -m runner.mirror_memory_cli --user-id <uuid>`
    to populate Settings > Memory from an existing profile without
    running a todo. Useful as a smoke test for "did Hermes remember
    anything about me?".
  - **Passbook icons**: each Passbook-visible memory stores an SF Symbol
    name (`symbol_name`). Agent-extracted memories pick one during the
    post-task extraction pass; user-pinned rows use a lightweight keyword
    heuristic on device. Backfill existing rows with
    `python -m runner.backfill_memory_symbols_cli`.
  - The fallback `_build_prompt` no longer enumerates the user's memory
    list — that path is gone now that the frozen snapshot does the job.
