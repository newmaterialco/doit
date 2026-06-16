// Supabase Edge Function: cron-suggestions
//
// Generates ephemeral recurring-automation suggestions for the iOS Scheduled tab.
// Mirrors task-suggestions but focuses on cron-style prompts (digests, monitors, etc.).

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
const MAX_FETCH_TODOS = 60;
const MAX_FETCH_CRON_JOBS = 30;
const MAX_RECENT_ACTIVITY = 3;
const MAX_HISTORICAL_ACTIVITY = 6;
const MAX_MEMORIES = 10;
const TITLE_OVERLAP_THRESHOLD = 0.72;

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
    topic: string | null;
    collection_name: string | null;
    created_at: string;
    updated_at: string;
    completed_at: string | null;
}

interface CronContextRow {
    name: string;
    prompt: string;
    schedule_display: string | null;
    connection_slug: string | null;
    state: string;
    last_status: string | null;
}

interface MemoryRow {
    title: string;
    body: string;
}

interface TaskSuggestion {
    title: string;
    theme: string;
    connection_slug?: string | null;
}

interface ActivitySummary {
    theme: string;
    integration: string | null;
    summary: string;
    completed: boolean;
    topic: string | null;
    collection: string | null;
}

interface CronJobSummary {
    name: string;
    schedule: string | null;
    integration: string | null;
    state: string;
    prompt_summary: string;
}

interface WorkProfile {
    top_integrations: Array<{ slug: string | null; count: number }>;
    top_topics: Array<{ topic: string; count: number }>;
    collections: string[];
    completed_last_7d: number;
    total_tasks: number;
    completed_count: number;
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
    return firstWord.length > 0 ? firstWord : "Digest";
}

function normalizeTitle(title: string): string {
    return title.toLowerCase().replace(/[^\w\s]/g, " ").replace(/\s+/g, " ").trim();
}

function titleTokens(title: string): Set<string> {
    return new Set(
        normalizeTitle(title)
            .split(" ")
            .filter((token) => token.length > 2),
    );
}

function titleOverlap(a: string, b: string): number {
    const tokensA = titleTokens(a);
    const tokensB = titleTokens(b);
    if (tokensA.size === 0 || tokensB.size === 0) return 0;
    let shared = 0;
    for (const token of tokensA) {
        if (tokensB.has(token)) shared++;
    }
    return shared / Math.max(tokensA.size, tokensB.size);
}

function buildHistoricalTitles(todos: TodoContextRow[]): Set<string> {
    const titles = new Set<string>();
    for (const todo of todos) {
        const prepared = cleanString(todo.title, 160);
        const original = cleanString(todo.original_title, 160);
        if (prepared) titles.add(normalizeTitle(prepared));
        if (original) titles.add(normalizeTitle(original));
    }
    return titles;
}

function buildCronHistoricalTitles(cronJobs: CronContextRow[]): Set<string> {
    const titles = new Set<string>();
    for (const job of cronJobs) {
        const name = cleanString(job.name, 160);
        const prompt = cleanString(job.prompt, 160);
        if (name) titles.add(normalizeTitle(name));
        if (prompt) titles.add(normalizeTitle(prompt));
    }
    return titles;
}

function buildForbiddenTitles(
    todos: TodoContextRow[],
    cronJobs: CronContextRow[],
): string[] {
    return [
        ...buildHistoricalTitles(todos),
        ...buildCronHistoricalTitles(cronJobs),
    ];
}

function isTooSimilarToHistory(
    title: string,
    historicalTitles: Set<string>,
): boolean {
    const normalized = normalizeTitle(title);
    if (!normalized) return true;
    if (historicalTitles.has(normalized)) return true;

    for (const historical of historicalTitles) {
        if (titleOverlap(normalized, historical) >= TITLE_OVERLAP_THRESHOLD) {
            return true;
        }
        if (
            normalized.includes(historical) ||
            historical.includes(normalized)
        ) {
            const shorter = Math.min(normalized.length, historical.length);
            const longer = Math.max(normalized.length, historical.length);
            if (shorter >= 12 && shorter / longer >= 0.65) return true;
        }
    }
    return false;
}

