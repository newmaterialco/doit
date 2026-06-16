// Supabase Edge Function: feedback
//
// Beta user feedback from the iOS Settings sheet.
//
// Endpoints (all POST, body { action, ... }):
//   { action: "submit", message, include_email?, app_version?, ios_version?, device_model? }
//     -> { ok: true }

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const MAX_MESSAGE_LENGTH = 4000;

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
    const userEmail = userResp.user.email ?? null;

    const serviceClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    let body: {
        action?: string;
        message?: string;
        include_email?: boolean;
        contact_email?: string;
        app_version?: string;
        ios_version?: string;
        device_model?: string;
    };
    try {
        body = await req.json();
    } catch {
        return json({ error: "invalid_json" }, 400);
    }

    try {
        switch (body.action) {
            case "submit": {
                const message = (body.message ?? "").trim();
                if (!message) {
                    return json({ error: "missing_message" }, 400);
                }
                if (message.length > MAX_MESSAGE_LENGTH) {
                    return json({ error: "message_too_long" }, 400);
                }

                const includeEmail = Boolean(body.include_email);
                let contactEmail: string | null = null;
                if (includeEmail) {
                    const provided = (body.contact_email ?? "").trim();
                    const candidate = provided || (userEmail ?? "").trim();
                    if (!candidate) {
                        return json({ error: "missing_contact_email" }, 400);
                    }
                    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(candidate)) {
                        return json({ error: "invalid_contact_email" }, 400);
                    }
                    contactEmail = candidate;
                }

                const { error } = await serviceClient.from("beta_feedback").insert({
                    user_id: userId,
                    message,
                    include_email: includeEmail,
                    contact_email: contactEmail,
                    app_version: (body.app_version ?? "").trim() || null,
                    ios_version: (body.ios_version ?? "").trim() || null,
                    device_model: (body.device_model ?? "").trim() || null,
                });
                if (error) throw error;

                return json({ ok: true });
            }
            default:
                return json({ error: "unknown_action" }, 400);
        }
    } catch (e) {
        console.error("feedback error:", e);
        return json({ error: "internal", detail: String(e) }, 500);
    }
});
