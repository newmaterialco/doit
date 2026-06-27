# Security Model

Doit has two major trust boundaries:

- **Control plane**: auth, task state, memories, realtime updates, attachments,
  Edge Functions, and admin APIs. This repo currently uses Supabase for that.
- **Execution unit**: runner or connector, Hermes gateway, Hermes profile files,
  and third-party tool/model credentials.

## Hosted Mode

Hosted Doit is convenient, managed, and privacy-minimized. It is user-isolated,
but it is not end-to-end encrypted from the service operator.

Normal app users access data through Supabase Auth and RLS policies such as
`auth.uid() = user_id`, so one user should not be able to read another user's
rows through the app.

The hosted runner uses service-role access. Service-role credentials bypass RLS
so backend infrastructure can execute tasks, write status updates, send pushes,
repair provisioning, and operate the service.

Routine admin tooling is privacy-minimized: task and issue views use aggregate
and pseudonymous operational data by default and do not expose task prompts,
preparation summaries, memory titles, or user emails tied to task rows. Raw
production database credentials remain highly sensitive and must be restricted
to backend infrastructure.

Do not claim hosted mode is end-to-end encrypted unless task content is changed
to be encrypted in a way the hosted runner cannot read while still executing
the task.

Hosted users can use the batteries-included app experience out of the box.
Public source builds use placeholders by default and are intended for
contributors, forks, and self-hosters.

## BYO Hermes Connector Mode

The intended BYO path is a connector that runs beside a user's Hermes setup,
for example on a VPS, home server, or Tailscale node.

In that model, Hermes execution and profile files live on user-owned
infrastructure. If the connector still talks to the hosted Doit control plane,
task state and other synced rows may still be visible to the hosted operator.

BYO connector mode improves control over the execution environment. It is not
the same as full self-hosting unless the control plane is also user-owned.

## Full Self-Host Mode

Full self-hosting is the strongest privacy path. A self-hosting user controls
both the control plane and execution unit, including Supabase or its
replacement, runner credentials, Hermes profiles, app signing, and third-party
keys.

This is the mode to choose if the operator must not be able to inspect hosted
task data.

## Secrets

Never put backend secrets in iOS app code or static public files. Anything
embedded in the app bundle can be inspected by users.

Keep these server-side only:

- `SUPABASE_SERVICE_ROLE_KEY`
- `ADMIN_SECRET`
- Composio API keys
- Model provider keys such as OpenRouter, OpenAI, Anthropic, or Nous keys
- APNs private keys
- Browserbase API keys
- Hermes profile `.env` files

The Supabase anon key is public and RLS-scoped, but public repos should still
use placeholders so clones do not point at a production project by default.