function themeForTodo(todo: TodoContextRow): string {
    switch (todo.connection_slug) {
        case "gmail":
            return "Email";
        case "googlecalendar":
            return "Plan";
        case "googlesheets":
            return "Sheets";
        case "slack":
            return "Update";
        case "googledocs":
            return "Write";
        case "googledrive":
            return "Docs";
        default:
            return todo.status === "done" ? "Follow-up" : "Idea";
    }
}

function summarizeTodo(todo: TodoContextRow): string {
    const summary = cleanString(todo.preparation_summary, 120);
    if (summary) return summary;
    return cleanString(todo.title, 110);
}

function summarizeCronJob(job: CronContextRow): string {
    return cleanString(job.prompt, 110) || cleanString(job.name, 110);
}

function compactActivity(todo: TodoContextRow): ActivitySummary {
    return {
        theme: themeForTodo(todo),
        integration: todo.connection_slug,
        summary: summarizeTodo(todo),
        completed: todo.status === "done",
        topic: cleanString(todo.topic, 40) || null,
        collection: cleanString(todo.collection_name, 60) || null,
    };
}

function compactCronJob(job: CronContextRow): CronJobSummary {
    return {
        name: cleanString(job.name, 80),
        schedule: cleanString(job.schedule_display, 60) || null,
        integration: job.connection_slug,
        state: cleanString(job.state, 24),
        prompt_summary: summarizeCronJob(job),
    };
}

function buildWorkProfile(allTodos: TodoContextRow[]): WorkProfile {
    const slugCounts = new Map<string | null, number>();
    const topicCounts = new Map<string, number>();
    const collections = new Set<string>();
    const sevenDaysAgo = Date.now() - 7 * 24 * 60 * 60 * 1000;
    let completedLast7d = 0;

    for (const todo of allTodos) {
        const slug = todo.connection_slug;
        slugCounts.set(slug, (slugCounts.get(slug) ?? 0) + 1);

        const topic = cleanString(todo.topic, 40);
        if (topic) topicCounts.set(topic, (topicCounts.get(topic) ?? 0) + 1);

        const collection = cleanString(todo.collection_name, 60);
        if (collection) collections.add(collection);

        if (todo.status === "done") {
            const completedAt = todo.completed_at ?? todo.updated_at;
            if (new Date(completedAt).getTime() >= sevenDaysAgo) {
                completedLast7d++;
            }
        }
    }

    return {
        top_integrations: [...slugCounts.entries()]
            .sort((a, b) => b[1] - a[1])
            .slice(0, 6)
            .map(([slug, count]) => ({ slug, count })),
        top_topics: [...topicCounts.entries()]
            .sort((a, b) => b[1] - a[1])
            .slice(0, 6)
            .map(([topic, count]) => ({ topic, count })),
        collections: [...collections].slice(0, 8),
        completed_last_7d: completedLast7d,
        total_tasks: allTodos.length,
        completed_count: allTodos.filter((todo) => todo.status === "done").length,
    };
}

