# Configuration

Doit uses two kinds of configuration:

- **Public app configuration** that can be embedded in an iOS binary, such as a
  Supabase project URL and anon key.
- **Private backend secrets** that must stay in local env files, hosted provider
  secrets, or CI secret stores.

## iOS Configuration

The iOS app reads its public runtime values from Xcode build settings.

Tracked files:

- [`ios/doit/Config/Base.xcconfig`](../ios/doit/Config/Base.xcconfig) contains
  placeholder defaults for public source builds.
- [`ios/doit/Config/Local.example.xcconfig`](../ios/doit/Config/Local.example.xcconfig)
  shows what a local override should contain.
- [`ios/doit/Config/AppInfo.plist`](../ios/doit/Config/AppInfo.plist) injects
  those values into the app bundle.

Ignored local file:

- `ios/doit/Config/Local.xcconfig`

To configure a fork:

```bash
cp ios/doit/Config/Local.example.xcconfig ios/doit/Config/Local.xcconfig
```

Then fill in:

- `DOIT_SUPABASE_URL`
- `DOIT_SUPABASE_ANON_KEY`
- `DOIT_WAITLIST_URL`
- `DOIT_DEVELOPMENT_TEAM`
- `DOIT_BUNDLE_ID`
- `DOIT_TESTS_BUNDLE_ID`
- `DOIT_UITESTS_BUNDLE_ID`
- `DOIT_WIDGET_BUNDLE_ID`

The batteries-included hosted build uses a private `Local.xcconfig` or
CI-injected equivalent. Do not commit that file.

## Runner Configuration

The runner uses `runner/.env`, which is ignored by git. Start from
[`runner/.env.example`](../runner/.env.example).

Important runner secrets include:

- `SUPABASE_SERVICE_ROLE_KEY`
- `COMPOSIO_API_KEY`
- model provider keys such as `OPENROUTER_API_KEY`
- `BROWSERBASE_API_KEY`
- APNs key path, key id, team id, and topic

These values must never be embedded in the iOS app.

## Supabase Configuration

Supabase project setup is documented in [`../supabase/README.md`](../supabase/README.md).

The anon key is public and RLS-scoped. It can be shipped in an app binary, but
the public repo should use placeholders so clones do not point to a production
project by default.

The service-role key is private. It bypasses RLS and belongs only in the runner
environment or trusted Edge Function secrets.

## Admin Dashboard

The admin dashboard is operator tooling. It requires:

- the deployed `admin` Edge Function URL
- the project anon key
- `ADMIN_SECRET`

`ADMIN_SECRET` must not be committed, shared publicly, or embedded in the iOS
app.

## What Never Goes In Git

- real `.env` files
- `Local.xcconfig`
- APNs `.p8` or `.p12` files
- Supabase service-role keys
- admin secrets
- third-party API keys
- waitlist exports or invite CSVs
- Hermes profile `.env` files and token directories
