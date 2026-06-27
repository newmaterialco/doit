# doit

An iOS GUI for [Hermes Agent](https://hermes-agent.nousresearch.com/docs/).
Create a todo, hand it to an agent, and watch the work stream back into the
app in real time.

## Ways To Use Doit

Doit is being shaped around several operating models:

| Path | Status | Who it is for |
| --- | --- | --- |
| Hosted Doit / managed Hermes | Works today | Users who want the official app and managed backend |
| Bring your own Hermes connector | Planned | Users who want the app as a GUI over Hermes on their own VPS, home server, or Tailscale node |
| Fork and self-host | Works for technical operators | Developers who want their own Supabase/control plane, runner, Hermes setup, and app build |
| Direct Hermes endpoint | Future/advanced | Users with a secure remote Hermes endpoint |

See [`docs/hosted-doit.md`](docs/hosted-doit.md),
[`docs/byo-connector.md`](docs/byo-connector.md), and
[`docs/self-host.md`](docs/self-host.md).

## Trust Model

Hosted Doit is **user-isolated, not end-to-end encrypted from the operator**.
Normal users are scoped to their own rows through Supabase RLS policies, but the
hosted runner and admin backend use service-role access to operate the service.
That means the hosted operator can technically access hosted task data.

BYO connector mode moves Hermes execution and profile files to user-owned
infrastructure. Full self-hosting gives the strongest data control because you
own both the control plane and execution unit.

See [`docs/security-model.md`](docs/security-model.md).

## Architecture

```
iOS (SwiftUI, Sign in with Apple)
   |
   v
Supabase (managed) ............... Auth + Postgres + Realtime + Edge Function
   ^
   |
Runner / connector ............... watches Supabase -> drives Hermes -> sends APNs
   |
   v
Hermes Gateway ................... one profile per user, isolated memory + OAuth
   |
   v
Composio Connect (MCP) ........... managed OAuth for Gmail, Calendar, Slack, ...
```

- In hosted mode, one operator VM runs the runner and many Hermes profiles.
  Each user gets a Hermes **profile** with its own API server port, memory, and
  OAuth connections, running as a `hermes@<profile>` systemd template instance.
- The **runner** is the only custom backend; it's outbound-only (no public port).
  It runs a bounded worker pool (multiple todos at once, across and within
  users) and an automated provisioner: new users redeem an **invite code**
  in the app and their agent is built end-to-end with no manual steps.
- In BYO mode, the goal is to move the runner/connector plus Hermes execution
  unit onto user-owned infrastructure while keeping the iOS realtime contract
  the same.
- Real-world actions (sending email, etc.) go through **Composio Connect** so we
  never build OAuth or store tokens ourselves.

See [`docs/architecture.md`](docs/architecture.md) for the full architecture
overview.

## Layout

```
doit/
|-- ios/         SwiftUI app (Xcode project)
|-- runner/      Python worker: Supabase -> Hermes /v1/runs -> APNs
|-- hermes/      Deploy config + setup runbook (NOT Hermes source)
|-- supabase/    SQL migrations + Edge Functions
```

## Quickstart Decision Tree

- **I want to use the official hosted app**: use the distributed app and managed
  backend. See [`docs/hosted-doit.md`](docs/hosted-doit.md).
- **I want to run the whole stack myself**: configure iOS, Supabase, runner, and
  Hermes. See [`docs/self-host.md`](docs/self-host.md).
- **I want the app to control my existing Hermes**: read
  [`docs/byo-connector.md`](docs/byo-connector.md). This path is planned and not
  the current default runtime.
- **I want to contribute code**: start with [`CONTRIBUTING.md`](CONTRIBUTING.md)
  and [`docs/task-realtime.md`](docs/task-realtime.md).

## Required Accounts For Self-Hosting

| Service | Purpose |
| --- | --- |
| Apple Developer | Sign in with Apple and APNs push |
| Supabase | Auth, DB, Realtime, Storage, Edge Functions |
| Cloud VM provider | Hosted runner + Hermes profiles |
| Nous Portal / OpenRouter | LLM access for Hermes runs |
| Composio | OAuth integrations such as Gmail, Calendar, Slack |
| Browserbase | Managed browser sessions for Hermes and browse.sh skills |

## Configuration

The iOS app reads Supabase, waitlist, signing team, and bundle identifiers from
`ios/doit/Config/Base.xcconfig`, which optionally includes the ignored
`ios/doit/Config/Local.xcconfig`. To self-host or run a fork:

```bash
cp ios/doit/Config/Local.example.xcconfig ios/doit/Config/Local.xcconfig
```

Then fill in your own Supabase and Apple values. The official hosted app uses a
private local/CI config with the managed Doit values; those values are not meant
to be committed to the public repo.

See [`docs/configuration.md`](docs/configuration.md) for `.xcconfig`, `.env`,
Supabase, APNs, and secret-handling details.

## Documentation

| Document | Purpose |
| --- | --- |
| [`docs/architecture.md`](docs/architecture.md) | Control plane vs execution unit |
| [`docs/configuration.md`](docs/configuration.md) | App config, env files, and secrets |
| [`docs/security-model.md`](docs/security-model.md) | Hosted/BYO/self-host privacy model |
| [`docs/hosted-doit.md`](docs/hosted-doit.md) | Managed app and hosted backend path |
| [`docs/byo-connector.md`](docs/byo-connector.md) | Planned BYO Hermes connector path |
| [`docs/self-host.md`](docs/self-host.md) | Full fork/self-host setup outline |
| [`docs/task-realtime.md`](docs/task-realtime.md) | iOS realtime contract |
| [`docs/apns.md`](docs/apns.md) | Push notification setup |
| [`docs/local-admin-dashboard.md`](docs/local-admin-dashboard.md) | Operator admin dashboard |

## Security And Contributing

Report vulnerabilities privately; see [`SECURITY.md`](SECURITY.md).

Before contributing, read [`CONTRIBUTING.md`](CONTRIBUTING.md). A license has
not been selected yet; add one before publishing broadly.

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
