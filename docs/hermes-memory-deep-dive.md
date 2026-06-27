# Hermes Memory Deep Dive

## Executive Summary

Doit is wired to use Hermes' built-in persistent memory path today:

- `USER.md` stores durable user profile facts and preferences.
- `MEMORY.md` stores workflow, environment, and agent notes.
- Hermes injects those files as a frozen snapshot when each session starts.
- Doit uses a fresh execution session per todo so the next todo sees the latest memory file contents.
- The runner mirrors Hermes memory files into Supabase so Settings > Memory can show what Hermes knows.

An audit of a hosted VM profile did not show healthy memory accumulation. The deployed `<profile>` had built-in memory enabled, but only one placeholder `USER.md` entry existed, `MEMORY.md` was missing, no external provider was enabled, and recent task history showed very few `memory` tool calls. Treat placeholder entries as suspicious, not as proof that built-in memory is working.

## Current Architecture

### Runtime Flow

1. The iOS app creates todos, chat messages, interactions, and memory rows in Supabase.
2. The Python runner claims work from Supabase.
3. The runner resolves the user's Hermes profile from `user_hermes`.
4. Before normal prep/execution runs, the runner stages pending user-authored memory rows into the profile's memory files.
5. The runner starts a Hermes run with:
   - `session_id=doit-todo-<todo_id>` for execution
   - `session_id=doit-prep-<todo_id>` for prep
   - `X-Hermes-Session-Key=doit-user:<user_id>`
6. Hermes loads `USER.md` and `MEMORY.md` into the system prompt once at session start.
7. During the run, Hermes can call:
   - `memory` to add, replace, or remove curated entries
   - `session_search` to search previous sessions in the profile's `state.db`
8. After normal execution runs, the runner mirrors current Hermes file entries back into Supabase.
9. Settings > Memory reads the Supabase `memories` table.

### Key Files

- `runner/runner/hermes.py`: Hermes API client and execution `SYSTEM_INSTRUCTIONS`.
- `runner/runner/prompt.py`: per-todo session ids, per-user session key, and execution/follow-up prompt builders.
- `runner/runner/runner.py`: normal todo/prep orchestration and built-in memory sync/mirror.
- `runner/runner/hermes_memory.py`: parser/writer for Hermes `USER.md` and `MEMORY.md`.
- `runner/runner/events.py`: activity labels for `memory` and `session_search` tool calls.
- `runner/runner/cron.py`: scheduled-task execution path.
- `ios/doit/doit/Views/MemoryView.swift`: Settings > Memory UI.
- `ios/doit/doit/Networking/MemoriesAPI.swift`: Supabase CRUD for memory rows.
- `supabase/migrations/20240601000002_memories.sql`: base memory table and RLS.
- `supabase/migrations/20240601000005_memories_native_sync.sql`: Hermes sync columns.
- `hermes/profiles/_template/config.yaml`: built-in memory enabled in profile template.
- `hermes/setup.md`: deployment notes and deferred external-provider setup.

## Hermes Capability Comparison

### Built-In Memory

Hermes documents two bounded files:

- `USER.md`: user profile, about 1,375 chars.
- `MEMORY.md`: agent notes, about 2,200 chars.

Doit's code matches this model. `HermesMemoryStore` uses the same limits, parses entries split by the section-sign delimiter, fingerprints entries for sync, and avoids writing files beyond Hermes' documented capacity. The deployed profile does not show meaningful accumulated usage of that model.

Current code accounts for Hermes' frozen snapshot behavior. Normal todos should use a fresh `doit-todo-<todo_id>` session id, so a new todo should reload memory written by a previous todo. Historical live rows from June 2 still show the old `doit-user-<user_id>` session id, so any conclusions about memory behavior must distinguish the current code from runs made before the per-todo session rollout.

### `memory` Tool

Doit's execution prompt tells Hermes to proactively save durable facts and to use replace/remove for curation. The runner also labels memory tool activity as "Updating long-term memory" / "Memory updated" so the task activity log can show when Hermes uses memory.

The app does not call Hermes' `memory` tool directly. User-created pins are written to disk by the runner, then the prompt nudges Hermes to consolidate them via the `memory` tool.

### `session_search`

Doit's execution prompt tells Hermes to call `session_search` before asking when the user refers to something from a previous todo. The event translator labels those calls as "Searching past tasks for context."

This is important because built-in memory is small. The intended design is:

- Memory files: compact durable facts that should always be in context.
- `session_search`: specific recall from prior conversations and task sessions.

### External Memory Providers

Hermes now documents external memory providers as additive to built-in memory. When active, a provider can prefetch relevant context, sync turns after responses, extract memories at session end, mirror built-in writes, and expose provider-specific tools.

Supported provider examples include Honcho, Mem0, Supermemory, OpenViking, Hindsight, Holographic, RetainDB, ByteRover, and Memori. Only one external provider can be active at a time.

Doit does not currently enable an external provider. `hermes/setup.md` explicitly says built-in memory plus `session_search` is the current source of truth. The code already forwards `X-Hermes-Session-Key=doit-user:<uuid>`, which is the right scoping hook for an eventual provider rollout.

