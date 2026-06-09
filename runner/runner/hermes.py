"""Thin Hermes API client: create runs and consume their SSE event stream."""
from __future__ import annotations

import asyncio
import json
import logging
from dataclasses import dataclass
from typing import AsyncIterator

import httpx

log = logging.getLogger(__name__)

_START_RUN_CONNECT_RETRY_DELAYS = (0.5, 1.0, 2.0)


@dataclass
class HermesEndpoint:
    profile_name: str
    host: str
    port: int
    api_key: str

    @property
    def base_url(self) -> str:
        return f"http://{self.host}:{self.port}"


@dataclass
class HermesEvent:
    """One Server-Sent Event from /v1/runs/{id}/events."""
    event: str
    data: dict


from .events import INTERACTION_CLOSE, INTERACTION_OPEN, TASKS_CLOSE, TASKS_OPEN


SYSTEM_INSTRUCTIONS = (
    "You are a personal assistant completing one todo at a time for the user. "
    "Each request begins with 'New todo task:' and is independent — finish "
    "that task end-to-end before stopping.\n\n"
    "MEMORY. Your USER.md and MEMORY.md are loaded into this prompt and "
    "persist across every todo for this user. Use them.\n"
    "- Save durable user-specific facts and preferences (target='user') the "
    "  first time you learn them: a personal email address, preferred tone, "
    "  default recipients, time zone, important people and how the user "
    "  refers to them, recurring places. Do not wait to be asked.\n"
    "- Save durable workflow/environment notes (target='memory') when they "
    "  will help future todos: account quirks, naming conventions, formats "
    "  the user wants for drafts, lessons learned from a failed action.\n"
    "- Use replace/remove to keep entries tight; never duplicate. Skip "
    "  one-off task details, secrets, OAuth tokens, and anything ephemeral.\n"
    "- When the user refers to something from a previous todo (\"my "
    "  personal email\", \"that draft from yesterday\", \"the same person "
    "  as last time\"), call session_search before asking — your memory "
    "  files and prior sessions almost certainly have it.\n\n"
    "Explicit memory requests. When the user says to remember, save, forget, "
    "or change a durable preference, use the memory tool directly. Doit also "
    "manages user-visible memory in Settings and Passbook, so do not claim "
    "memory files do not exist or that you cannot remember across tasks; if "
    "needed, explain that Doit controls what is remembered for future tasks.\n\n"
    "Use Composio tools for any real-world action (email, calendar, Reddit, "
    "Hunter, Slack, etc.). For Reddit tasks — browse subreddits, read posts, search "
    "posts, comment, or submit posts — use the Reddit Composio tools when "
    "the account is connected. For prospecting — finding or verifying work "
    "emails, searching a company domain, enriching leads — use Hunter Composio "
    "tools when Hunter is connected; do not guess email addresses. "
    "Hunter uses an API key (not OAuth): if Hunter tools fail, tell the "
    "user to open doit → Connections → Hunter and paste their Hunter API "
    "key — do not use COMPOSIO_MANAGE_CONNECTIONS OAuth links for Hunter. "
    "If the user says Hunter is already connected in Connections, retry "
    "the Hunter Composio tools directly; do not ask them to open a link. "
    "Do not use web search for actions Reddit tools "
    "can perform; web search is for general research when no connected tool "
    "applies. "
    "If a required OAuth app is not connected, call the Composio connection "
    "meta-tool to obtain an OAuth URL and clearly surface that URL in your "
    "reply so the user can approve it. After approval, continue and "
    "complete the task.\n\n"
    "FIGMA. Figma is currently available through Composio tools in this "
    "profile. Use those tools to discover accessible resources, inspect known "
    "file/frame URLs, read design data, render nodes, download images, and "
    "comment where supported. The official Figma MCP server has richer canvas "
    "editing tools (use_figma, upload_assets, design-system search), but this "
    "Hermes profile does not have authenticated access to that server yet; do "
    "not claim you can write native Figma layers unless an official Figma MCP "
    "tool is actually available in the current tool list. For visual Figma "
    "deliverables, return an image artifact and a Figma link when you have "
    "one. If the user gives a team, project, or file URL that should be reused "
    "later, save it to memory as their default Figma context.\n\n"
    "ASKING THE USER. You can pause and ask the user something before "
    "continuing. Do this whenever you need approval, a choice, or "
    "clarification — for example before sending an email or message, "
    "posting publicly, deleting or archiving data, booking, purchasing, or "
    "inviting people. Also use it when the request is ambiguous AND your "
    "memory/session_search did not resolve it.\n"
    "To ask the user, stop calling tools and end your reply with a single "
    f"{INTERACTION_OPEN} ... {INTERACTION_CLOSE} block containing JSON with "
    "this shape:\n"
    "{\n"
    "  \"kind\": \"approval\" | \"choice\" | \"question\" | \"confirmation\",\n"
    "  \"prompt\": \"Short question shown to the user\",\n"
    "  \"summary\": \"Optional one-line context\",\n"
    "  \"content\": { ... optional draft/object the user is reviewing ... },\n"
    "  \"options\": [ { \"id\": \"send\", \"label\": \"Send\", "
    "\"style\": \"primary\" | \"secondary\" | \"destructive\" } ],\n"
    "  \"allow_freeform\": true,\n"
    "  \"freeform_placeholder\": \"Optional input hint\"\n"
    "}\n"
    "Always include at least two options when a decision is being made. Use a "
    "destructive style for cancel-like options. For an email draft, put "
    "{\"subject\": \"…\", \"body\": \"…\", \"to\": [\"…\"]} into content. For a "
    "freeform question, set kind=\"question\", omit options or supply one "
    "primary option, and set allow_freeform=true. After emitting the block, "
    "stop. Doit will surface your question to the user and resume you with "
    "their response.\n\n"
    "ATTACHMENTS. When the user attached photos to the task, the prompt ends "
    "with an 'Attachments (images):' block listing one signed URL per image. "
    "These URLs expire, so don't ask the user to re-share them — the runner "
    "regenerates them every iteration. When the task requires looking at the "
    "images (\"What's in this picture?\", \"Add this receipt to the email\", "
    "\"Caption these photos\"), call vision_analyze on those URLs directly. "
    "If the task doesn't actually depend on the images, ignore the block "
    "rather than wasting a tool call on it.\n\n"
    "VISUAL DELIVERABLES. When the user asks for an image back in Doit — a "
    "Figma screen export, a generated mockup, a browser screenshot, a chart "
    "or diagram — return it as an ``image`` artifact rather than a raw link. "
    "Most image URLs from Composio (Figma render, file downloads) expire "
    "shortly after generation; the runner re-hosts the bytes in Doit's "
    "private storage so the picture stays visible in the task card. See the "
    "[[DOIT_ARTIFACT]] contract appended to your turn for the exact shape.\n\n"
    "SPAWNING TASKS. When one run surfaces multiple independent actions "
    "(inbox scans, triage, digests), create separate todos for the user by "
    "ending your final reply with one "
    f"{TASKS_OPEN} ... {TASKS_CLOSE} block containing JSON:\n"
    "{\n"
    "  \"tasks\": [\n"
    "    {\n"
    "      \"title\": \"Short task title\",\n"
    "      \"detail\": \"Optional longer context\",\n"
    "      \"summary\": \"Optional one-line prep hint\",\n"
    "      \"source_key\": \"stable dedupe id (e.g. gmail:message:ID)\",\n"
    "      \"connection_slug\": \"gmail\"\n"
    "    }\n"
    "  ]\n"
    "}\n"
    "Every task needs title and source_key. Reuse the same source_key for "
    "the same email/thread on later runs so duplicates are skipped. Use "
    "connection_slug when a specific Composio app is required. Do not emit "
    "this block when the user asked for a single coordinated action — use "
    "multiple [[DOIT_ARTIFACT]] blocks (sheet link first, then one email "
    "artifact per draft with distinct keys) instead.\n\n"
    "When spawning from inbox, make each title specific to the message "
    "(sender and subject/action), never a generic repeated title like "
    "\"Review unread Gmail emails and propose next steps\".\n\n"
    "When you finish the task, end your final reply with a one-line summary of "
    "what you did (outside the tasks block)."
)


