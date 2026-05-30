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
   or `memories/MEMORY.md` so Hermes picks them up in the next session's
   frozen snapshot (see "Memory" below).
5. `POST http://127.0.0.1:<port>/v1/runs` with the todo text + a system prompt,
   using a stable per-user `session_id = doit-user-<uuid>` so memory and
   `session_search` span all todos for that user.
6. Consumes `GET /v1/runs/{id}/events` (Server-Sent Events).
7. Translates Hermes events into rows in `todo_steps` and status changes on
   `todos`. The iOS app sees them live via Supabase Realtime.
8. After the run, mirrors Hermes' updated `USER.md` / `MEMORY.md` back into
   Supabase so Settings > Memory shows what the agent has learned.
9. Sends APNs pushes on the key moments: **needs Gmail auth**, **needs your
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
|   |-- runner.py       main loop + per-todo orchestration
|   |-- hermes.py       /v1/runs client + SSE parser
|   |-- hermes_memory.py read/write Hermes' MEMORY.md and USER.md files
|   |-- prompt.py       per-todo prompt + stable session id helpers
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

## Tests

Pure-python checks (no Supabase / Hermes / network) for the bits that are
easy to regress without noticing — start with the interaction-block parser:

```bash
python -m unittest discover -s tests -v
```

## Deploy on the VM (systemd)

See `../hermes/setup.md` for the full provisioning runbook. The runner is the
last step there.

## Notes

- The runner uses Supabase's **service_role** key so its writes bypass RLS.
  Keep that key off the iOS app at all costs — it's server-only.
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
- Model settings: the iOS app writes allowlisted choices through the
  `agent-settings` Edge Function. The runner reads pending settings with
  `service_role`, copies Doit's global provider key from `OPENAI_API_KEY` or
  `ANTHROPIC_API_KEY` into that user's Hermes profile `.env`, updates
  `~/.hermes/profiles/<profile>/config.yaml`, restarts `hermes-<profile>`, then
  marks the setting applied.
- Memory: we lean on Hermes' built-in persistent memory instead of
  re-injecting facts into every prompt. The runner uses a stable
  `session_id = doit-user-<uuid>` so the agent's `USER.md`, `MEMORY.md`, and
  `session_search` span every todo for that user. Two-way sync runs around
  each `/v1/runs` call:
  - Before: pending user-pinned rows from Supabase `memories`
    (`source='user'`, `sync_status='pending'`) are staged into the matching
    `~/.hermes/profiles/<profile>/memories/{USER,MEMORY}.md` file with
    fingerprints, then marked `synced`.
  - After: the same files are read back and any new agent-curated entries
    are upserted into Supabase as `source='hermes'`; Hermes-authored rows
    whose fingerprints have vanished from disk are deleted so Settings >
    Memory mirrors the agent's current state. User-pinned rows are never
    deleted by the mirror.
  - The fallback `_build_prompt` no longer enumerates memories — that path
    is gone now that the frozen snapshot does the job.
