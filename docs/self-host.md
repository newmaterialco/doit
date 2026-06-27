# Self-Hosting

Self-hosting is for developers and operators who want to run their own Doit
deployment instead of using the managed hosted app.

Self-hosting gives you control over both:

- the **control plane**: Supabase or a compatible replacement, auth, database,
  realtime, storage, Edge Functions, and admin tooling
- the **execution unit**: runner, Hermes profiles, profile files, APNs, Composio,
  model provider keys, and browser automation keys

## Required Accounts

You need:

- Apple Developer account for Sign in with Apple, bundle IDs, app signing, and
  APNs
- Supabase project
- VM or VPS for the runner and Hermes profiles
- Hermes / Nous Portal or compatible model-provider setup
- Composio project for OAuth integrations
- Browserbase account if you want hosted browser sessions
- model provider keys such as OpenRouter

## Setup Outline

1. Configure iOS build settings:

   ```bash
   cp ios/doit/Config/Local.example.xcconfig ios/doit/Config/Local.xcconfig
   ```

   Fill in your Supabase, Apple team, bundle IDs, and waitlist URL.

2. Create and configure Supabase:

   Follow [`../supabase/README.md`](../supabase/README.md). Apply migrations,
   enable Sign in with Apple, deploy Edge Functions, and set Edge Function
   secrets.

3. Set up runner and Hermes:

   Follow [`../hermes/setup.md`](../hermes/setup.md). Use your own VM/VPS and
   runner `.env` values.

4. Configure APNs:

   Follow [`apns.md`](apns.md). Your `APNS_TOPIC` should match your main app
   bundle ID.

5. Build and run the iOS app.

## Important Secret Boundaries

Only the anon Supabase key belongs in the iOS app. It is public and RLS-scoped.

Never put these in the iOS app:

- Supabase service-role key
- `ADMIN_SECRET`
- APNs private key
- Composio API key
- model provider keys
- Browserbase API key
- Hermes profile `.env` files

## Current Limitations

This repo currently assumes Supabase as the control plane. Replacing Supabase
with another backend would require replacing auth, RLS/API authorization,
Realtime, Storage, Edge Functions, admin APIs, and the runner database client.

BYO connector mode is planned separately. Until that exists, a full self-hosted
deployment should run the runner and Hermes profiles together, similar to the
hosted architecture.
