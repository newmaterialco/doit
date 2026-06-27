// Supabase Edge Function: connector
//
// BYO Hermes connector API. The user-owned connector calls this with
// X-Connector-Token. The token is hashed and matched server-side; the connector
// never receives service-role credentials from this function.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const CONNECTOR_COLUMNS =
    "user_id,status,profile_name,endpoint_url,capabilities,last_heartbeat_at,created_at,updated_at";

function corsHeaders(): HeadersInit {
    return {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers":
            "authorization, x-client-info, apikey, content-type, x-connector-token",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
    };
}

function json(body: unknown, status = 200): Response {
    return new Response(JSON.stringify(body), {
        status,
        headers: { ...corsHeaders(), "Content-Type": "application/json" },
    });
}

async function sha256Hex(value: string): Promise<string> {
    const bytes = new TextEncoder().encode(value);
    const digest = await crypto.subtle.digest("SHA-256", bytes);
    return Array.from(new Uint8Array(digest))
        .map((b) => b.toString(16).padStart(2, "0"))
        .join("");
}

serve(async (req) => {
    if (req.method === "OPTIONS") {
        return new Response("ok", { headers: corsHeaders() });
    }
    if (req.method !== "POST") {
        return json({ error: "method_not_allowed" }, 405);
    }
    if (!SUPABASE_SERVICE_ROLE_KEY) {
        return json({ error: "service_role_not_configured" }, 500);
    }

    const token = req.headers.get("X-Connector-Token") ?? "";
    if (!token) {
        return json({ error: "connector_token_required" }, 401);
    }

    let body: {
        action?: string;
        todo_id?: string;
        fields?: Record<string, unknown>;
        step?: {
            todo_id?: string;
            kind?: string;
            text?: string | null;
            url?: string | null;
            tool_name?: string | null;
        };
        profile_name?: string | null;
        endpoint_url?: string | null;
        capabilities?: Record<string, unknown>;
    };
    try {
        body = await req.json();
    } catch {
        return json({ error: "invalid_json" }, 400);
    }

    const serviceClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    const tokenHash = await sha256Hex(token);

    const { data: existing, error: lookupError } = await serviceClient
        .from("byo_connectors")
        .select(CONNECTOR_COLUMNS)
        .eq("connector_token_hash", tokenHash)
        .neq("status", "revoked")
        .maybeSingle();
    if (lookupError) throw lookupError;
    if (!existing) {
        return json({ error: "invalid_connector_token" }, 401);
    }
    const userId = existing.user_id;

    async function claimTodo(kind: "requested" | "stale_running") {
        const now = new Date();
        let query = serviceClient
            .from("todos")
            .select("*")
            .eq("user_id", userId)
            .order("created_at")
            .limit(1);
        if (kind === "requested") {
            query = query.eq("status", "requested");
        } else {
            const staleBefore = new Date(now.getTime() - 15 * 60 * 1000).toISOString();
            query = query
                .eq("status", "running")
                .or(`run_claimed_at.is.null,run_claimed_at.lt.${staleBefore}`);
        }
        const { data: rows, error: selectError } = await query;
        if (selectError) throw selectError;
        const candidate = rows?.[0];
        if (!candidate) return null;

        let updateQuery = serviceClient
            .from("todos")
            .update({
                status: "running",
                run_claimed_at: now.toISOString(),
                error_message: null,
            })
            .eq("id", candidate.id)
            .eq("user_id", userId)
            .select("*");
        if (kind === "requested") {
            updateQuery = updateQuery.eq("status", "requested");
        } else {
            const staleBefore = new Date(now.getTime() - 15 * 60 * 1000).toISOString();
            updateQuery = updateQuery
                .eq("status", "running")
                .or(`run_claimed_at.is.null,run_claimed_at.lt.${staleBefore}`);
        }
        const { data, error } = await updateQuery;
        if (error) throw error;
        return data?.[0] ?? null;
    }

    function scopedTodoId(): string | Response {
        const todoId = (body.todo_id ?? body.step?.todo_id ?? "").trim();
        if (!todoId) return json({ error: "missing_todo_id" }, 400);
        return todoId;
    }

    const allowedTodoFields = new Set([
        "status",
        "hermes_run_id",
        "hermes_session_id",
        "error_message",
        "completed_at",
        "total_tokens",
    ]);

    function sanitizeTodoFields(fields: Record<string, unknown> | undefined) {
        const patch: Record<string, unknown> = {};
        for (const [key, value] of Object.entries(fields ?? {})) {
            if (allowedTodoFields.has(key)) patch[key] = value;
        }
        return patch;
    }

    switch (body.action) {
        case "register":
        case "heartbeat": {
            const patch = {
                status: "online",
                profile_name: body.profile_name ?? existing.profile_name ?? null,
                endpoint_url: body.endpoint_url ?? existing.endpoint_url ?? null,
                capabilities: body.capabilities ?? existing.capabilities ?? {},
                last_heartbeat_at: new Date().toISOString(),
            };
            const { data, error } = await serviceClient
                .from("byo_connectors")
                .update(patch)
                .eq("user_id", existing.user_id)
                .select(CONNECTOR_COLUMNS)
                .single();
            if (error) throw error;
            return json({ connector: data });
        }
        case "claim_next": {
            return json({ todo: await claimTodo("requested") });
        }
        case "recover_stale": {
            return json({ todo: await claimTodo("stale_running") });
        }
        case "touch_lease": {
            const todoId = scopedTodoId();
            if (todoId instanceof Response) return todoId;
            const { error } = await serviceClient
                .from("todos")
                .update({ run_claimed_at: new Date().toISOString() })
                .eq("id", todoId)
                .eq("user_id", userId);
            if (error) throw error;
            return json({ ok: true });
        }
        case "update_todo": {
            const todoId = scopedTodoId();
            if (todoId instanceof Response) return todoId;
            const patch = sanitizeTodoFields(body.fields);
            if (Object.keys(patch).length === 0) {
                return json({ error: "no_allowed_fields" }, 400);
            }
            const { data, error } = await serviceClient
                .from("todos")
                .update(patch)
                .eq("id", todoId)
                .eq("user_id", userId)
                .select("*")
                .single();
            if (error) throw error;
            return json({ todo: data });
        }
        case "insert_step": {
            const step = body.step ?? {};
            const todoId = scopedTodoId();
            if (todoId instanceof Response) return todoId;
            const kind = String(step.kind ?? "");
            if (![
                "thought",
                "tool_started",
                "tool_result",
                "oauth_needed",
                "input_needed",
                "final",
                "error",
            ].includes(kind)) {
                return json({ error: "invalid_step_kind" }, 400);
            }
            const { data, error } = await serviceClient
                .from("todo_steps")
                .insert({
                    todo_id: todoId,
                    user_id: userId,
                    kind,
                    text: step.text ?? null,
                    url: step.url ?? null,
                    tool_name: step.tool_name ?? null,
                })
                .select("*")
                .single();
            if (error) throw error;
            return json({ step: data });
        }
        default:
            return json({ error: "unknown_action" }, 400);
    }
});