function selectActivitySummaries(allTodos: TodoContextRow[]): ActivitySummary[] {
    const recentRaw = allTodos.slice(0, MAX_RECENT_ACTIVITY);
    const recentSummaries = new Set(
        recentRaw.map((todo) => normalizeTitle(summarizeTodo(todo))),
    );
    const historical: TodoContextRow[] = [];
    const seenSummaries = new Set<string>(recentSummaries);

    const bySlug = new Map<string, TodoContextRow[]>();
    for (const todo of allTodos) {
        const slug = todo.connection_slug || "general";
        if (!bySlug.has(slug)) bySlug.set(slug, []);
        bySlug.get(slug)!.push(todo);
    }

    const slugOrder = [...bySlug.entries()].sort((a, b) => b[1].length - a[1].length);
    for (const [, bucket] of slugOrder) {
        if (historical.length >= MAX_HISTORICAL_ACTIVITY) break;

        const candidates = [...bucket]
            .filter((todo) => !recentRaw.includes(todo))
            .sort((a, b) => {
                const aDone = a.status === "done" ? 0 : 1;
                const bDone = b.status === "done" ? 0 : 1;
                if (aDone !== bDone) return aDone - bDone;
                return new Date(b.updated_at).getTime() - new Date(b.updated_at).getTime();
            });

        let picked = 0;
        for (const candidate of candidates) {
            if (picked >= 2) break;
            const key = normalizeTitle(summarizeTodo(candidate));
            if (seenSummaries.has(key)) continue;
            historical.push(candidate);
            seenSummaries.add(key);
            picked++;
        }
    }

    return [
        ...recentRaw.map(compactActivity),
        ...historical.map(compactActivity),
    ].slice(0, MAX_RECENT_ACTIVITY + MAX_HISTORICAL_ACTIVITY);
}

function sanitizeSuggestion(
    raw: unknown,
    excluded: Set<string>,
    historicalTitles: Set<string>,
): TaskSuggestion | null {
    if (!raw || typeof raw !== "object") return null;
    const record = raw as Record<string, unknown>;
    const title = cleanString(record.title, 140);
    if (!title) return null;

    const normalized = normalizeTitle(title);
    if (excluded.has(normalized)) return null;
    if (isTooSimilarToHistory(title, historicalTitles)) return null;

    return {
        title,
        theme: cleanTheme(record.theme),
        connection_slug: cleanString(record.connection_slug, 40) || null,
    };
}

function fallbackSuggestions(count: number, excluded: Set<string>): TaskSuggestion[] {
    const starters: TaskSuggestion[] = [
        {
            title: "Every weekday morning, make me a short plan for the day",
            theme: "Plan",
            connection_slug: "googlecalendar",
        },
        {
            title: "Monitor my inbox every day for important follow-ups",
            theme: "Monitor",
            connection_slug: "gmail",
        },
        {
            title: "Every Friday, summarize what I got done this week",
            theme: "Recap",
            connection_slug: null,
        },
        {
            title: "Check every day whether ",
            theme: "Check",
            connection_slug: null,
        },
        {
            title: "Every Monday, review my calendar and flag conflicts",
            theme: "Plan",
            connection_slug: "googlecalendar",
        },
        {
            title: "Weekly digest of unread emails that need a reply",
            theme: "Digest",
            connection_slug: "gmail",
        },
        {
            title: "Every evening, summarize Slack threads I missed",
            theme: "Update",
            connection_slug: "slack",
        },
        {
            title: "Monthly recap of completed tasks and open follow-ups",
            theme: "Recap",
            connection_slug: null,
        },
    ];
    return starters
        .filter((s) => !excluded.has(normalizeTitle(s.title)))
        .slice(0, count);
}

