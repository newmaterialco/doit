// Supabase Edge Function: integrations
//
// Proxies the Composio REST API so the Composio key never reaches the iOS app.
// Auto-authenticated by the user's Supabase JWT — auth.uid() becomes the
// Composio `user_id`, so each user only ever sees their own connections.
//
// Endpoints (all POST, body { action, ... }):
//   { action: "list" }
//     -> { toolkits: [{ slug, name, description, connected, connection_id?, connectable? }] }
//   { action: "connect", toolkit: "gmail" }
//     -> { redirect_url: "https://...", connection_id: "..." }
//   { action: "connect", toolkit: "hunter", api_key: "..." }
//     -> { connected: true, connection_id: "..." }
//   { action: "disconnect", connection_id: "..." }
//     -> { ok: true }

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const COMPOSIO_API = "https://backend.composio.dev";
const COMPOSIO_API_KEY = Deno.env.get("COMPOSIO_API_KEY") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

// Catalog of services we surface in the iOS Integrations page.
// `slug` is the Composio toolkit slug (lowercase canonical app name).
type AuthType = "oauth" | "api_key";

const CATALOG: Array<{
    slug: string;
    name: string;
    description: string;
    /** When false the toolkit is always available (no connect flow). */
    connectable?: boolean;
    /** OAuth redirect (default) or user-supplied API key. */
    auth_type?: AuthType;
}> = [
    {
        slug: "gmail",
        name: "Gmail",
        description: "Send and read emails on your behalf.",
    },
    {
        slug: "googlecalendar",
        name: "Google Calendar",
        description: "Create, move, and find events.",
    },
    {
        slug: "googledrive",
        name: "Google Drive",
        description: "Find, read, and organize files in Drive.",
    },
    {
        slug: "googledocs",
        name: "Google Docs",
        description: "Read and draft documents.",
    },
    {
        slug: "googlesheets",
        name: "Google Sheets",
        description: "Read and update spreadsheets.",
    },
    {
        slug: "slack",
        name: "Slack",
        description: "Send messages and search channels.",
    },
    {
        slug: "notion",
        name: "Notion",
        description: "Read pages and add notes to your workspace.",
    },
    {
        slug: "linear",
        name: "Linear",
        description: "Create and update issues.",
    },
    {
        slug: "github",
        name: "GitHub",
        description: "Open issues and read repos.",
    },
    {
        slug: "reddit",
        name: "Reddit",
        description: "Browse, post, and comment on subreddits.",
    },
    {
        slug: "hunter",
        name: "Hunter",
        description: "Find and verify professional email addresses.",
        auth_type: "api_key",
    },
];

interface ComposioConnectedAccount {
    id: string;
    status: string;        // e.g. "ACTIVE", "INITIATED", "FAILED"
    toolkit?: { slug?: string };
    appName?: string;      // fallback field name in some API versions
    user_id?: string;
}

interface ComposioSession {
    session_id?: string;
    id?: string;
}

interface ComposioToolkit {
    slug: string;
    logo?: string;
    meta?: {
        logo?: string;
        app_url?: string | null;
        description?: string;
    } | null;
    connected_account?: ComposioConnectedAccount | null;
    connection?: {
        is_active?: boolean;
        connected_account?: ComposioConnectedAccount | null;
    } | null;
}

function connectableSlugs(): string[] {
    return CATALOG.filter((t) => t.connectable !== false).map((t) => t.slug);
}

function corsHeaders(): HeadersInit {
    return {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers":
            "authorization, x-client-info, apikey, content-type",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
    };
}

function json(body: unknown, status = 200): Response {
    return new Response(JSON.stringify(body), {
        status,
        headers: { ...corsHeaders(), "Content-Type": "application/json" },
    });
}

async function composio(
    path: string,
    init: RequestInit = {},
): Promise<Response> {
    const headers = new Headers(init.headers ?? {});
    headers.set("x-api-key", COMPOSIO_API_KEY);
    headers.set("Content-Type", "application/json");
    return fetch(`${COMPOSIO_API}${path}`, { ...init, headers });
}

async function listConnections(
    userId: string,
): Promise<ComposioConnectedAccount[]> {
    const res = await composio(
        `/api/v3/connected_accounts?user_ids=${encodeURIComponent(userId)}`,
    );
    if (!res.ok) {
        const t = await res.text();
        throw new Error(`composio list failed: ${res.status} ${t}`);
    }
    const data = await res.json();
    // Composio responses vary in shape between API versions; accept both
    // `{ items: [...] }` and a bare array.
    return Array.isArray(data) ? data : (data.items ?? data.data ?? []);
}

