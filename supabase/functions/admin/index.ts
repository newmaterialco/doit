// Supabase Edge Function: admin
//
// Operator-only dashboard API. Authenticated via X-Admin-Secret header
// (ADMIN_SECRET env var). All reads/writes use service_role.
//
// Endpoints (all POST, body { action, ... }):
//   { action: "summary" }  -> admin_ops_summary()
//   { action: "metrics" }  -> admin_usage_metrics()
//   { action: "users", limit?, offset? }
//                          -> { users: [...], total_count }
//   { action: "user_options" } -> { users: [{ user_id, email }] }
//   { action: "invites", limit?, offset?, invite_status?, invite_sort?, invite_search?, invite_email_sent? }
//                          -> { invites: [...], total_count }
//   { action: "feedback", limit?, offset? }
//                          -> { feedback: [...], total_count }
//   { action: "tasks", limit?, offset?, search?, status?, connection_slug? }
//                          -> { tasks: [...] }
//   { action: "create_invite", note?, max_uses?, expires_at? }
//                          -> inserts invite_codes (auto-generates code if omitted)
//   { action: "set_invite_email_sent", code, email_sent }
//                          -> updates invite_codes.email_sent
//   { action: "delete_invite", code }
//                          -> deletes unused invite_codes row
//   { action: "premium_model_users" }
//                          -> { users: [{ user_id, email, note, created_at }] }
//   { action: "grant_premium_models", user_id, note? }
//                          -> grants premium model access
//   { action: "revoke_premium_models", user_id }
//                          -> revokes premium model access
//   { action: "issues", limit?, offset?, kind? }
//                          -> { issues: [...], total_count, summary }

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
        invite_status?: string;
        invite_sort?: string;
        invite_search?: string;
        invite_email_sent?: string;
        email_sent?: boolean;
        kind?: string;
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
            case "metrics": {
                const { data, error } = await serviceClient.rpc("admin_usage_metrics");
                if (error) throw error;
                return json(data ?? {});
            }
            case "users": {
                const limit = clampInt(body.limit, 1, 100, 50);
                const offset = clampInt(body.offset, 0, 1_000_000, 0);
                const { data, error } = await serviceClient.rpc("admin_users_list", {
                    p_limit: limit,
                    p_offset: offset,
                });
                if (error) throw error;
                const rows = data ?? [];
                const totalCount = rows.length > 0
                    ? Number((rows[0] as Record<string, unknown>).total_count ?? 0)
                    : 0;
                const users = rows.map((row: Record<string, unknown>) => {
                    const { total_count: _tc, ...user } = row;
                    return user;
                });
                const userIds = users
                    .map((user) => String(user.user_id ?? ""))
                    .filter(Boolean);
                const premiumUserIds = new Set<string>();
                if (userIds.length > 0) {
                    const { data: premiumRows, error: premiumErr } = await serviceClient
                        .from("premium_model_users")
                        .select("user_id")
                        .in("user_id", userIds);
                    if (premiumErr) throw premiumErr;
                    for (const row of premiumRows ?? []) {
                        premiumUserIds.add(String(row.user_id));
                    }
                }
                const usersWithPremiumAccess = users.map((user) => ({
                    ...user,
                    premium_model_access: premiumUserIds.has(String(user.user_id ?? "")),
                }));
                return json({ users: usersWithPremiumAccess, total_count: totalCount });
            }
            case "user_options": {
                const { data, error } = await serviceClient.rpc("admin_user_options");
                if (error) throw error;
                return json({ users: data ?? [] });
            }
            case "invites": {
                const limit = clampInt(body.limit, 1, 100, 50);
                const offset = clampInt(body.offset, 0, 1_000_000, 0);
                const status = (body.invite_status ?? "").trim() || null;
                const sort = (body.invite_sort ?? "").trim() || null;
                const search = (body.invite_search ?? "").trim() || null;
                const emailSent = (body.invite_email_sent ?? "").trim() || null;
                const { data, error } = await serviceClient.rpc("admin_invite_codes_list", {
                    p_limit: limit,
                    p_offset: offset,
                    p_status: status,
                    p_sort: sort,
                    p_search: search,
                    p_email_sent: emailSent,
                });
                if (error) throw error;
                const rows = data ?? [];
                const totalCount = rows.length > 0
                    ? Number((rows[0] as Record<string, unknown>).total_count ?? 0)
                    : 0;
                const invites = rows.map((row: Record<string, unknown>) => {
                    const { total_count: _tc, ...invite } = row;
                    return invite;
                });
                return json({ invites, total_count: totalCount });
            }
            case "feedback": {
                const limit = clampInt(body.limit, 1, 100, 50);
                const offset = clampInt(body.offset, 0, 1_000_000, 0);
                const { data, error } = await serviceClient.rpc("admin_feedback_list", {
                    p_limit: limit,
                    p_offset: offset,
                });
                if (error) throw error;
                const rows = data ?? [];
                const totalCount = rows.length > 0
                    ? Number((rows[0] as Record<string, unknown>).total_count ?? 0)
                    : 0;
                const feedback = rows.map((row: Record<string, unknown>) => {
                    const { total_count: _tc, ...item } = row;
                    return item;
                });
                return json({ feedback, total_count: totalCount });
            }
            case "tasks": {
                const limit = clampInt(body.limit, 1, 100, 50);
                const offset = clampInt(body.offset, 0, 1_000_000, 0);
                const search = (body.search ?? "").trim() || null;
                const status = (body.status ?? "").trim() || null;
                const connectionSlug = (body.connection_slug ?? "").trim() || null;
                const { data, error } = await serviceClient.rpc("admin_todos_list", {
                    p_limit: limit,
                    p_offset: offset,
                    p_search: search,
                    p_status: status,
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
                        email_sent: false,
                    },
                });
            }
            case "set_invite_email_sent": {
                const code = (body.code ?? "").trim().toUpperCase();
                if (!code) {
                    return json({ error: "code_required" }, 400);
                }
                const emailSent = body.email_sent === true;
                const { data, error } = await serviceClient
                    .from("invite_codes")
                    .update({ email_sent: emailSent })
                    .eq("code", code)
                    .select("code, email_sent")
                    .single();
                if (error) throw error;
                return json({ invite: data });
            }
            case "premium_model_users": {
                const [premiumResp, usersResp] = await Promise.all([
                    serviceClient
                        .from("premium_model_users")
                        .select("user_id,note,created_at")
                        .order("created_at", { ascending: false }),
                    serviceClient.rpc("admin_user_options"),
                ]);
                if (premiumResp.error) throw premiumResp.error;
                if (usersResp.error) throw usersResp.error;

                const emailsByUserId = new Map(
                    (usersResp.data ?? []).map((user: Record<string, unknown>) => [
                        String(user.user_id),
                        user.email ?? null,
                    ]),
                );
                const users = (premiumResp.data ?? []).map((row) => ({
                    ...row,
                    email: emailsByUserId.get(String(row.user_id)) ?? null,
                }));
                return json({ users });
            }
            case "grant_premium_models": {
                const userId = (body.user_id ?? "").trim();
                if (!userId) {
                    return json({ error: "user_id_required" }, 400);
                }
                const note = (body.note ?? "").trim() || null;
                const { data, error } = await serviceClient
                    .from("premium_model_users")
                    .upsert({ user_id: userId, note }, { onConflict: "user_id" })
                    .select("user_id,note,created_at")
                    .single();
                if (error) throw error;
                return json({ user: data });
            }
            case "revoke_premium_models": {
                const userId = (body.user_id ?? "").trim();
                if (!userId) {
                    return json({ error: "user_id_required" }, 400);
                }
                const { error } = await serviceClient
                    .from("premium_model_users")
                    .delete()
                    .eq("user_id", userId);
                if (error) throw error;
                return json({ ok: true, user_id: userId });
            }
            case "delete_invite": {
                const code = (body.code ?? "").trim().toUpperCase();
                if (!code) {
                    return json({ error: "code_required" }, 400);
                }
                const { data: invite, error: fetchErr } = await serviceClient
                    .from("invite_codes")
                    .select("code, use_count")
                    .eq("code", code)
                    .maybeSingle();
                if (fetchErr) throw fetchErr;
                if (!invite) {
                    return json({ error: "not_found" }, 404);
                }
                if ((invite.use_count ?? 0) > 0) {
                    return json({ error: "invite_in_use" }, 400);
                }
                const { data: redeemer, error: redeemerErr } = await serviceClient
                    .from("user_provisioning")
                    .select("user_id")
                    .eq("invite_code", code)
                    .limit(1)
                    .maybeSingle();
                if (redeemerErr) throw redeemerErr;
                if (redeemer) {
                    return json({ error: "invite_in_use" }, 400);
                }
                const { error: deleteErr } = await serviceClient
                    .from("invite_codes")
                    .delete()
                    .eq("code", code);
                if (deleteErr) throw deleteErr;
                return json({ ok: true, code });
            }
            case "issues": {
                const limit = clampInt(body.limit, 1, 100, 50);
                const offset = clampInt(body.offset, 0, 1_000_000, 0);
                const kind = (body.kind ?? "").trim() || null;
                const [listResp, summaryResp] = await Promise.all([
                    serviceClient.rpc("admin_issues_list", {
                        p_limit: limit,
                        p_offset: offset,
                        p_kind: kind,
                    }),
                    serviceClient.rpc("admin_issues_summary"),
                ]);
                if (listResp.error) throw listResp.error;
                if (summaryResp.error) throw summaryResp.error;
                const rows = listResp.data ?? [];
                const totalCount = rows.length > 0
                    ? Number((rows[0] as Record<string, unknown>).total_count ?? 0)
                    : 0;
                const issues = rows.map((row: Record<string, unknown>) => {
                    const { total_count: _tc, ...issue } = row;
                    return issue;
                });
                return json({
                    issues,
                    total_count: totalCount,
                    summary: summaryResp.data ?? {},
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