function buildPrompt(
    count: number,
    todos: TodoContextRow[],
    cronJobs: CronContextRow[],
    excludedTitles: string[],
    memories: MemoryRow[],
    forbiddenTitles: string[],
): Array<{ role: "system" | "user"; content: string }> {
    const hasTodoHistory = todos.length > 0;
    const hasCronHistory = cronJobs.length > 0;
    const workProfile = hasTodoHistory ? buildWorkProfile(todos) : null;
    const recentActivity = hasTodoHistory ? selectActivitySummaries(todos) : [];
    const existingCronJobs = cronJobs.slice(0, 12).map(compactCronJob);

    return [
        {
            role: "system",
            content:
                "You suggest recurring automations a doit user would schedule with their personal AI agent. " +
                "Each suggestion must be a schedulable prompt with explicit recurrence (Every weekday, Daily, Weekly, Every Friday, Monthly, etc.). " +
                "Focus on digests, monitors, check-ins, recurring prep, and automated follow-ups — not one-off tasks. " +
                "Base suggestions on work_profile, recent_activity, user_memories, and existing_cron_jobs. " +
                "Never repeat or lightly rephrase existing cron jobs or forbidden titles. " +
                "Do not execute anything. Avoid destructive or risky actions. Return only valid JSON.",
        },
        {
            role: "user",
            content: JSON.stringify({
                instruction:
                    `Generate ${count} concise suggested recurring automations as card titles. ` +
                    "Each title must read like a prompt the user would schedule to repeat automatically.",
                cold_start_rules: hasTodoHistory || hasCronHistory
                    ? null
                    : [
                        "There is no task or schedule history. Showcase recurring automations doit can run.",
                        "Use concrete recurrence language: Every weekday, Daily, Weekly, Every Friday, etc.",
                        "Cover digests, inbox monitoring, planning, check-ins, and recaps.",
                    ],
                personalization_rules: hasTodoHistory || hasCronHistory
                    ? [
                        "Infer recurring workflows from work_profile, recent_activity, and existing_cron_jobs.",
                        "Never repeat or lightly rephrase any forbidden_title or existing cron job.",
                        "Suggest adjacent recurring workflows: weekly digests, daily monitors, weekday prep, monthly recaps.",
                        "Use at least 3 distinct theme values when count >= 3.",
                        "Example: if they often email vendors, suggest a weekly follow-up digest — not the same one-off email task.",
                    ]
                    : null,
                output_schema: {
                    suggestions: [
                        {
                            title: "string, <= 110 chars, recurring prompt with explicit schedule language",
                            theme: "one word, e.g. Digest, Monitor, Plan, Recap, Watch, Check",
                            connection_slug: "optional known toolkit slug or null",
                        },
                    ],
                },
                constraints: [
                    "Return exactly the requested number if possible.",
                    "Every title must imply recurrence (Daily, Weekly, Every weekday, etc.).",
                    "Do not repeat excluded_titles or forbidden_titles.",
                    "Do not include markdown.",
                    "Do not use ellipses unless intentionally fill-in-friendly for cold start.",
                ],
                excluded_titles: excludedTitles,
                forbidden_titles: forbiddenTitles.slice(0, MAX_EXCLUDED_TITLES),
                work_profile: workProfile,
                recent_activity: hasTodoHistory ? recentActivity : null,
                existing_cron_jobs: hasCronHistory ? existingCronJobs : null,
                user_memories: memories.length > 0
                    ? memories.map((m) => ({
                        title: m.title,
                        body: m.body,
                    }))
                    : null,
            }),
        },
    ];
}

