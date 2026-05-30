// Supabase Edge Function: transcribe-audio
//
// Receives a multipart/form-data audio upload from the iOS app and proxies it
// to OpenAI's audio transcription endpoint (Whisper-class models). The
// OpenAI API key never leaves the server: the iOS app authenticates with
// its Supabase JWT and we call OpenAI using `OPENAI_API_KEY` set as an Edge
// Function secret.
//
// Request:
//   POST multipart/form-data
//     file: audio file (m4a/aac/mp3/wav/webm/ogg/mp4)
//     language? (optional): ISO-639-1 language hint
//
// Response:
//   200 { text: "..." }
//   4xx/5xx { error: "...", detail?: "..." }

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY") ?? "";
const OPENAI_TRANSCRIBE_MODEL = Deno.env.get("OPENAI_TRANSCRIBE_MODEL") ??
    "whisper-1";

// Cap upload size so we don't relay arbitrarily large requests to OpenAI.
// 25 MB matches OpenAI's documented max for the audio transcriptions endpoint.
const MAX_BYTES = 25 * 1024 * 1024;

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

    if (!OPENAI_API_KEY) {
        return json({ error: "openai_not_configured" }, 500);
    }

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

    const contentLength = Number(req.headers.get("content-length") ?? "0");
    if (Number.isFinite(contentLength) && contentLength > MAX_BYTES) {
        return json({ error: "audio_too_large" }, 413);
    }

    let form: FormData;
    try {
        form = await req.formData();
    } catch {
        return json({ error: "invalid_form" }, 400);
    }

    const file = form.get("file");
    if (!(file instanceof File)) {
        return json({ error: "missing_file" }, 400);
    }
    if (file.size === 0) {
        return json({ error: "empty_audio" }, 400);
    }
    if (file.size > MAX_BYTES) {
        return json({ error: "audio_too_large" }, 413);
    }

    const language = form.get("language");

    // Re-build the multipart body for OpenAI. Setting an explicit filename
    // (with extension) helps OpenAI infer the audio format reliably.
    const filename = file.name && file.name.length > 0 ? file.name : "audio.m4a";
    const upstreamForm = new FormData();
    upstreamForm.append("file", file, filename);
    upstreamForm.append("model", OPENAI_TRANSCRIBE_MODEL);
    upstreamForm.append("response_format", "json");
    if (typeof language === "string" && language.length > 0) {
        upstreamForm.append("language", language);
    }

    let openaiRes: Response;
    try {
        openaiRes = await fetch(
            "https://api.openai.com/v1/audio/transcriptions",
            {
                method: "POST",
                headers: { Authorization: `Bearer ${OPENAI_API_KEY}` },
                body: upstreamForm,
            },
        );
    } catch (err) {
        console.error("transcribe-audio fetch failed:", err);
        return json({ error: "openai_unreachable" }, 502);
    }

    if (!openaiRes.ok) {
        const detail = await openaiRes.text();
        console.error(
            "transcribe-audio openai error:",
            openaiRes.status,
            detail,
        );
        return json(
            { error: "openai_error", detail },
            openaiRes.status >= 500 ? 502 : 400,
        );
    }

    let data: { text?: string };
    try {
        data = await openaiRes.json();
    } catch {
        return json({ error: "openai_bad_response" }, 502);
    }

    const text = (data.text ?? "").trim();
    return json({ text });
});