## Findings

### What Is Wired Correctly

- Built-in Hermes memory is enabled in the profile template and in the audited hosted profile.
- Normal todo execution stages pending user pins before starting Hermes.
- Normal todo execution mirrors Hermes-authored file changes back to Supabase afterward.
- Normal todo execution uses per-todo sessions so memory snapshots refresh across todos.
- Existing tests cover file parsing, limits, dedupe, staging, session ids, pinned-memory prompt nudges, and activity labels.
- Settings > Memory exposes both targets: "About you" for `USER.md` and "Agent notes" for `MEMORY.md`.
- User edits reset rows to `sync_status='pending'`, so the next run will stage them again.

### Live Profile Evidence

Read-only inspection of a hosted VM profile found:

- Active service: `hermes-<profile>.service`.
- Profile path: `/root/.hermes/profiles/<profile>`.
- Runner service user: `root`, so the runner uses the same default profile path.
- `hermes -p <profile> memory status`: built-in memory active, external provider `(none)`.
- `USER.md`: one placeholder personal-email entry.
- `MEMORY.md`: missing.
- Supabase `memories`: exactly one mirrored row, matching that placeholder email entry.
- Recent `todo_steps`: only two `memory` tool events in the last 1000 steps, corresponding to one call/result pair.
- That recent memory tool call occurred during an unrelated calendar task and did not update the `USER.md` mtime, suggesting it was likely a duplicate/no-op rather than evidence of healthy memory writing.

The placeholder email also appears in repo demo/test material, so it should not be treated as organic proof that memory works.

### Gaps That Can Make Hermes Look Forgetful

1. App deletes do not propagate to Hermes files.
   - `MemoriesAPI.delete` deletes the Supabase row only.
   - The runner mirror only deletes stale `source='hermes'` rows from Supabase.
   - A user-deleted pinned entry may remain in `USER.md` or `MEMORY.md` until Hermes later removes it.

2. Cron execution does not use the normal memory sync/mirror path.
   - `_run_one_cron_job` starts Hermes directly with `_CRON_INSTRUCTIONS`.
   - It does not stage pending memories before the run.
   - It does not mirror memory files back after the run.
   - Its system prompt does not include the richer memory policy from `SYSTEM_INSTRUCTIONS`.

3. Prep stages pending memory but does not mirror back.
   - This is lower risk because prep says not to call tools.
   - Still, if Hermes or a future provider updates memory around prep/configure, the app will not see it until a normal execution run or manual backfill.

4. Capacity failures are passive.
   - The runner marks overflowed rows as `sync_status='failed'`.
   - The app displays the error, but there is no guided consolidation flow, capacity meter, or "ask doit to clean this up" action.

5. Settings > Memory is not realtime.
   - It loads on entry and pull-to-refresh.
   - A user watching a task finish will not necessarily see learned memory appear unless they refresh or reopen the screen.

6. Task chat does not link memory activity to the Memory screen.
   - The activity feed shows "Memory updated."
   - It does not expose the resulting stored row, target, or a shortcut to Settings > Memory.

7. Built-in memory appears effectively non-functional in practice.
   - The live profile has only one suspicious user-profile entry after substantial usage.
   - `MEMORY.md` is missing.
   - The agent rarely calls the `memory` tool.
   - Historical tasks may have used the older stable user-level `session_id`, so memory snapshots may not have refreshed per todo at that time.

8. External provider capabilities are not enabled.
   - Doit gets bounded curated memory and full-text session search.
   - It does not yet get provider-level semantic recall, automatic fact extraction, user modeling, knowledge graphs, or provider-specific recall tools.

## Validation

### Tests Run In This Environment

The available shell only has Apple Python 3.9.6 and no runner virtualenv.

Passed:

- `PYTHONPATH=runner python3 runner/tests/test_hermes_memory.py`
  - 12 tests passed.
- `PYTHONPATH=runner python3 runner/tests/test_events.py`
  - 35 tests passed.

Could not fully run here:

- `tests/test_runner_session.py`
  - Fails under Python 3.9 because the runner imports `datetime.UTC`, which requires Python 3.11+.
- `tests/test_mirror_memory_cli.py`
  - Fails because `python-dotenv` is not installed in this shell.

### Recommended Live Smoke Tests

Run these against a provisioned Hermes profile, the runner, Supabase, and the iOS app.

1. Agent-learned user fact:
   - Create todo: "Remember that my preferred signing name is Gabe."
   - Verify task activity shows a `memory` tool call.
   - Verify Settings > Memory shows a `USER.md` / "About you" entry.
   - Create a second todo: "Write a one sentence signoff using my preferred signing name."
   - Expected: agent uses Gabe without asking.

2. User-pinned fact:
   - Add a Settings > Memory "About you" entry: "Default personal email is test@example.com."
   - Run a new todo: "What personal email should you use for me?"
   - Expected: runner stages the row, Hermes sees it in the frozen snapshot, row becomes `synced`.

