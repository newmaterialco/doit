// Supabase Edge Function: integrations
//
// Proxies the Composio REST API so the Composio key never reaches the iOS app.
// Auto-authenticated by the user's Supabase JWT — auth.uid() becomes the
// Composio `user_id`, so each user only ever sees their own connections.
//
// Endpoints (all POST, body { action, ... }):
//   { action: "list" }
//     -> { toolkits: [{ slug, name, description, logo_url, connected, connection_id? }] }
//   { action: "connect", toolkit: "gmail" }
//     -> { redirect_url: "https://...", connection_id: "..." }
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
const CATALOG: Array<{
    slug: string;
    name: string;
    description: string;
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

async function listAvailableToolkits(): Promise<ComposioToolkit[]> {
    const res = await composio("/api/v3.1/toolkits?limit=1000");
    if (!res.ok) {
        const t = await res.text();
        throw new Error(`composio available toolkits failed: ${res.status} ${t}`);
    }
    const data = await res.json();
    return Array.isArray(data) ? data : (data.items ?? data.data ?? []);
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
    toolkits = CATALOG.map((t) => t.slug),
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
): Promise<ComposioToolkit[]> {
    const slugs = CATALOG.map((t) => t.slug).join(",");
    const res = await composio(
        `/api/v3.1/tool_router/session/${encodeURIComponent(sessionId)}/toolkits?limit=50&toolkits=${encodeURIComponent(slugs)}`,
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

    let body: { action?: string; toolkit?: string; connection_id?: string };
    try {
        body = await req.json();
    } catch {
        return json({ error: "invalid_json" }, 400);
    }

    try {
        switch (body.action) {
            case "list": {
                const sessionId = await createSession(userId);
                const sessionToolkits = await listSessionToolkits(sessionId);
                const availableToolkits = await listAvailableToolkits();
                const conns = await listConnections(userId);
                const bySlug = new Map<string, ComposioConnectedAccount>();
                const toolkitMetadataBySlug = new Map<string, ComposioToolkit>();
                for (const tk of availableToolkits) {
                    toolkitMetadataBySlug.set(tk.slug.toLowerCase(), tk);
                }
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
                    const sessionToolkit = sessionToolkits.find((tk) =>
                        tk.slug.toLowerCase() === t.slug
                    );
                    const metadataToolkit = toolkitMetadataBySlug.get(t.slug);
                    const conn = bySlug.get(t.slug);
                    return {
                        slug: t.slug,
                        name: t.name,
                        description: t.description,
                        logo_url: metadataToolkit?.meta?.logo ??
                            metadataToolkit?.logo ??
                            sessionToolkit?.meta?.logo ??
                            sessionToolkit?.logo ??
                            null,
                        connected: conn?.status === "ACTIVE",
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
                if (!CATALOG.some((t) => t.slug === body.toolkit)) {
                    return json({ error: "unknown_toolkit" }, 400);
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
