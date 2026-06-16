// Supabase Edge Function: agent-settings
//
// Owns the app-facing model catalog and stores per-user Hermes model choices.
//
// Endpoints (all POST, body { action, ... }):
//   { action: "get" }
//     -> { catalog, setting? }
//   { action: "update", provider, model }
//     -> { setting }

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

type ProviderId = "openai" | "anthropic" | "openrouter";

interface ModelOption {
    id: string;
    name: string;
    label: string;
    description: string;
    locked?: boolean;
}

interface ProviderOption {
    id: ProviderId;
    name: string;
    models: ModelOption[];
}

const CATALOG: ProviderOption[] = [
    {
        id: "openrouter",
        name: "OpenRouter",
        models: [
            {
                id: "google/gemini-3.1-flash-lite",
                name: "Gemini 3.1 Flash Lite",
                label: "Daily Driver",
                description: "Fast, low-cost default for everyday Hermes agent tasks.",
            },
            {
                id: "google/gemini-2.5-flash",
                name: "Gemini 2.5 Flash",
                label: "Daily Driver+",
                description: "Slightly heavier daily-driver option when a task needs more headroom.",
            },
            {
                id: "deepseek/deepseek-v3.2",
                name: "DeepSeek V3.2",
                label: "Budget Agent",
                description: "Very low-cost agent model with long context and tool/structured output support.",
            },
            {
                id: "qwen/qwen3-coder-flash",
                name: "Qwen3 Coder Flash",
                label: "Budget Coding",
                description: "Cost-efficient coding and tool-use model with a very large context window.",
            },
            {
                id: "moonshotai/kimi-k2.5",
                name: "Kimi K2.5",
                label: "Efficient",
                description: "Kimi option for agentic tool use and multimodal reasoning at moderate cost.",
            },
            {
                id: "moonshotai/kimi-k2-thinking",
                name: "Kimi K2 Thinking",
                label: "Strong Reasoning",
                description: "Stronger Kimi reasoning model for harder multi-step agent tasks.",
            },
            {
                id: "anthropic/claude-sonnet-4",
                name: "Claude Sonnet 4",
                label: "Balanced",
                description: "Strong quality/cost balance for agent work.",
            },
            {
                id: "openai/gpt-4.1",
                name: "GPT-4.1",
                label: "Strong",
                description: "Higher quality OpenAI option for harder agent tasks.",
            },
            {
                id: "anthropic/claude-sonnet-4-6",
                name: "Claude Sonnet 4.6",
                label: "Balanced+",
                description: "Latest Sonnet with stronger reasoning for complex agent work.",
                locked: true,
            },
            {
                id: "anthropic/claude-opus-4",
                name: "Claude Opus 4",
                label: "Premium",
                description: "Most capable Claude option; use when quality matters more than cost.",
                locked: true,
            },
            {
                id: "openai/gpt-5.4",
                name: "GPT-5.4",
                label: "Strong+",
                description: "Strong OpenAI option for agents and professional work.",
                locked: true,
            },
            {
                id: "openai/gpt-5.5",
                name: "GPT-5.5",
                label: "Premium",
                description: "Most capable OpenAI option for professional agent work.",
                locked: true,
            },
        ],
    },
];

const DEFAULT_SELECTION = {
    provider: "openrouter" as ProviderId,
    model: "google/gemini-2.5-flash",
};

interface AgentModelSetting {
    user_id: string;
    provider: ProviderId;
    model: string;
    apply_status: "pending" | "applied" | "failed";
    apply_error: string | null;
    last_applied_at: string | null;
    updated_at: string;
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

function providerFor(id: string | undefined): ProviderOption | undefined {
    return CATALOG.find((p) => p.id === id);
}

function modelEntry(
    provider: ProviderOption,
    model: string | undefined,
): ModelOption | undefined {
    if (!model) return undefined;
    return provider.models.find((m) => m.id === model);
}

function modelIsSupported(provider: ProviderOption, model: string | undefined): boolean {
    return Boolean(modelEntry(provider, model));
}

function modelIsSelectable(provider: ProviderOption, model: string | undefined): boolean {
    const entry = modelEntry(provider, model);
    return Boolean(entry && !entry.locked);
}

function sanitizeSetting(row: AgentModelSetting | null): AgentModelSetting | null {
    if (!row) return null;
    return {
        user_id: row.user_id,
        provider: row.provider,
        model: row.model,
        apply_status: row.apply_status,
        apply_error: row.apply_error,
        last_applied_at: row.last_applied_at,
        updated_at: row.updated_at,
    };
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

    let body: {
        action?: string;
        provider?: string;
        model?: string;
    };
    try {
        body = await req.json();
    } catch {
        return json({ error: "invalid_json" }, 400);
    }

    try {
        switch (body.action) {
            case "get": {
                const { data, error } = await serviceClient
                    .from("agent_model_settings")
                    .select("user_id,provider,model,apply_status,apply_error,last_applied_at,updated_at")
                    .eq("user_id", userId)
                    .maybeSingle();
                if (error) throw error;
                return json({
                    catalog: CATALOG,
                    setting: sanitizeSetting(data),
                    default_selection: DEFAULT_SELECTION,
                });
            }
            case "update": {
                const provider = providerFor(body.provider);
                if (!provider) {
                    return json({ error: "unsupported_provider" }, 400);
                }
                if (!modelIsSupported(provider, body.model)) {
                    return json({ error: "unsupported_model" }, 400);
                }
                if (!modelIsSelectable(provider, body.model)) {
                    return json({ error: "model_locked" }, 403);
                }

                const { data, error } = await serviceClient
                    .from("agent_model_settings")
                    .upsert({
                        user_id: userId,
                        provider: provider.id,
                        model: body.model,
                        apply_status: "pending",
                        apply_error: null,
                    })
                    .select("user_id,provider,model,apply_status,apply_error,last_applied_at,updated_at")
                    .single();
                if (error) throw error;

                return json({ setting: sanitizeSetting(data) });
            }
            default:
                return json({ error: "unknown_action" }, 400);
        }
    } catch (e) {
        console.error("agent-settings error:", e);
        return json({ error: "internal", detail: String(e) }, 500);
    }
});
