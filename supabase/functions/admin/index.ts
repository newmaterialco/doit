// Supabase Edge Function: admin
//
// Operator-only dashboard API. Authenticated via X-Admin-Secret header
// (ADMIN_SECRET env var). All reads/writes use service_role.
//
// Endpoints (all POST, body { action, ... }):
//   { action: "summary" }  -> admin_ops_summary()
//   { action: "users" }    -> auth.admin.listUsers + admin_user_stats()
//   { action: "invites" }  -> admin_invite_codes()
//   { action: "feedback" } -> { feedback: [...] }
//   { action: "tasks", limit?, offset?, search?, status?, user_id?, connection_slug? }
//                          -> { tasks: [...] }
//   { action: "create_invite", note?, max_uses?, expires_at? }
//                          -> inserts invite_codes (auto-generates code if omitted)

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const ADMIN_SECRET = Deno.env.get("ADMIN_SECRET") ?? "";

const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

function corsHeaders(): HeadersInit {
    return {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers":
            "authorization, x-client-info, apikey, content-type, x-admin-secret",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
    };
}

function json(body: unknown, status = 200): Response {
    return new Response(JSON.stringify(body), {
        status,
        headers: { ...corsHeaders(), "Content-Type": "application/json" },
    });
}

function unauthorized(): Response {
    return json({ error: "unauthorized" }, 401);
}

function generateInviteCode(): string {
    const bytes = crypto.getRandomValues(new Uint8Array(8));
    let suffix = "";
    for (let i = 0; i < 8; i++) {
        suffix += CODE_ALPHABET[bytes[i]! % CODE_ALPHABET.length];
    }
    return `DOIT-${suffix}`;
}

function clampInt(value: unknown, min: number, max: number, fallback: number): number {
    const n = Number(value);
    if (!Number.isFinite(n)) return fallback;
    return Math.max(min, Math.min(max, Math.floor(n)));
}

function normalizeExpiresAt(value: unknown): string | null {
    if (value === null || value === undefined || value === "") {
        return null;
    }
    const text = String(value).trim();
    if (!text) return null;
    const parsed = Date.parse(text);
    if (Number.isNaN(parsed)) return null;
    return new Date(parsed).toISOString();
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
    if (!ADMIN_SECRET) {
        return json({ error: "admin_secret_not_configured" }, 500);
    }

    const providedSecret = req.headers.get("X-Admin-Secret") ?? "";
    if (providedSecret !== ADMIN_SECRET) {
        return unauthorized();
    }

    const serviceClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    let body: {
        action?: string;
        code?: string;
        note?: string;
        max_uses?: number;
        expires_at?: string | null;
        limit?: number;
        offset?: number;
        search?: string;
        status?: string;
        user_id?: string;
        connection_slug?: string;
    };
    try {
        body = await req.json();
    } catch {
        return json({ error: "invalid_json" }, 400);
    }

    try {
        switch (body.action) {
            case "summary": {
                const { data, error } = await serviceClient.rpc("admin_ops_summary");
                if (error) throw error;
                const row = Array.isArray(data) ? data[0] : data;
                return json(row ?? {});
            }
            case "users": {
                const { data: stats, error: statsErr } = await serviceClient.rpc(
                    "admin_user_stats",
                );
                if (statsErr) throw statsErr;
                const statsByUser = new Map(
                    (stats ?? []).map((row: Record<string, unknown>) => [
                        String(row.user_id),
                        row,
                    ]),
                );

                const users: Record<string, unknown>[] = [];
                let page = 1;
                const perPage = 1000;
                while (true) {
                    const { data: listed, error: listErr } =
                        await serviceClient.auth.admin.listUsers({ page, perPage });
                    if (listErr) throw listErr;
                    for (const user of listed.users ?? []) {
                        const stat = statsByUser.get(user.id) ?? {};
                        users.push({
                            user_id: user.id,
                            email: user.email ?? null,
                            signed_up_at: user.created_at ?? null,
                            provisioning_status: stat.provisioning_status ?? null,
                            profile_name: stat.profile_name ?? null,
                            invite_code: stat.invite_code ?? null,
                            todos_total: stat.todos_total ?? 0,
                            todos_done: stat.todos_done ?? 0,
                            todos_failed: stat.todos_failed ?? 0,
                            total_tokens: stat.total_tokens ?? 0,
                            last_active_at: stat.last_active_at ?? null,
                            memory_count: stat.memory_count ?? 0,
                            cron_count: stat.cron_count ?? 0,
                        });
                    }
                    if ((listed.users?.length ?? 0) < perPage) break;
                    page += 1;
                }

                users.sort((a, b) =>
                    String(b.signed_up_at ?? "").localeCompare(
                        String(a.signed_up_at ?? ""),
                    )
                );
                return json({ users });
            }
            case "invites": {
                const { data, error } = await serviceClient.rpc("admin_invite_codes");
                if (error) throw error;
                return json({ invites: data ?? [] });
            }
            case "feedback": {
                const { data, error } = await serviceClient
                    .from("beta_feedback")
                    .select(
                        "id,user_id,message,include_email,contact_email,app_version,ios_version,device_model,created_at",
                    )
                    .order("created_at", { ascending: false })
                    .limit(200);
                if (error) throw error;
                return json({ feedback: data ?? [] });
            }
            case "tasks": {
                const limit = clampInt(body.limit, 1, 100, 50);
                const offset = clampInt(body.offset, 0, 1_000_000, 0);
                const search = (body.search ?? "").trim() || null;
                const status = (body.status ?? "").trim() || null;
                const userId = (body.user_id ?? "").trim() || null;
                const connectionSlug = (body.connection_slug ?? "").trim() || null;
                const { data, error } = await serviceClient.rpc("admin_todos_list", {
                    p_limit: limit,
                    p_offset: offset,
                    p_search: search,
                    p_status: status,
                    p_user_id: userId,
                    p_connection_slug: connectionSlug,
                });
                if (error) throw error;
                return json({ tasks: data ?? [] });
            }
            case "create_invite": {
                const note = (body.note ?? "").trim() || null;
                const maxUsesRaw = body.max_uses ?? 1;
                const maxUses = Number.isFinite(maxUsesRaw)
                    ? Math.max(1, Math.min(1000, Math.floor(maxUsesRaw)))
                    : 1;
                const expiresAt = normalizeExpiresAt(body.expires_at);

                let code = (body.code ?? "").trim().toUpperCase();
                if (!code) {
                    code = generateInviteCode();
                }
                if (code.length < 4 || code.length > 64) {
                    return json({ error: "invalid_code_length" }, 400);
                }

                const attemptInsert = async (candidate: string) =>
                    serviceClient
                        .from("invite_codes")
                        .insert({
                            code: candidate,
                            note,
                            max_uses: maxUses,
                            expires_at: expiresAt,
                        })
                        .select(
                            "code, note, max_uses, use_count, expires_at, created_at",
                        )
                        .single();

                let { data, error } = await attemptInsert(code);
                if (error && !body.code) {
                    const retryCode = generateInviteCode();
                    ({ data, error } = await attemptInsert(retryCode));
                }
                if (error) throw error;

                return json({
                    invite: {
                        ...data,
                        status: "unused",
                        redeemers: [],
                    },
                });
            }
            default:
                return json({ error: "unknown_action" }, 400);
        }
    } catch (e) {
        console.error("admin error:", e);
        return json({ error: "internal", detail: String(e) }, 500);
    }
});
