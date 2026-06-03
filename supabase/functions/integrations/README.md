# integrations edge function

Proxies the Composio REST API so the iOS app can list, connect, and disconnect
integrations without ever seeing the Composio API key. Authenticated by the
caller's Supabase JWT; uses `auth.uid()` as the Composio `user_id`, so each
user only ever sees their own connections.

## Deploy

```bash
supabase functions deploy integrations
supabase secrets set COMPOSIO_API_KEY=ak_xxx
```

`SUPABASE_URL` and `SUPABASE_ANON_KEY` are injected by the platform.

## API

All requests are `POST /functions/v1/integrations` with `Authorization: Bearer <user-jwt>`.

```jsonc
// list available toolkits + connection state for the caller
{ "action": "list" }
// -> { "toolkits": [ { "slug": "gmail", "name": "Gmail",
//                      "description": "...", "connected": true,
//                      "connection_id": "...", "status": "ACTIVE" }, ... ] }

// initiate an OAuth connection — returns the URL the app opens in ASWebAuthenticationSession
{ "action": "connect", "toolkit": "gmail" }
// -> { "redirect_url": "https://connect.composio.dev/link/...",
//      "connection_id": "..." }

// connect an API-key toolkit (e.g. Hunter)
{ "action": "connect", "toolkit": "hunter", "api_key": "..." }
// -> { "connected": true, "connection_id": "..." }

// drop a connection
{ "action": "disconnect", "connection_id": "..." }
// -> { "ok": true }
```

## Catalog

The visible toolkit list is hardcoded in `index.ts` (`CATALOG`) so the app
shows a curated set rather than all 1000+ Composio apps. To add a service,
append to `CATALOG`. The `slug` must match Composio's canonical toolkit slug.

## Notes

- Returns 401 if the JWT is missing/invalid, 500 if `COMPOSIO_API_KEY` isn't
  set, 400 for unknown toolkits or actions.
- Connection ownership is re-checked on disconnect (the connection must belong
  to the caller's `user_id`) as a defense-in-depth check.