async function createSession(
    userId: string,
    toolkits = connectableSlugs(),
): Promise<string> {
    const res = await composio("/api/v3.1/tool_router/session", {
        method: "POST",
        body: JSON.stringify({
            user_id: userId,
            toolkits: { enable: toolkits },
            manage_connections: {
                enable: true,
                enable_wait_for_connections: false,
                enable_connection_removal: true,
            },
        }),
    });
    if (!res.ok) {
        const t = await res.text();
        throw new Error(`composio session failed: ${res.status} ${t}`);
    }
    const data: ComposioSession = await res.json();
    const sessionId = data.session_id ?? data.id;
    if (!sessionId) {
        throw new Error(`composio session: missing session_id in ${JSON.stringify(data)}`);
    }
    return sessionId;
}

async function listSessionToolkits(
    sessionId: string,
    slugs = connectableSlugs(),
): Promise<ComposioToolkit[]> {
    const slugList = slugs.join(",");
    const res = await composio(
        `/api/v3.1/tool_router/session/${encodeURIComponent(sessionId)}/toolkits?limit=50&toolkits=${encodeURIComponent(slugList)}`,
    );
    if (!res.ok) {
        const t = await res.text();
        throw new Error(`composio toolkits failed: ${res.status} ${t}`);
    }
    const data = await res.json();
    return Array.isArray(data) ? data : (data.items ?? data.data ?? []);
}

async function initiateConnection(
    userId: string,
    toolkit: string,
): Promise<{ redirect_url: string; connection_id: string }> {
    const sessionId = await createSession(userId, [toolkit]);
    const res = await composio(
        `/api/v3.1/tool_router/session/${encodeURIComponent(sessionId)}/link`,
        {
            method: "POST",
            body: JSON.stringify({ toolkit }),
        },
    );
    if (!res.ok) {
        const t = await res.text();
        throw new Error(`composio link failed: ${res.status} ${t}`);
    }
    const data = await res.json();
    const redirectUrl: string | undefined =
        data.redirect_url ?? data.redirectUrl ?? data.link;
    const connectionId: string | undefined =
        data.connected_account_id ?? data.connection_id ?? data.connectionId ?? data.id;
    if (!redirectUrl || !connectionId) {
        throw new Error(
            `composio link: missing redirect_url/connection_id in ${
                JSON.stringify(data)
            }`,
        );
    }
    return { redirect_url: redirectUrl, connection_id: connectionId };
}

interface ComposioAuthConfig {
    id: string;
}

async function getOrCreateAuthConfig(toolkitSlug: string): Promise<string> {
    const listRes = await composio(
        `/api/v3/auth_configs?toolkit_slug=${
            encodeURIComponent(toolkitSlug)
        }&limit=5`,
    );
    if (!listRes.ok) {
        const t = await listRes.text();
        throw new Error(`composio auth_configs list failed: ${listRes.status} ${t}`);
    }
    const listData = await listRes.json();
    const items: ComposioAuthConfig[] = Array.isArray(listData)
        ? listData
        : (listData.items ?? listData.data ?? []);
    if (items.length > 0 && items[0].id) {
        return items[0].id;
    }

    const createRes = await composio("/api/v3/auth_configs", {
        method: "POST",
        body: JSON.stringify({
            toolkit: { slug: toolkitSlug },
            auth_config: {
                type: "use_custom_auth",
                authScheme: "API_KEY",
            },
        }),
    });
    if (!createRes.ok) {
        const t = await createRes.text();
        throw new Error(`composio auth_config create failed: ${createRes.status} ${t}`);
    }
    const created = await createRes.json();
    const authConfigId = created.id ?? created.auth_config_id;
    if (!authConfigId) {
        throw new Error(
            `composio auth_config create: missing id in ${JSON.stringify(created)}`,
        );
    }
    return authConfigId;
}

async function connectApiKey(
    userId: string,
    toolkit: string,
    apiKey: string,
): Promise<{ connection_id: string }> {
    const authConfigId = await getOrCreateAuthConfig(toolkit);
    const conns = await listConnections(userId);
    for (const c of conns) {
        const slug = (c.toolkit?.slug ?? c.appName ?? "").toLowerCase();
        if (slug === toolkit) {
            await deleteConnection(c.id);
        }
    }
    const res = await composio("/api/v3/connected_accounts", {
        method: "POST",
        body: JSON.stringify({
            auth_config: { id: authConfigId },
            user_id: userId,
            connection: {
                state: {
                    authScheme: "API_KEY",
                    val: { generic_api_key: apiKey },
                },
            },
        }),
    });
    if (!res.ok) {
        const t = await res.text();
        throw new Error(`composio api_key connect failed: ${res.status} ${t}`);
    }
    const data = await res.json();
    const connectionId: string | undefined = data.id ?? data.connection_id;
    if (!connectionId) {
        throw new Error(
            `composio api_key connect: missing id in ${JSON.stringify(data)}`,
        );
    }
    return { connection_id: connectionId };
}

