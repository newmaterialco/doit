// Supabase Edge Function: task-suggestions
//
// Generates ephemeral, inspirational task suggestions for the iOS homescreen.
// The iOS app authenticates with its Supabase JWT; this function reads recent
// user todos server-side and calls OpenAI with OPENAI_API_KEY.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY") ?? "";
const OPENAI_SUGGESTIONS_MODEL = Deno.env.get("OPENAI_SUGGESTIONS_MODEL") ??
    "gpt-5.4-mini";

const MAX_COUNT = 5;
const MAX_EXCLUDED_TITLES = 80;
const MAX_CONTEXT_TODOS = 40;

interface SuggestionRequest {
    count?: number;
    exclude_titles?: string[];
}

interface TodoContextRow {
    title: string;
    original_title: string | null;
    status: string;
    connection_slug: string | null;
    preparation_summary: string | null;
    created_at: string;
    updated_at: string;
}

interface TaskSuggestion {
    title: string;
    theme: string;
    connection_slug?: string | null;
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

function clampCount(value: unknown): number {
    if (typeof value !== "number" || !Number.isFinite(value)) return MAX_COUNT;
    return Math.max(1, Math.min(MAX_COUNT, Math.floor(value)));
}

function cleanString(value: unknown, maxLength: number): string {
    if (typeof value !== "string") return "";
    return value.replace(/\s+/g, " ").trim().slice(0, maxLength);
}

function cleanTheme(value: unknown): string {
    const cleaned = cleanString(value, 24).replace(/[^a-zA-Z -]/g, "").trim();
    const firstWord = cleaned.split(/\s+/)[0] ?? "";
    return firstWord.length > 0 ? firstWord : "Idea";
}

function normalizeTitle(title: string): string {
    return title.toLowerCase().replace(/\s+/g, " ").trim();
}

function sanitizeSuggestion(
    raw: unknown,
    excluded: Set<string>,
): TaskSuggestion | null {
    if (!raw || typeof raw !== "object") return null;
    const record = raw as Record<string, unknown>;
    const title = cleanString(record.title, 140);
    if (!title || excluded.has(normalizeTitle(title))) return null;

    return {
        title,
        theme: cleanTheme(record.theme),
        connection_slug: cleanString(record.connection_slug, 40) || null,
    };
}

function fallbackSuggestions(count: number, excluded: Set<string>): TaskSuggestion[] {
    const starters: TaskSuggestion[] = [
        { title: "Draft a reply to an email I have been putting off", theme: "Email", connection_slug: "gmail" },
        { title: "Plan my week around the most important tasks", theme: "Plan", connection_slug: "googlecalendar" },
        { title: "Research options for a decision I need to make", theme: "Research", connection_slug: null },
        { title: "Create a reminder for something I keep forgetting", theme: "Remind", connection_slug: null },
        { title: "Turn messy notes into a clear action plan", theme: "Write", connection_slug: "googledocs" },
        { title: "Find and summarize a document from my workspace", theme: "Docs", connection_slug: "googledrive" },
        { title: "Prepare a short status update I can send", theme: "Update", connection_slug: "slack" },
        { title: "Organize follow-ups from recent conversations", theme: "Follow-up", connection_slug: "gmail" },
    ];
    return starters
        .filter((s) => !excluded.has(normalizeTitle(s.title)))
        .slice(0, count);
}

function buildPrompt(
    count: number,
    todos: TodoContextRow[],
    excludedTitles: string[],
): Array<{ role: "system" | "user"; content: string }> {
    const completed = todos.filter((todo) => todo.status === "done");
    const active = todos.filter((todo) => todo.status !== "done");
    const hasHistory = todos.length > 0;

    const compactTodos = todos.map((todo) => ({
        title: todo.original_title || todo.title,
        prepared_title: todo.title,
        status: todo.status,
        connection_slug: todo.connection_slug,
        summary: todo.preparation_summary,
        updated_at: todo.updated_at,
    }));

    const contextLabel = completed.length > 0
        ? "completed and recent task history"
        : active.length > 0
        ? "recent in-progress task history only"
        : "no prior task history";

    return [
        {
            role: "system",
            content:
                "You create inspiring, useful task suggestions for doit, a personal AI agent app. " +
                "Your suggestions should drive usage by helping the user imagine helpful next actions. " +
                "Infer adjacent workflows, smart follow-ups, automations, reminders, drafts, research, " +
                "cleanup tasks, planning, and organization opportunities. Do not execute anything. " +
                "Avoid destructive or risky actions. Return only valid JSON.",
        },
        {
            role: "user",
            content: JSON.stringify({
                instruction:
                    `Generate ${count} concise suggested tasks. They should be actionable card titles ` +
                    "the user could tap to create a new doit task. They do not need to be 1:1 repeats; " +
                    "they should feel similar, adjacent, or helpful based on the user's work patterns.",
                context_label: contextLabel,
                cold_start_rules: hasHistory
                    ? null
                    : [
                        "There is no task history. Showcase what doit can do.",
                        "Use concrete but fill-in-friendly starter tasks.",
                        "Cover email, planning, research, reminders, writing, and organization.",
                    ],
                output_schema: {
                    suggestions: [
                        {
                            title: "string, <= 110 chars, actionable and specific enough to inspire",
                            theme: "one word, e.g. Email, Plan, Research, Remind, Write",
                            connection_slug: "optional known toolkit slug or null",
                        },
                    ],
                },
                constraints: [
                    "Return exactly the requested number if possible.",
                    "Do not repeat excluded_titles.",
                    "Do not include markdown.",
                    "Do not use ellipses unless it is intentionally fill-in-friendly for cold start.",
                    "Prefer helpful, adjacent next actions over generic templates.",
                ],
                excluded_titles: excludedTitles,
                recent_todos: compactTodos,
            }),
        },
    ];
}

async function generateSuggestions(
    count: number,
    todos: TodoContextRow[],
    excludedTitles: string[],
): Promise<TaskSuggestion[]> {
    if (!OPENAI_API_KEY) {
        throw new Error("openai_not_configured");
    }

    const res = await fetch("https://api.openai.com/v1/chat/completions", {
        method: "POST",
        headers: {
            Authorization: `Bearer ${OPENAI_API_KEY}`,
            "Content-Type": "application/json",
        },
        body: JSON.stringify({
            model: OPENAI_SUGGESTIONS_MODEL,
            messages: buildPrompt(count, todos, excludedTitles),
            response_format: { type: "json_object" },
        }),
    });

    if (!res.ok) {
        throw new Error(`openai_error:${res.status}:${await res.text()}`);
    }

    const data = await res.json();
    const content = data?.choices?.[0]?.message?.content;
    if (typeof content !== "string") {
        throw new Error("openai_bad_response");
    }

    const parsed = JSON.parse(content);
    const rawSuggestions = Array.isArray(parsed?.suggestions) ? parsed.suggestions : [];
    const excluded = new Set(excludedTitles.map(normalizeTitle));
    const suggestions: TaskSuggestion[] = [];
    for (const raw of rawSuggestions) {
        const suggestion = sanitizeSuggestion(raw, excluded);
        if (!suggestion) continue;
        excluded.add(normalizeTitle(suggestion.title));
        suggestions.push(suggestion);
        if (suggestions.length >= count) break;
    }
    return suggestions;
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

    let body: SuggestionRequest;
    try {
        body = await req.json();
    } catch {
        return json({ error: "invalid_json" }, 400);
    }

    const count = clampCount(body.count);
    const excludedTitles = (Array.isArray(body.exclude_titles) ? body.exclude_titles : [])
        .map((title) => cleanString(title, 160))
        .filter(Boolean)
        .slice(0, MAX_EXCLUDED_TITLES);

    const serviceClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    const { data, error } = await serviceClient
        .from("todos")
        .select("title,original_title,status,connection_slug,preparation_summary,created_at,updated_at")
        .eq("user_id", userResp.user.id)
        .order("updated_at", { ascending: false })
        .limit(MAX_CONTEXT_TODOS);

    if (error) {
        console.error("task-suggestions todo fetch error:", error);
        return json({ error: "todo_context_failed", detail: String(error.message ?? error) }, 500);
    }

    const excluded = new Set(excludedTitles.map(normalizeTitle));
    try {
        const generated = await generateSuggestions(
            count,
            (data ?? []) as TodoContextRow[],
            excludedTitles,
        );
        const fallback = generated.length < count
            ? fallbackSuggestions(count - generated.length, new Set([
                ...excluded,
                ...generated.map((s) => normalizeTitle(s.title)),
            ]))
            : [];
        return json({ suggestions: [...generated, ...fallback].slice(0, count) });
    } catch (err) {
        console.error("task-suggestions generation error:", err);
        return json({
            suggestions: fallbackSuggestions(count, excluded),
            degraded: true,
            error: String(err),
        });
    }
});
