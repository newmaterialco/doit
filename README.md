# doit

A "do-it-for-me" todo iOS app. Each todo can be executed by a cloud-hosted
[Hermes Agent](https://hermes-agent.nousresearch.com/docs/), which works in the
background and streams its thinking back into the app in real time.

## Architecture

```
iOS (SwiftUI, Sign in with Apple)
   |
   v
Supabase (managed) ............... Auth + Postgres + Realtime + Edge Function
   ^
   |
Runner (on one VM) ............... watches Supabase -> drives Hermes -> sends APNs
   |
   v
Hermes Gateway (same VM) ......... one profile per user, isolated memory + OAuth
   |
   v
Composio Connect (MCP) ........... managed OAuth for Gmail, Calendar, Slack, ...
```

- **One VM total**, not one per user. Each user gets a Hermes **profile** with
  its own API server port, memory, and OAuth connections.
- The **runner** is the only custom backend; it's outbound-only (no public port).
- Real-world actions (sending email, etc.) go through **Composio Connect** so we
  never build OAuth or store tokens ourselves.

## Layout

```
doit/
|-- ios/         SwiftUI app (Xcode project)
|-- runner/      Python worker: Supabase -> Hermes /v1/runs -> APNs
|-- hermes/      Deploy config + setup runbook (NOT Hermes source)
|-- supabase/    SQL migrations + Edge Functions
```

## Required accounts

| Service | Purpose | Already have? |
| --- | --- | --- |
| Apple Developer | Sign in with Apple, APNs push | yes |
| Supabase | Auth, DB, Realtime, Edge Functions | yes |
| Cloud VM provider (Hetzner / DigitalOcean) | runs Hermes + runner | needed |
| Nous Portal | LLM + Hermes built-in tools | needed |
| Composio | OAuth integrations (Gmail, etc.) | needed |

See `hermes/setup.md` for provisioning the VM and `supabase/README.md` for the
managed-side setup.

## Realtime contract (READ THIS BEFORE TOUCHING THE iOS LIST OR DETAIL VIEW)

How a task ends up on screen after the agent does work is documented in
[`docs/task-realtime.md`](docs/task-realtime.md). The short version:

- The runner writes Postgres rows.
- Supabase Realtime publishes those changes to the iOS client.
- `TodoRealtimeHub` (in `ios/doit/doit/Supabase/TodoRealtimeHub.swift`) pulls
  the row id out of the payload and hands it to `TodoStore`.
- `TodoStore` (in `ios/doit/doit/Stores/TodoStore.swift`) is the single
  app-scoped owner of task / cron / interaction / artifact state. Views
  observe it; views do NOT keep their own `@State` copies.
- APNs is a backup channel for when the app isn't running. It is not the
  primary path for in-app updates.

If you (or another agent) are about to add `@State private var todos: [Todo]`
to a view, or a `Timer` that refetches the list every few seconds, stop and
re-read the doc — that pattern is exactly what the store exists to prevent
and it is the reason the list previously stopped updating after the prep
pass.
