"""Supabase REST client wrapper for the runner (uses service_role)."""
from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from supabase import Client, create_client

from .config import Config
from .hermes import HermesEndpoint

log = logging.getLogger(__name__)


_TITLE_MAX = 120


def _derive_title(text: str) -> str:
    """First non-empty line, clamped to the memories.title CHECK length."""
    for line in text.splitlines():
        candidate = line.strip()
        if candidate:
            return candidate[:_TITLE_MAX]
    return text.strip()[:_TITLE_MAX] or "Memory"


@dataclass(frozen=True)
class AgentModelSetting:
    provider: str
    model: str


class DB:
    def __init__(self, cfg: Config) -> None:
        self._client: Client = create_client(
            cfg.supabase_url,
            cfg.supabase_service_role_key,
        )

    # ------------------------------------------------------------------
    # Claiming work
    # ------------------------------------------------------------------

    def claim_next_preparing_todo(self) -> dict | None:
        """Return the oldest ``preparing`` todo, or ``None``.

        Unlike the execution claim, there is no separate "preparing in
        progress" status — the preparation pass is short and the runner is
        single-instance per deployment (see ``README.md``). If we ever scale
        to multiple runners we'll need a CAS column like ``prep_started_at``.
        """
        resp = (
            self._client.table("todos")
            .select("*")
            .eq("status", "preparing")
            .order("created_at")
            .limit(1)
            .execute()
        )
        rows = resp.data or []
        return rows[0] if rows else None

    def claim_next_requested_todo(self) -> dict | None:
        """Atomically transition one 'requested' todo to 'running' and return it.

        We do this in two phases: select one row id, then update WHERE id=?
        AND status='requested'. PostgREST returns the updated row, which is
        empty if someone else won the race — in which case we retry.
        """
        # Find one candidate.
        resp = (
            self._client.table("todos")
            .select("*")
            .eq("status", "requested")
            .order("created_at")
            .limit(1)
            .execute()
        )
        rows = resp.data or []
        if not rows:
            return None
        candidate = rows[0]

        # Try to claim it.
        upd = (
            self._client.table("todos")
            .update({"status": "running"})
            .eq("id", candidate["id"])
            .eq("status", "requested")
            .execute()
        )
        claimed = upd.data or []
        if not claimed:
            # Lost the race; caller can retry.
            return None
        return claimed[0]

    # ------------------------------------------------------------------
    # Lookups
    # ------------------------------------------------------------------

    def get_user_hermes(self, user_id: str) -> HermesEndpoint | None:
        resp = (
            self._client.table("user_hermes")
            .select("profile_name, api_host, api_port, api_key")
            .eq("user_id", user_id)
            .limit(1)
            .execute()
        )
        rows = resp.data or []
        if not rows:
            return None
        r = rows[0]
        return HermesEndpoint(
            profile_name=r["profile_name"],
            host=r.get("api_host") or "127.0.0.1",
            port=int(r["api_port"]),
            api_key=r["api_key"],
        )

    def get_pending_agent_model_setting(self, user_id: str) -> AgentModelSetting | None:
        settings_resp = (
            self._client.table("agent_model_settings")
            .select("provider, model")
            .eq("user_id", user_id)
            .eq("apply_status", "pending")
            .limit(1)
            .execute()
        )
        settings = settings_resp.data or []
        if not settings:
            return None
        setting = settings[0]

        return AgentModelSetting(
            provider=setting["provider"],
            model=setting["model"],
        )

    def get_todo(self, todo_id: str) -> dict | None:
        resp = (
            self._client.table("todos")
            .select("*")
            .eq("id", todo_id)
            .limit(1)
            .execute()
        )
        rows = resp.data or []
        return rows[0] if rows else None

    def list_apns_tokens(self, user_id: str) -> list[str]:
        resp = (
            self._client.table("devices")
            .select("apns_token")
            .eq("user_id", user_id)
            .execute()
        )
        return [r["apns_token"] for r in (resp.data or [])]

    def list_memories(self, user_id: str, limit: int = 20) -> list[dict]:
        """Legacy helper kept for the fallback prompt path.

        Returns the user's most recently updated memories regardless of sync
        state. Callers prefer the native Hermes memory sync (see
        ``list_memories_for_sync`` and ``list_synced_memories``); this is only
        used when the runner hasn't been able to confirm the native sync ran.
        """
        try:
            resp = (
                self._client.table("memories")
                .select("title, body, category")
                .eq("user_id", user_id)
                .order("updated_at", desc=True)
                .limit(limit)
                .execute()
            )
            return resp.data or []
        except Exception as e:
            log.error("list_memories(%s) failed: %s", user_id, e)
            return []

    def list_memories_for_sync(self, user_id: str) -> list[dict]:
        """Pending user-authored entries that need to land in a Hermes file.

        Returns the full row so the caller can update sync state afterward.
        """
        try:
            resp = (
                self._client.table("memories")
                .select("*")
                .eq("user_id", user_id)
                .eq("source", "user")
                .eq("sync_status", "pending")
                .order("updated_at")
                .execute()
            )
            return resp.data or []
        except Exception as e:
            log.error("list_memories_for_sync(%s) failed: %s", user_id, e)
            return []

    def list_synced_memories(self, user_id: str) -> list[dict]:
        """All rows that have a Hermes fingerprint, for the reverse sync diff."""
        try:
            resp = (
                self._client.table("memories")
                .select("id, target, source, hermes_fingerprint")
                .eq("user_id", user_id)
                .not_.is_("hermes_fingerprint", "null")
                .execute()
            )
            return resp.data or []
        except Exception as e:
            log.error("list_synced_memories(%s) failed: %s", user_id, e)
            return []

    def mark_memory_synced(
        self,
        memory_id: str,
        *,
        fingerprint: str,
        when_iso: str,
    ) -> None:
        try:
            self._client.table("memories").update(
                {
                    "sync_status": "synced",
                    "hermes_fingerprint": fingerprint,
                    "last_sync_at": when_iso,
                    "sync_error": None,
                }
            ).eq("id", memory_id).execute()
        except Exception as e:
            log.error("mark_memory_synced(%s) failed: %s", memory_id, e)

    def mark_memory_sync_failed(self, memory_id: str, *, error: str) -> None:
        try:
            self._client.table("memories").update(
                {"sync_status": "failed", "sync_error": error[:500]}
            ).eq("id", memory_id).execute()
        except Exception as e:
            log.error("mark_memory_sync_failed(%s) failed: %s", memory_id, e)

    def upsert_hermes_memory(
        self,
        *,
        user_id: str,
        target: str,
        text: str,
        fingerprint: str,
        when_iso: str,
    ) -> None:
        """Insert an agent-curated entry mirrored from a Hermes file.

        Title is the first line (clamped), body is the full text; this gives
        the iOS app something readable without enforcing structure the agent
        didn't intend.
        """
        title = _derive_title(text)
        body = text[:2000]
        try:
            self._client.table("memories").upsert(
                {
                    "user_id": user_id,
                    "title": title,
                    "body": body,
                    "category": None,
                    "target": target,
                    "source": "hermes",
                    "sync_status": "synced",
                    "hermes_fingerprint": fingerprint,
                    "last_sync_at": when_iso,
                    "sync_error": None,
                },
                on_conflict="user_id,target,hermes_fingerprint",
            ).execute()
        except Exception as e:
            log.error(
                "upsert_hermes_memory(user=%s, target=%s) failed: %s",
                user_id,
                target,
                e,
            )

    def delete_memory(self, memory_id: str) -> None:
        try:
            self._client.table("memories").delete().eq("id", memory_id).execute()
        except Exception as e:
            log.error("delete_memory(%s) failed: %s", memory_id, e)

    # ------------------------------------------------------------------
    # Writes
    # ------------------------------------------------------------------

    def update_todo(self, todo_id: str, fields: dict[str, Any]) -> None:
        try:
            self._client.table("todos").update(fields).eq("id", todo_id).execute()
        except Exception as e:
            log.error("update_todo(%s) failed: %s", todo_id, e)

    def update_agent_model_status(
        self,
        user_id: str,
        *,
        status: str,
        error: str | None = None,
    ) -> None:
        fields: dict[str, Any] = {
            "apply_status": status,
            "apply_error": error,
        }
        if status == "applied":
            fields["last_applied_at"] = datetime.now(UTC).isoformat()
        try:
            self._client.table("agent_model_settings").update(fields).eq(
                "user_id",
                user_id,
            ).execute()
        except Exception as e:
            log.error("update_agent_model_status(%s) failed: %s", user_id, e)

    def insert_step(
        self,
        *,
        todo_id: str,
        user_id: str,
        kind: str,
        text: str | None = None,
        url: str | None = None,
        tool_name: str | None = None,
    ) -> None:
        try:
            self._client.table("todo_steps").insert(
                {
                    "todo_id": todo_id,
                    "user_id": user_id,
                    "kind": kind,
                    "text": text,
                    "url": url,
                    "tool_name": tool_name,
                }
            ).execute()
        except Exception as e:
            log.error("insert_step(%s, %s) failed: %s", todo_id, kind, e)

    # ------------------------------------------------------------------
    # Interactions (structured ask-the-user)
    # ------------------------------------------------------------------

    def supersede_open_interactions(self, todo_id: str) -> None:
        """Mark any still-open interactions on a todo as superseded.

        We do this whenever we are about to insert a new one or when the
        todo enters a terminal state, so the iOS app never sees more than
        one actionable card per todo.
        """
        try:
            self._client.table("todo_interactions").update(
                {"status": "superseded"}
            ).eq("todo_id", todo_id).eq("status", "open").execute()
        except Exception as e:
            log.error("supersede_open_interactions(%s) failed: %s", todo_id, e)

    def insert_interaction(
        self,
        *,
        todo_id: str,
        user_id: str,
        kind: str,
        prompt: str,
        payload: dict[str, Any] | None = None,
        hermes_run_id: str | None = None,
    ) -> dict | None:
        try:
            resp = (
                self._client.table("todo_interactions")
                .insert(
                    {
                        "todo_id": todo_id,
                        "user_id": user_id,
                        "kind": kind,
                        "prompt": prompt,
                        "payload": payload or {},
                        "hermes_run_id": hermes_run_id,
                    }
                )
                .execute()
            )
            rows = resp.data or []
            return rows[0] if rows else None
        except Exception as e:
            log.error("insert_interaction(%s) failed: %s", todo_id, e)
            return None

    def get_open_interaction(self, todo_id: str) -> dict | None:
        try:
            resp = (
                self._client.table("todo_interactions")
                .select("*")
                .eq("todo_id", todo_id)
                .eq("status", "open")
                .order("created_at", desc=True)
                .limit(1)
                .execute()
            )
            rows = resp.data or []
            return rows[0] if rows else None
        except Exception as e:
            log.error("get_open_interaction(%s) failed: %s", todo_id, e)
            return None

    def get_latest_responded_interaction(self, todo_id: str) -> dict | None:
        try:
            resp = (
                self._client.table("todo_interactions")
                .select("*")
                .eq("todo_id", todo_id)
                .eq("status", "responded")
                .order("responded_at", desc=True)
                .order("created_at", desc=True)
                .limit(1)
                .execute()
            )
            rows = resp.data or []
            return rows[0] if rows else None
        except Exception as e:
            log.error("get_latest_responded_interaction(%s) failed: %s", todo_id, e)
            return None

    def mark_interaction(
        self,
        interaction_id: str,
        *,
        status: str,
        response: dict[str, Any] | None = None,
    ) -> None:
        fields: dict[str, Any] = {"status": status}
        if response is not None:
            fields["response"] = response
        if status in ("responded", "cancelled", "superseded"):
            fields["responded_at"] = datetime.now(UTC).isoformat()
        try:
            self._client.table("todo_interactions").update(fields).eq(
                "id", interaction_id
            ).execute()
        except Exception as e:
            log.error("mark_interaction(%s, %s) failed: %s", interaction_id, status, e)