3. Session search:
   - Complete a task with a unique detail that should not fit in compact memory, such as a one-off draft title.
   - In a later todo, ask: "Find the draft title we discussed last time."
   - Expected: activity shows `session_search`; answer cites the prior session.

4. Delete propagation:
   - Add and sync a user-pinned memory.
   - Delete it in Settings > Memory.
   - Inspect the Hermes memory file or ask the agent about the fact in a new todo.
   - Current expected behavior: the fact may still be present. This confirms the delete gap.

5. Cron memory:
   - Add a pending Settings > Memory row.
   - Let a due cron job run before any normal todo execution.
   - Expected current behavior: pending memory is not staged by cron execution. This confirms the cron gap.

6. Capacity:
   - Fill `USER.md` near the char limit, then add another user pin.
   - Run a todo.
   - Expected: row becomes `failed` with a memory-full error. Evaluate whether the UI makes the recovery path clear.

## Prioritized Fixes

### P0: Make Delete And Edit Semantics Honest

Goal: when the user deletes or edits a memory in the app, Hermes should stop remembering the old text.

Recommended implementation:

- Replace hard delete with a tombstone or pending-delete state in Supabase, or add a separate `memory_deletions` queue.
- Store enough data to remove the old entry from Hermes:
  - `target`
  - `hermes_fingerprint`
  - previous entry text or unique substring
- Add runner sync logic before each run:
  - remove matching entries from `USER.md` / `MEMORY.md`
  - mark deletion complete
  - then stage new/edited rows
- Add tests for:
  - user-pinned delete removes the on-disk entry
  - edit removes the old fingerprint and stages the new text
  - deleting an agent-authored row removes the mirrored row and optionally asks Hermes to remove it from disk

### P1: Align Cron With Normal Todo Memory

Goal: scheduled tasks should see and update memory the same way user-started todos do.

Recommended implementation:

- Move memory staging/mirroring helpers to a small shared module so `cron.py` can use them without awkward imports.
- In `_run_one_cron_job`, stage pending user memories before `hermes.start_run`.
- Mirror Hermes files back after cron completion/failure.
- Add memory guidance to `_CRON_INSTRUCTIONS`, including when to use `session_search`.
- Add tests that cron starts after staging pending memory and mirrors after completion.

### P2: Improve Memory UX

Goal: make memory feel visible and trustworthy.

Recommended implementation:

- Show `last_sync_at` in `MemoryRow` or detail.
- Add approximate capacity indicators for each target.
- Add clearer failed-sync recovery copy.
- Add a "Review memory" affordance from task activity when `memory` tool calls happen.
- Consider a lightweight realtime subscription for the `memories` table while `MemoryView` is open.

### P3: Strengthen Prompt And Test Coverage

Goal: keep memory behavior from regressing.

Recommended implementation:

- Add tests that `SYSTEM_INSTRUCTIONS` keeps the `session_search before asking` rule.
- Add tests for cron memory prompt clauses once cron is aligned.
- Add direct tests for `_sync_pending_memories_to_hermes` and `_mirror_hermes_memory_to_supabase` with fake DB/store objects.
- Document Python 3.11 as the runner test/runtime requirement, or adjust code if Python 3.9 support is intended.

## External Memory Provider Rollout

Treat provider enablement as a separate rollout after P0/P1 are fixed.

### Candidate Choice

Start with Mem0 or Honcho:

- Mem0 is likely the simplest first provider for semantic fact extraction and search.
- Honcho is more compelling for user modeling, preferences, and richer personal assistant behavior.
- Supermemory is also relevant if the desired outcome is semantic long-term recall plus conversation graph ingestion.

Do not enable more than one provider. Hermes supports only one active external provider alongside built-in memory.

### Rollout Steps

1. Pick one test user/profile.
2. Snapshot current profile memory files and Supabase `memories` rows.
3. Configure provider on the Hermes VM:
   - `hermes -p <profile> memory setup <provider>`
   - `hermes -p <profile> memory status`
4. Confirm `config.yaml` has `memory.provider`.
5. Run the live smoke tests above.
6. Add provider-specific tests:
   - recall from a previous todo without the fact being in `USER.md` / `MEMORY.md`
   - provider tool activity is visible in task steps
   - `X-Hermes-Session-Key` isolates one Doit user's memory from another
7. Observe cost, latency, and quality for at least several real tasks.
8. Roll back with:
   - `hermes -p <profile> memory off`
   - keep built-in `USER.md` / `MEMORY.md` active

### Product Decision

Keep Settings > Memory as the curated built-in memory surface. Do not try to mirror a provider's entire corpus into that screen at first.

Instead:

- Use Settings > Memory for critical, user-visible, editable facts.
- Use provider-backed memory for long-tail recall and semantic context.
- Surface provider usage in task activity, similar to `memory` and `session_search`.

## Recommended Next Implementation Order

1. Add delete/edit propagation for Hermes files.
2. Align cron memory staging, mirroring, and prompt policy with normal todos.
3. Add tests around the runner sync helpers and cron memory behavior.
4. Improve Settings > Memory capacity/sync/realtime UX.
5. Run the live smoke-test suite on a provisioned profile.
6. Pilot one external memory provider on a single profile.

