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
//   { action: "disconnect", connection_id: "...", toolkit?: "gmail" }
//     -> { ok: true }

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const COMPOSIO_API = "https://backend.composio.dev";
const COMPOSIO_API_KEY = Deno.env.get("COMPOSIO_API_KEY") ?? "";
/** Hermes profile MCP session id (trs_…). Required to sync API-key toolkits. */
const COMPOSIO_MCP_SESSION_ID = Deno.env.get("COMPOSIO_MCP_SESSION_ID") ?? "";
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
    {
        slug: "linkedin",
        name: "LinkedIn",
        description: "Read your profile and post on your behalf.",
    },
    {
        slug: "figma",
        name: "Figma",
        description: "Browse files, read designs, and export assets.",
    },
];

interface ComposioConnectedAccount {
    id: string;
    status: string;        // e.g. "ACTIVE", "INITIATED", "FAILED"
    toolkit?: { slug?: string };
    appName?: string;      // fallback field name in some API versions
    user_id?: string;
    email?: string;
    account_email?: string;
    connected_account_email?: string;
    account?: { email?: string };
    data?: { email?: string; account_email?: string };
    metadata?: { email?: string; account_email?: string };
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
        `/api/v3/connected_accounts?user_ids=${encodeURIComponent(userId)}&limit=100`,
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

function connectedAccountEmail(conn: ComposioConnectedAccount | null | undefined): string | null {
    if (!conn) return null;
    const candidates = [
        conn.account_email,
        conn.connected_account_email,
        conn.email,
        conn.account?.email,
        conn.data?.account_email,
        conn.data?.email,
        conn.metadata?.account_email,
        conn.metadata?.email,
    ];
    for (const candidate of candidates) {
        if (typeof candidate !== "string") continue;
        const trimmed = candidate.trim();
        if (trimmed.includes("@")) return trimmed;
    }
    return null;
}

function apiKeyToolkitSlugs(): string[] {
    return CATALOG.filter((t) => t.auth_type === "api_key").map((t) => t.slug);
}

async function buildSessionConnectionContext(
    userId: string,
    toolkits: string[],
): Promise<{
    auth_configs: Record<string, string>;
    connected_accounts: Record<string, string[]>;
}> {
    const auth_configs: Record<string, string> = {};
        for (const slug of apiKeyToolkitSlugs()) {
        if (toolkits.includes(slug)) {
            auth_configs[slug] = await getOrCreateAuthConfig(slug, "API_KEY");
        }
    }

    const connected_accounts: Record<string, string[]> = {};
    for (const c of await listConnections(userId)) {
        if (c.status !== "ACTIVE") continue;
        const slug = (c.toolkit?.slug ?? c.appName ?? "").toLowerCase();
        if (!slug || !toolkits.includes(slug)) continue;
        connected_accounts[slug] = [c.id];
    }

    return { auth_configs, connected_accounts };
}

async function createSession(
    userId: string,
    toolkits = connectableSlugs(),
): Promise<string> {
    const { auth_configs, connected_accounts } = await buildSessionConnectionContext(
        userId,
        toolkits,
    );
    const payload: Record<string, unknown> = {
        user_id: userId,
        toolkits: { enable: toolkits },
        manage_connections: {
            enable: true,
            enable_wait_for_connections: false,
            enable_connection_removal: true,
        },
    };
    if (Object.keys(auth_configs).length > 0) {
        payload.auth_configs = auth_configs;
    }
    if (Object.keys(connected_accounts).length > 0) {
        payload.connected_accounts = connected_accounts;
    }

    const res = await composio("/api/v3.1/tool_router/session", {
        method: "POST",
        body: JSON.stringify(payload),
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
    auth_scheme?: string;
    is_enabled_for_tool_router?: boolean;
}

async function getOrCreateAuthConfig(
    toolkitSlug: string,
    authScheme: "API_KEY" = "API_KEY",
): Promise<string> {
    const listRes = await composio(
        `/api/v3/auth_configs?toolkit_slug=${
            encodeURIComponent(toolkitSlug)
        }&limit=10`,
    );
    if (!listRes.ok) {
        const t = await listRes.text();
        throw new Error(`composio auth_configs list failed: ${listRes.status} ${t}`);
    }
    const listData = await listRes.json();
    const items: ComposioAuthConfig[] = Array.isArray(listData)
        ? listData
        : (listData.items ?? listData.data ?? []);
    const apiKeyConfigs = items.filter((i) => i.auth_scheme === authScheme);
    const routerReady = apiKeyConfigs.find((i) =>
        i.is_enabled_for_tool_router === true
    );
    if (routerReady?.id) {
        return routerReady.id;
    }
    if (apiKeyConfigs.length > 0 && apiKeyConfigs[0].id) {
        return apiKeyConfigs[0].id;
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
    const res = await composio("/api/v3.1/connected_accounts", {
        method: "POST",
        body: JSON.stringify({
            auth_config: { id: authConfigId },
            connection: {
                user_id: userId,
                state: {
                    authScheme: "API_KEY",
                    val: { generic_api_key: apiKey },
                },
            },
            validate_credentials: true,
        }),
    });
    if (!res.ok) {
        const t = await res.text();
        if (
            res.status === 400 &&
            t.includes("Credentials validation failed")
        ) {
            throw new Error("invalid_api_key");
        }
        throw new Error(`composio api_key connect failed: ${res.status} ${t}`);
    }
    const data = await res.json();
    const connectionId: string | undefined = data.id ?? data.connection_id;
    if (!connectionId) {
        throw new Error(
            `composio api_key connect: missing id in ${JSON.stringify(data)}`,
        );
    }

    const conns = await listConnections(userId);
    for (const c of conns) {
        const slug = (c.toolkit?.slug ?? c.appName ?? "").toLowerCase();
        if (slug === toolkit && c.id !== connectionId) {
            await deleteConnection(c.id);
        }
    }
    await syncMcpSessionToolkit(toolkit, connectionId, authConfigId);
    return { connection_id: connectionId };
}

async function syncMcpSessionToolkit(
    toolkit: string,
    connectionId: string | null,
    authConfigId?: string,
): Promise<void> {
    if (!COMPOSIO_MCP_SESSION_ID) {
        console.warn(
            "COMPOSIO_MCP_SESSION_ID unset; Hermes MCP session not synced for",
            toolkit,
        );
        return;
    }
    const patch: Record<string, unknown> = {};
    if (authConfigId) {
        patch.auth_configs = { [toolkit]: authConfigId };
    }
    if (connectionId) {
        patch.connected_accounts = { [toolkit]: [connectionId] };
    } else {
        patch.connected_accounts = { [toolkit]: [] };
    }
    const res = await composio(
        `/api/v3.1/tool_router/session/${
            encodeURIComponent(COMPOSIO_MCP_SESSION_ID)
        }`,
        { method: "PATCH", body: JSON.stringify(patch) },
    );
    if (!res.ok) {
        const t = await res.text();
        console.error("mcp session sync failed:", res.status, t);
    }
}

async function syncMcpSessionConnections(userId: string): Promise<void> {
    if (!COMPOSIO_MCP_SESSION_ID) {
        console.warn("COMPOSIO_MCP_SESSION_ID unset; Hermes MCP session not synced");
        return;
    }
    const { auth_configs, connected_accounts } = await buildSessionConnectionContext(
        userId,
        connectableSlugs(),
    );
    const patch: Record<string, unknown> = {};
    if (Object.keys(auth_configs).length > 0) {
        patch.auth_configs = auth_configs;
    }
    if (Object.keys(connected_accounts).length > 0) {
        patch.connected_accounts = connected_accounts;
    }
    if (Object.keys(patch).length === 0) {
        return;
    }
    const res = await composio(
        `/api/v3.1/tool_router/session/${
            encodeURIComponent(COMPOSIO_MCP_SESSION_ID)
        }`,
        { method: "PATCH", body: JSON.stringify(patch) },
    );
    if (!res.ok) {
        const t = await res.text();
        console.error("mcp session full sync failed:", res.status, t);
        return;
    }
    console.log(
        "mcp session full sync",
        JSON.stringify({
            connected: Object.entries(connected_accounts).map(([slug, ids]) => ({
                slug,
                connection_id: ids[0],
            })),
        }),
    );
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
                        account_email: connectedAccountEmail(conn),
                    };
                });
                console.log(
                    "integrations list",
                    JSON.stringify({
                        user_id: userId,
                        connected: toolkits
                            .filter((t) => t.connected)
                            .map((t) => ({
                                slug: t.slug,
                                connection_id: t.connection_id,
                                status: t.status,
                            })),
                    }),
                );
                // OAuth redirects complete outside this Edge Function. The
                // first list/refresh after returning to the app is therefore
                // the reliable point to sync new OAuth connected_account IDs
                // into Hermes' long-lived Composio MCP session.
                await syncMcpSessionConnections(userId);
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
                if (!body.connection_id && !body.toolkit) {
                    return json({ error: "missing_connection_id" }, 400);
                }
                // Re-check ownership: only delete if this connection belongs
                // to the calling user (Composio scopes by user_id).
                const conns = await listConnections(userId);
                const requestedToolkit = (body.toolkit ?? "").toLowerCase();
                const exact = body.connection_id
                    ? conns.find((c) => c.id === body.connection_id)
                    : undefined;
                const inferredToolkit = (
                    exact?.toolkit?.slug ?? exact?.appName ?? requestedToolkit
                ).toLowerCase();
                const targets = conns.filter((c) => {
                    if (exact && c.id === exact.id) return true;
                    const slug = (c.toolkit?.slug ?? c.appName ?? "")
                        .toLowerCase();
                    return Boolean(requestedToolkit && slug === requestedToolkit);
                });
                console.log(
                    "integrations disconnect",
                    JSON.stringify({
                        user_id: userId,
                        connection_id: body.connection_id ?? null,
                        toolkit: requestedToolkit || null,
                        exact: exact?.id ?? null,
                        targets: targets.map((c) => ({
                            id: c.id,
                            slug: (c.toolkit?.slug ?? c.appName ?? "")
                                .toLowerCase(),
                            status: c.status,
                        })),
                    }),
                );
                if (targets.length === 0) {
                    // The iOS app may hold a stale connection_id after a
                    // previous disconnect, a Composio-side deletion, or a
                    // catalog/auth-config migration. Treat that as already
                    // disconnected so the client can refresh the list instead
                    // of pinning the user behind a 404 toast.
                    return json({ ok: true, already_disconnected: true });
                }
                for (const target of targets) {
                    await deleteConnection(target.id);
                }
                const catalogEntry = CATALOG.find((t) =>
                    t.slug === (requestedToolkit || inferredToolkit)
                );
                if (catalogEntry) {
                    await syncMcpSessionToolkit(catalogEntry.slug, null);
                }
                return json({ ok: true, deleted: targets.length });
            }
            default:
                return json({ error: "unknown_action" }, 400);
        }
    } catch (e) {
        console.error("integrations error:", e);
        const msg = String(e);
        if (msg.includes("invalid_api_key")) {
            const catalogEntry = body.toolkit
                ? CATALOG.find((t) => t.slug === body.toolkit)
                : undefined;
            const name = catalogEntry?.name ?? "This service";
            return json({
                error: "invalid_api_key",
                detail:
                    `${name} rejected this API key. Copy it again from the provider dashboard (no extra spaces).`,
            }, 400);
        }
        return json({ error: "internal", detail: msg }, 500);
    }
});