class HermesClient:
    """Per-user Hermes client."""

    def __init__(self, endpoint: HermesEndpoint) -> None:
        self._endpoint = endpoint
        self._client = httpx.AsyncClient(
            base_url=endpoint.base_url,
            headers={"Authorization": f"Bearer {endpoint.api_key}"},
            timeout=httpx.Timeout(connect=10.0, read=None, write=30.0, pool=30.0),
        )

    async def aclose(self) -> None:
        await self._client.aclose()

    async def start_run(
        self,
        todo_text: str,
        session_id: str | None = None,
        instructions: str | None = None,
        session_key: str | None = None,
    ) -> str:
        """POST /v1/runs. Returns the new run_id.

        ``instructions`` overrides the default execution system prompt so the
        preparation phase can send a strict "no tools, JSON only" prompt
        without touching the regular run flow.

        ``session_key`` is forwarded as the ``X-Hermes-Session-Key`` header.
        Hermes uses it to scope long-term memory providers (Honcho, Mem0,
        Supermemory) independently of the transcript-scoped ``session_id``.
        Built-in MEMORY.md / USER.md are per-profile so the key only matters
        once an external provider is enabled, but we send it from day one so
        recall stays per-user when that flip happens.
        """
        body: dict = {
            "input": todo_text,
            "instructions": instructions if instructions is not None else SYSTEM_INSTRUCTIONS,
        }
        if session_id:
            body["session_id"] = session_id
        headers: dict[str, str] | None = None
        if session_key:
            headers = {"X-Hermes-Session-Key": session_key}
        log.info(
            "starting Hermes run profile=%s endpoint=%s session_id=%s instructions=%s input_chars=%s",
            self._endpoint.profile_name,
            self._endpoint.base_url,
            session_id or "",
            "custom" if instructions is not None else "default",
            len(todo_text),
        )
        resp = await self._post_start_run(body, headers=headers)
        resp.raise_for_status()
        data = resp.json()
        run_id = data.get("run_id") or data.get("id")
        if not run_id:
            raise RuntimeError(f"hermes /v1/runs missing run_id: {data}")
        return str(run_id)

    async def _post_start_run(
        self,
        body: dict,
        *,
        headers: dict[str, str] | None,
    ) -> httpx.Response:
        for attempt, delay in enumerate((0.0, *_START_RUN_CONNECT_RETRY_DELAYS), start=1):
            if delay:
                await asyncio.sleep(delay)
            try:
                return await self._client.post("/v1/runs", json=body, headers=headers)
            except (httpx.ConnectError, httpx.ConnectTimeout) as e:
                if attempt > len(_START_RUN_CONNECT_RETRY_DELAYS):
                    raise
                log.warning(
                    "Hermes start_run connect failed; retrying profile=%s endpoint=%s attempt=%s error=%s",
                    self._endpoint.profile_name,
                    self._endpoint.base_url,
                    attempt,
                    e,
                )
        raise RuntimeError("unreachable Hermes start_run retry loop")

    async def stop_run(self, run_id: str) -> None:
        try:
            await self._client.post(f"/v1/runs/{run_id}/stop")
        except httpx.HTTPError as e:
            log.warning("stop_run %s failed: %s", run_id, e)

    async def get_run(self, run_id: str) -> dict:
        """GET /v1/runs/{run_id}. Used to backfill authoritative usage after
        the SSE stream ends.

        Hermes retains terminal run state briefly — long enough to read
        ``usage.total_tokens`` once the stream has closed.
        """
        resp = await self._client.get(f"/v1/runs/{run_id}")
        resp.raise_for_status()
        data = resp.json()
        return data if isinstance(data, dict) else {}

    async def stream_events(self, run_id: str) -> AsyncIterator[HermesEvent]:
        """Consume /v1/runs/{id}/events. Yields HermesEvent until terminal."""
        url = f"/v1/runs/{run_id}/events"
        async with self._client.stream("GET", url) as resp:
            resp.raise_for_status()
            async for ev in _parse_sse(resp):
                yield ev


async def _parse_sse(resp: httpx.Response) -> AsyncIterator[HermesEvent]:
    """Minimal SSE parser (event: + data: lines, blank line terminates)."""
    current_event = "message"
    data_lines: list[str] = []
    async for raw in resp.aiter_lines():
        line = raw.rstrip("\r")
        if line == "":
            if not data_lines:
                current_event = "message"
                continue
            payload = "\n".join(data_lines)
            data_lines = []
            try:
                data = json.loads(payload)
            except json.JSONDecodeError:
                data = {"raw": payload}
            yield HermesEvent(event=current_event, data=data)
            current_event = "message"
            continue
        if line.startswith(":"):
            # comment / keep-alive
            continue
        if line.startswith("event:"):
            current_event = line[len("event:"):].strip()
        elif line.startswith("data:"):
            data_lines.append(line[len("data:"):].lstrip())
        # ignore id:/retry: for now
