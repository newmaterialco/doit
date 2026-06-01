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

    def list_todo_attachments(self, todo_id: str) -> list[dict]:
        """All image attachments for a todo, oldest first.

        We keep the order stable so the agent sees images in the order the
        user added them. The runner re-signs each row's storage path right
        before building the prompt — see ``sign_attachment_url``.
        """
        try:
            resp = (
                self._client.table("todo_attachments")
                .select("*")
                .eq("todo_id", todo_id)
                .order("created_at")
                .execute()
            )
            return resp.data or []
        except Exception as e:
            log.error("list_todo_attachments(%s) failed: %s", todo_id, e)
            return []

    def sign_attachment_url(
        self,
        storage_path: str,
        *,
        ttl_seconds: int = 24 * 60 * 60,
    ) -> str | None:
        """Generate a short-lived signed URL for an attachment.

        TTL defaults to 24 hours: long enough that a single agent run can
        finish (with some interactive back-and-forth) but short enough that
        leaked URLs don't stay live forever. URLs are intentionally re-signed
        every time the runner builds a prompt, so even on resumes that span
        the TTL the agent always gets a fresh URL.
        """
        try:
            resp = self._client.storage.from_("todo-attachments").create_signed_url(
                storage_path,
                ttl_seconds,
            )
            # supabase-py returns either {"signedURL": "..."} or
            # {"signedUrl": "..."} depending on version.
            if isinstance(resp, dict):
                return resp.get("signedURL") or resp.get("signedUrl")
            return None
        except Exception as e:
            log.error("sign_attachment_url(%s) failed: %s", storage_path, e)
            return None

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

    def increment_todo_tokens(self, todo_id: str, delta: int) -> None:
        """Atomically bump `todos.total_tokens` by `delta` via the
        `increment_todo_tokens(uuid, bigint)` Postgres RPC.

        Negative or zero deltas are dropped client-side so we don't make a
        round trip when the caller already knows there's nothing to add.
        """
        if delta <= 0:
            return
        try:
            self._client.rpc(
                "increment_todo_tokens",
                {"p_todo_id": todo_id, "p_delta": int(delta)},
            ).execute()
        except Exception as e:
            log.error(
                "increment_todo_tokens(%s, %d) failed: %s",
                todo_id, delta, e,
            )

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

    # ------------------------------------------------------------------
    # Free-form user chat messages
    # ------------------------------------------------------------------

    def get_unconsumed_user_messages(self, todo_id: str) -> list[dict]:
        """Messages the user sent that haven't been folded into a prompt yet.

        Returned oldest-first so the runner can quote them in conversational
        order when it weaves them into the next Hermes turn.
        """
        try:
            resp = (
                self._client.table("todo_messages")
                .select("*")
                .eq("todo_id", todo_id)
                .is_("consumed_at", "null")
                .order("created_at")
                .execute()
            )
            return resp.data or []
        except Exception as e:
            log.error("get_unconsumed_user_messages(%s) failed: %s", todo_id, e)
            return []

    def mark_user_messages_consumed(self, message_ids: list[str]) -> None:
        """Stamp `consumed_at` on every message we just put in a prompt.

        Done in a single update so a slow runner can't double-include the
        same message in a follow-up resume.
        """
        if not message_ids:
            return
        try:
            self._client.table("todo_messages").update(
                {"consumed_at": datetime.now(UTC).isoformat()}
            ).in_("id", message_ids).execute()
        except Exception as e:
            log.error(
                "mark_user_messages_consumed(%d ids) failed: %s",
                len(message_ids),
                e,
            )

    # ------------------------------------------------------------------
    # Artifacts (user-visible deliverables)
    # ------------------------------------------------------------------

    def upsert_artifact(
        self,
        *,
        todo_id: str,
        user_id: str,
        key: str,
        kind: str,
        title: str | None,
        payload: dict[str, Any] | None,
        hermes_run_id: str | None = None,
    ) -> None:
        """Insert or update a ``todo_artifacts`` row keyed on (todo_id, key).

        The agent reuses ``key`` across turns to update a previously-emitted
        artifact in place (e.g. swap a draft URL for a final one), so we
        rely on the table's ``unique (todo_id, artifact_key)`` constraint
        with PostgREST's ``on_conflict`` to avoid duplicates.
        """
        row: dict[str, Any] = {
            "todo_id": todo_id,
            "user_id": user_id,
            "artifact_key": key,
            "kind": kind,
            "title": title,
            "payload": payload or {},
            "hermes_run_id": hermes_run_id,
            "updated_at": datetime.now(UTC).isoformat(),
        }
        try:
            self._client.table("todo_artifacts").upsert(
                row, on_conflict="todo_id,artifact_key"
            ).execute()
        except Exception as e:
            log.error(
                "upsert_artifact(todo=%s, key=%s) failed: %s",
                todo_id, key, e,
            )

    # ------------------------------------------------------------------
    # Cron jobs (scheduled automations)
    # ------------------------------------------------------------------

    def insert_cron_job(self, fields: dict[str, Any]) -> dict | None:
        try:
            resp = self._client.table("cron_jobs").insert(fields).execute()
            rows = resp.data or []
            return rows[0] if rows else None
        except Exception as e:
            log.error("insert_cron_job failed: %s", e)
            return None

    def update_cron_job(self, job_id: str, fields: dict[str, Any]) -> None:
        try:
            self._client.table("cron_jobs").update(fields).eq("id", job_id).execute()
        except Exception as e:
            log.error("update_cron_job(%s) failed: %s", job_id, e)

    def delete_todo(self, todo_id: str) -> None:
        try:
            self._client.table("todos").delete().eq("id", todo_id).execute()
        except Exception as e:
            log.error("delete_todo(%s) failed: %s", todo_id, e)

    def insert_prepared_todo(
        self,
        *,
        user_id: str,
        title: str,
        original_title: str,
        detail: str | None = None,
        connection_slug: str | None = None,
        preparation_summary: str | None = None,
    ) -> dict | None:
        """Insert an already-prepared todo (status=todo) for multi-task splits."""
        return self.insert_spawned_todo(
            user_id=user_id,
            title=title,
            original_title=original_title,
            detail=detail,
            connection_slug=connection_slug,
            preparation_summary=preparation_summary,
            spawn_key=None,
            spawned_by_todo_id=None,
            spawned_by_cron_job_id=None,
        )

    def spawn_key_exists(self, user_id: str, spawn_key: str) -> bool:
        if not spawn_key:
            return False
        try:
            resp = (
                self._client.table("todos")
                .select("id")
                .eq("user_id", user_id)
                .eq("spawn_key", spawn_key)
                .limit(1)
                .execute()
            )
            return bool(resp.data)
        except Exception as e:
            log.error("spawn_key_exists(%s) failed: %s", spawn_key, e)
            return False

    def insert_spawned_todo(
        self,
        *,
        user_id: str,
        title: str,
        original_title: str,
        detail: str | None = None,
        connection_slug: str | None = None,
        preparation_summary: str | None = None,
        spawn_key: str | None = None,
        spawned_by_todo_id: str | None = None,
        spawned_by_cron_job_id: str | None = None,
    ) -> dict | None:
        """Insert a ready todo (status=todo), optionally with spawn provenance."""
        row: dict[str, Any] = {
            "user_id": user_id,
            "title": title,
            "original_title": original_title,
            "detail": detail,
            "status": "todo",
        }
        if connection_slug:
            row["connection_slug"] = connection_slug
        if preparation_summary:
            row["preparation_summary"] = preparation_summary
        if spawn_key:
            row["spawn_key"] = spawn_key
        if spawned_by_todo_id:
            row["spawned_by_todo_id"] = spawned_by_todo_id
        if spawned_by_cron_job_id:
            row["spawned_by_cron_job_id"] = spawned_by_cron_job_id
        try:
            resp = self._client.table("todos").insert(row).execute()
            rows = resp.data or []
            return rows[0] if rows else None
        except Exception as e:
            log.error("insert_spawned_todo failed: %s", e)
            return None

    def claim_due_cron_jobs(self, *, limit: int = 3) -> list[dict]:
        """Return due cron jobs and mark them running (best-effort claim)."""
        now_iso = datetime.now(UTC).isoformat()
        try:
            resp = (
                self._client.table("cron_jobs")
                .select("*")
                .eq("enabled", True)
                .eq("state", "scheduled")
                .lte("next_run_at", now_iso)
                .order("next_run_at")
                .limit(limit)
                .execute()
            )
        except Exception as e:
            log.error("claim_due_cron_jobs select failed: %s", e)
            return []
        claimed: list[dict] = []
        for row in resp.data or []:
            job_id = row["id"]
            upd = (
                self._client.table("cron_jobs")
                .update({"state": "running"})
                .eq("id", job_id)
                .eq("state", "scheduled")
                .execute()
            )
            if upd.data:
                claimed.append(upd.data[0])
        return claimed

    def get_cron_job(self, job_id: str) -> dict | None:
        try:
            resp = (
                self._client.table("cron_jobs")
                .select("*")
                .eq("id", job_id)
                .limit(1)
                .execute()
            )
            rows = resp.data or []
            return rows[0] if rows else None
        except Exception as e:
            log.error("get_cron_job(%s) failed: %s", job_id, e)
            return None

    def claim_next_configuring_cron_job(self) -> dict | None:
        """Return the oldest cron job needing configuration."""
        try:
            resp = (
                self._client.table("cron_jobs")
                .select("*")
                .eq("state", "configuring")
                .order("updated_at")
                .limit(1)
                .execute()
            )
            rows = resp.data or []
            return rows[0] if rows else None
        except Exception as e:
            log.error("claim_next_configuring_cron_job failed: %s", e)
            return None

    def get_unconsumed_cron_messages(self, cron_job_id: str) -> list[dict]:
        try:
            resp = (
                self._client.table("cron_job_messages")
                .select("*")
                .eq("cron_job_id", cron_job_id)
                .is_("consumed_at", "null")
                .order("created_at")
                .execute()
            )
            return resp.data or []
        except Exception as e:
            log.error("get_unconsumed_cron_messages(%s) failed: %s", cron_job_id, e)
            return []

    def mark_cron_messages_consumed(self, message_ids: list[str]) -> None:
        if not message_ids:
            return
        now = datetime.now(UTC).isoformat()
        try:
            self._client.table("cron_job_messages").update(
                {"consumed_at": now}
            ).in_("id", message_ids).execute()
        except Exception as e:
            log.error("mark_cron_messages_consumed failed: %s", e)

    def supersede_open_cron_interactions(self, cron_job_id: str) -> None:
        try:
            self._client.table("cron_job_interactions").update(
                {"status": "superseded"}
            ).eq("cron_job_id", cron_job_id).eq("status", "open").execute()
        except Exception as e:
            log.error("supersede_open_cron_interactions(%s) failed: %s", cron_job_id, e)

    def insert_cron_interaction(
        self,
        *,
        cron_job_id: str,
        user_id: str,
        kind: str,
        prompt: str,
        payload: dict[str, Any] | None = None,
        hermes_run_id: str | None = None,
    ) -> dict | None:
        try:
            resp = (
                self._client.table("cron_job_interactions")
                .insert(
                    {
                        "cron_job_id": cron_job_id,
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
            log.error("insert_cron_interaction(%s) failed: %s", cron_job_id, e)
            return None

    def mark_cron_interaction(self, interaction_id: str, *, status: str) -> None:
        fields: dict[str, Any] = {"status": status}
        if status in ("responded", "cancelled", "superseded"):
            fields["responded_at"] = datetime.now(UTC).isoformat()
        try:
            self._client.table("cron_job_interactions").update(fields).eq(
                "id", interaction_id
            ).execute()
        except Exception as e:
            log.error("mark_cron_interaction(%s) failed: %s", interaction_id, e)

    def get_latest_responded_cron_interaction(self, cron_job_id: str) -> dict | None:
        try:
            resp = (
                self._client.table("cron_job_interactions")
                .select("*")
                .eq("cron_job_id", cron_job_id)
                .eq("status", "responded")
                .order("responded_at", desc=True)
                .order("created_at", desc=True)
                .limit(1)
                .execute()
            )
            rows = resp.data or []
            return rows[0] if rows else None
        except Exception as e:
            log.error(
                "get_latest_responded_cron_interaction(%s) failed: %s",
                cron_job_id,
                e,
            )
            return None
