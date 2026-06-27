// Supabase Edge Function: onboarding
//
// Drives the post-signup "create your agent" flow. The iOS app calls this
// with the user's JWT; all writes happen with service-role so RLS can stay
// locked down (users can only ever read their own provisioning row).
//
// Endpoints (all POST, body { action, ... }):
//   { action: "status" }
//     -> { provisioning: ProvisioningRow | null, agent_ready: boolean }
//   { action: "redeem", code: string }
//     -> { ok, reason, provisioning: ProvisioningRow | null }
//   { action: "byo_prepare" }
//     -> { connector: ConnectorRow, pairing_code, connector_token, install_command }
//   { action: "byo_status" }
//     -> { connector: ConnectorRow | null, agent_ready: boolean }
//
// `status` also backfills a `ready` provisioning row for users who were
// provisioned manually before invite codes existed, so they never see the
// onboarding screen.
//
// `redeem` is idempotent: a user who already redeemed (any status) gets
// their current row back without consuming another invite use. Atomicity
// of code validation + use-count increment lives in the
// `redeem_invite_code` Postgres function (security definer, service-role
// only).

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

interface ProvisioningRow {
    user_id: string;
    status: "pending" | "provisioning" | "ready" | "failed";
    error: string | null;
    created_at: string;
    updated_at: string;
}

interface ConnectorRow {
    user_id: string;
    status: "pairing" | "online" | "offline" | "revoked";
    profile_name: string | null;
    endpoint_url: string | null;
    capabilities: Record<string, unknown>;
    last_heartbeat_at: string | null;
    created_at: string;
    updated_at: string;
}

const PROVISIONING_COLUMNS = "user_id,status,error,created_at,updated_at";
const CONNECTOR_COLUMNS = "user_id,status,profile_name,endpoint_url,capabilities,last_heartbeat_at,created_at,updated_at";

function randomBase32(length: number): string {
    const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    const bytes = crypto.getRandomValues(new Uint8Array(length));
    let out = "";
    for (const byte of bytes) out += alphabet[byte % alphabet.length];
    return out;
}

function randomToken(): string {
    const bytes = crypto.getRandomValues(new Uint8Array(32));
    return btoa(String.fromCharCode(...bytes))
        .replaceAll("+", "-")
        .replaceAll("/", "_")
        .replaceAll("=", "");
}

async function sha256Hex(value: string): Promise<string> {
    const bytes = new TextEncoder().encode(value);
    const digest = await crypto.subtle.digest("SHA-256", bytes);
    return Array.from(new Uint8Array(digest))
        .map((b) => b.toString(16).padStart(2, "0"))
        .join("");
}

function shellQuote(value: string): string {
    return `'${value.replaceAll("'", "'\\''")}'`;
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

    const authHeader = req.headers.get("Authorization") ?? "";
    if (!authHeader.startsWith("Bearer ")) {
        return json({ error: "unauthorized" }, 401);
    }

    const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
        global: { headers: { Authorization: authHeader } },
    });
    const { data: userResp, error: userErr } = await userClient.auth.getUser();
    if (userErr || !userResp.user) {
        return json({ error: "unauthorized" }, 401);
    }
    const userId = userResp.user.id;

    const serviceClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    let body: { action?: string; code?: string };
    try {
        body = await req.json();
    } catch {
        return json({ error: "invalid_json" }, 400);
    }

    async function fetchProvisioning(): Promise<ProvisioningRow | null> {
        const { data, error } = await serviceClient
            .from("user_provisioning")
            .select(PROVISIONING_COLUMNS)
            .eq("user_id", userId)
            .maybeSingle();
        if (error) throw error;
        return data as ProvisioningRow | null;
    }

    async function agentReady(): Promise<boolean> {
        const { data, error } = await serviceClient
            .from("user_hermes")
            .select("user_id")
            .eq("user_id", userId)
            .maybeSingle();
        if (error) throw error;
        return Boolean(data);
    }

    async function fetchConnector(): Promise<ConnectorRow | null> {
        const { data, error } = await serviceClient
            .from("byo_connectors")
            .select(CONNECTOR_COLUMNS)
            .eq("user_id", userId)
            .maybeSingle();
        if (error) throw error;
        return data as ConnectorRow | null;
    }

    try {
        switch (body.action) {
            case "status": {
                const ready = await agentReady();
                let provisioning = await fetchProvisioning();

                // Manually-onboarded users (provisioned before invite codes
                // existed) have a user_hermes row but no provisioning row.
                // Backfill `ready` so the app routes them straight in.
                if (ready && !provisioning) {
                    const { data, error } = await serviceClient
                        .from("user_provisioning")
                        .upsert(
                            { user_id: userId, status: "ready" },
                            { onConflict: "user_id" },
                        )
                        .select(PROVISIONING_COLUMNS)
                        .single();
                    if (error) throw error;
                    provisioning = data as ProvisioningRow;
                }

                return json({ provisioning, agent_ready: ready });
            }
            case "redeem": {
                const code = (body.code ?? "").trim();
                if (!code) {
                    return json({ error: "missing_code" }, 400);
                }
                const { data, error } = await serviceClient.rpc(
                    "redeem_invite_code",
                    { p_code: code, p_user_id: userId },
                );
                if (error) throw error;
                const result = Array.isArray(data) ? data[0] : data;
                const ok = Boolean(result?.ok);
                const reason = String(result?.reason ?? "unknown");
                if (!ok) {
                    // Invalid/expired/exhausted code. 200 with ok:false so the
                    // app can show a friendly inline message.
                    return json({ ok: false, reason, provisioning: null });
                }
                const provisioning = await fetchProvisioning();
                return json({ ok: true, reason, provisioning });
            }
            case "byo_prepare": {
                const pairingCode = `DOIT-${randomBase32(8)}`;
                const connectorToken = `doit_conn_${randomToken()}`;
                const [pairingHash, tokenHash] = await Promise.all([
                    sha256Hex(pairingCode),
                    sha256Hex(connectorToken),
                ]);
                const { data, error } = await serviceClient
                    .from("byo_connectors")
                    .upsert(
                        {
                            user_id: userId,
                            pairing_code_hash: pairingHash,
                            connector_token_hash: tokenHash,
                            status: "pairing",
                            capabilities: {},
                            last_heartbeat_at: null,
                        },
                        { onConflict: "user_id" },
                    )
                    .select(CONNECTOR_COLUMNS)
                    .single();
                if (error) throw error;
                const installerURL =
                    "https://raw.githubusercontent.com/newmaterialco/doit/main/scripts/install-byo-connector.sh";
                const installCommand = [
                    `DOIT_SUPABASE_URL=${shellQuote(SUPABASE_URL)}`,
                    `DOIT_SUPABASE_ANON_KEY=${shellQuote(SUPABASE_ANON_KEY)}`,
                    `DOIT_CONNECTOR_TOKEN=${shellQuote(connectorToken)}`,
                    `DOIT_HERMES_URL=${shellQuote("http://127.0.0.1:8643")}`,
                    `bash -c "$(curl -fsSL ${shellQuote(installerURL)})"`,
                ].join(" ");
                return json({
                    connector: data as ConnectorRow,
                    pairing_code: pairingCode,
                    connector_token: connectorToken,
                    install_command: installCommand,
                });
            }
            case "byo_status": {
                const connector = await fetchConnector();
                return json({
                    connector,
                    agent_ready: connector?.status === "online",
                });
            }
            default:
                return json({ error: "unknown_action" }, 400);
        }
    } catch (e) {
        console.error("onboarding error:", e);
        return json({ error: "internal", detail: String(e) }, 500);
    }
});