async function callOpenAI(
    count: number,
    todos: TodoContextRow[],
    cronJobs: CronContextRow[],
    excludedTitles: string[],
    memories: MemoryRow[],
    forbiddenTitles: string[],
): Promise<TaskSuggestion[]> {
    const res = await fetch("https://api.openai.com/v1/chat/completions", {
        method: "POST",
        headers: {
            Authorization: `Bearer ${OPENAI_API_KEY}`,
            "Content-Type": "application/json",
        },
        body: JSON.stringify({
            model: OPENAI_SUGGESTIONS_MODEL,
            messages: buildPrompt(
                count,
                todos,
                cronJobs,
                excludedTitles,
                memories,
                forbiddenTitles,
            ),
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
    const historicalTitles = new Set([
        ...buildHistoricalTitles(todos),
        ...buildCronHistoricalTitles(cronJobs),
    ]);
    const excluded = new Set([
        ...excludedTitles.map(normalizeTitle),
        ...forbiddenTitles.map(normalizeTitle),
    ]);
    const suggestions: TaskSuggestion[] = [];

    for (const raw of rawSuggestions) {
        const suggestion = sanitizeSuggestion(raw, excluded, historicalTitles);
        if (!suggestion) continue;
        const normalized = normalizeTitle(suggestion.title);
        excluded.add(normalized);
        suggestions.push(suggestion);
        if (suggestions.length >= count) break;
    }

    return suggestions;
}

async function generateSuggestions(
    count: number,
    todos: TodoContextRow[],
    cronJobs: CronContextRow[],
    excludedTitles: string[],
    memories: MemoryRow[],
): Promise<TaskSuggestion[]> {
    if (!OPENAI_API_KEY) {
        throw new Error("openai_not_configured");
    }

    const forbiddenTitles = buildForbiddenTitles(todos, cronJobs);
    let suggestions = await callOpenAI(
        count,
        todos,
        cronJobs,
        excludedTitles,
        memories,
        forbiddenTitles,
    );

    if (suggestions.length < count && (todos.length > 0 || cronJobs.length > 0)) {
        const retryExcluded = [
            ...excludedTitles,
            ...suggestions.map((s) => s.title),
        ];
        const retry = await callOpenAI(
            count,
            todos,
            cronJobs,
            retryExcluded,
            memories,
            forbiddenTitles,
        );
        const seen = new Set(suggestions.map((s) => normalizeTitle(s.title)));
        for (const candidate of retry) {
            const key = normalizeTitle(candidate.title);
            if (seen.has(key)) continue;
            seen.add(key);
            suggestions.push(candidate);
            if (suggestions.length >= count) break;
        }
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
    const userId = userResp.user.id;

    const [todosResult, memoriesResult, cronResult] = await Promise.all([
        serviceClient
            .from("todos")
            .select(
                "title,original_title,status,connection_slug,preparation_summary,topic,collection_name,created_at,updated_at,completed_at",
            )
            .eq("user_id", userId)
            .order("updated_at", { ascending: false })
            .limit(MAX_FETCH_TODOS),
        serviceClient
            .from("memories")
            .select("title,body")
            .eq("user_id", userId)
            .eq("memory_status", "active")
            .eq("target", "user")
            .order("updated_at", { ascending: false })
            .limit(MAX_MEMORIES),
        serviceClient
            .from("cron_jobs")
            .select("name,prompt,schedule_display,connection_slug,state,last_status")
            .eq("user_id", userId)
            .order("updated_at", { ascending: false })
            .limit(MAX_FETCH_CRON_JOBS),
    ]);

    const { data, error } = todosResult;
    if (error) {
        console.error("cron-suggestions todo fetch error:", error);
        return json({ error: "todo_context_failed", detail: String(error.message ?? error) }, 500);
    }

    if (cronResult.error) {
        console.error("cron-suggestions cron fetch error:", cronResult.error);
        return json({ error: "cron_context_failed", detail: String(cronResult.error.message ?? cronResult.error) }, 500);
    }

    const todos = (data ?? []) as TodoContextRow[];
    const memories = (memoriesResult.data ?? []) as MemoryRow[];
    const cronJobs = (cronResult.data ?? []) as CronContextRow[];
    const hasHistory = todos.length > 0 || cronJobs.length > 0;
    const excluded = new Set(excludedTitles.map(normalizeTitle));

    try {
        const generated = await generateSuggestions(
            count,
            todos,
            cronJobs,
            excludedTitles,
            memories,
        );

        if (!hasHistory && generated.length < count) {
            const fallback = fallbackSuggestions(
                count - generated.length,
                new Set([
                    ...excluded,
                    ...generated.map((s) => normalizeTitle(s.title)),
                ]),
            );
            return json({ suggestions: [...generated, ...fallback].slice(0, count) });
        }

        return json({ suggestions: generated.slice(0, count) });
    } catch (err) {
        console.error("cron-suggestions generation error:", err);
        if (!hasHistory) {
            return json({
                suggestions: fallbackSuggestions(count, excluded),
                degraded: true,
                error: String(err),
            });
        }
        return json({
            suggestions: [],
            degraded: true,
            error: String(err),
        });
    }
});
