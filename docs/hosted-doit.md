# Hosted Doit

Hosted Doit is the batteries-included path for users who want to use the app out
of the box. The app uses the managed control plane and hosted Hermes execution
environment.

## What Hosted Mode Includes

- iOS app configured for the managed Supabase project.
- Supabase Auth, Postgres, Storage, Realtime, and Edge Functions.
- A hosted runner that watches Supabase for work.
- Hermes profiles on an operator-managed VM or VPS.
- Operator-managed APNs, Composio, Browserbase, and model-provider keys.

## User Flow

1. User signs in with Apple.
2. User redeems an invite code.
3. The hosted runner provisions a Hermes profile for that user.
4. The app watches provisioning status over Supabase Realtime.
5. Todos are executed by the hosted runner and Hermes profile.

## Operator Flow

The operator maintains:

- Supabase project and Edge Function secrets.
- VM/VPS running the runner and Hermes profiles.
- `runner/.env` secrets.
- APNs key material.
- Composio/model/Browserbase accounts.
- Admin dashboard access.

See [`../hermes/setup.md`](../hermes/setup.md) and
[`../supabase/README.md`](../supabase/README.md) for the current runbooks.

## Trust Model

Hosted mode is user-isolated and privacy-minimized, but not end-to-end
encrypted.

Normal users should only be able to access their own rows through Supabase RLS.
The hosted runner uses service-role access so backend infrastructure can execute
tasks, write task progress, repair provisioning, and operate the service.

Routine operator tooling does not expose task prompts tied to user identity by
default. Admin task and issue views use aggregate and pseudonymous operational
data, such as status, timestamps, integration slug, token count, safe error
category, and anonymized user labels. Raw production credentials remain
sensitive and must stay restricted to backend infrastructure.

For the strongest data control, run a full self-hosted deployment instead.

## Public Repo vs Hosted Build

The public repo uses placeholder config. The batteries-included hosted build is
created with private configuration that points to the managed hosted backend.

Users who want the out-of-the-box experience can use the hosted build. Developers
who clone the repo should configure their own Supabase and Apple values unless
they have explicit access to the hosted deployment.