async function deleteConnection(connectionId: string): Promise<void> {
    const res = await composio(
        `/api/v3/connected_accounts/${encodeURIComponent(connectionId)}`,
        { method: "DELETE" },
    );
    if (!res.ok && res.status !== 404) {
        const t = await res.text();
        throw new Error(`composio delete failed: ${res.status} ${t}`);
    }
}

serve(async (req) => {
    if (req.method === "OPTIONS") {
        return new Response("ok", { headers: corsHeaders() });
    }
    if (req.method !== "POST") {
        return json({ error: "method_not_allowed" }, 405);
    }

    if (!COMPOSIO_API_KEY) {
        return json({ error: "composio_not_configured" }, 500);
    }

    // Identify the caller via their Supabase JWT.
    const authHeader = req.headers.get("Authorization") ?? "";
    if (!authHeader.startsWith("Bearer ")) {
        return json({ error: "unauthorized" }, 401);
    }
    const supa = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
        global: { headers: { Authorization: authHeader } },
    });
    const { data: userResp, error: userErr } = await supa.auth.getUser();
    if (userErr || !userResp.user) {
        return json({ error: "unauthorized" }, 401);
    }
    const userId = userResp.user.id;

    let body: {
        action?: string;
        toolkit?: string;
        connection_id?: string;
        api_key?: string;
    };
    try {
        body = await req.json();
    } catch {
        return json({ error: "invalid_json" }, 400);
    }

    try {
        switch (body.action) {
            case "list": {
                const sessionId = await createSession(userId);
                const [sessionToolkits, conns] = await Promise.all([
                    listSessionToolkits(sessionId),
                    listConnections(userId),
                ]);
                const bySlug = new Map<string, ComposioConnectedAccount>();
                for (const tk of sessionToolkits) {
                    const conn = tk.connected_account ??
                        tk.connection?.connected_account ?? null;
                    if (conn) {
                        bySlug.set(tk.slug.toLowerCase(), conn);
                    }
                }
                for (const c of conns) {
                    const slug = (c.toolkit?.slug ?? c.appName ?? "")
                        .toLowerCase();
                    if (!slug) continue;
                    // Prefer ACTIVE connections; otherwise keep what we have.
                    const existing = bySlug.get(slug);
                    if (!existing || c.status === "ACTIVE") {
                        bySlug.set(slug, c);
                    }
                }
                const toolkits = CATALOG.map((t) => {
                    const connectable = t.connectable !== false;
                    const conn = connectable ? bySlug.get(t.slug) : null;
                    return {
                        slug: t.slug,
                        name: t.name,
                        description: t.description,
                        auth_type: t.auth_type ?? "oauth",
                        connectable,
                        connected: connectable
                            ? conn?.status === "ACTIVE"
                            : true,
                        connection_id: conn?.id ?? null,
                        status: conn?.status ?? null,
                    };
                });
                return json({ toolkits });
            }
            case "connect": {
                if (!body.toolkit) {
                    return json({ error: "missing_toolkit" }, 400);
                }
                const catalogEntry = CATALOG.find((t) => t.slug === body.toolkit);
                if (!catalogEntry) {
                    return json({ error: "unknown_toolkit" }, 400);
                }
                if (catalogEntry.connectable === false) {
                    return json({ error: "not_connectable" }, 400);
                }
                if (catalogEntry.auth_type === "api_key") {
                    const apiKey = body.api_key?.trim() ?? "";
                    if (!apiKey) {
                        return json({ error: "missing_api_key" }, 400);
                    }
                    const result = await connectApiKey(
                        userId,
                        body.toolkit,
                        apiKey,
                    );
                    return json({ connected: true, ...result });
                }
                const result = await initiateConnection(
                    userId,
                    body.toolkit,
                );
                return json(result);
            }
            case "disconnect": {
                if (!body.connection_id) {
                    return json({ error: "missing_connection_id" }, 400);
                }
                // Re-check ownership: only delete if this connection belongs
                // to the calling user (Composio scopes by user_id).
                const conns = await listConnections(userId);
                if (!conns.some((c) => c.id === body.connection_id)) {
                    return json({ error: "not_found" }, 404);
                }
                await deleteConnection(body.connection_id);
                return json({ ok: true });
            }
            default:
                return json({ error: "unknown_action" }, 400);
        }
    } catch (e) {
        console.error("integrations error:", e);
        return json({ error: "internal", detail: String(e) }, 500);
    }
});
