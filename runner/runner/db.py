"""Supabase REST client wrapper for the runner (uses service_role)."""
from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

from supabase import Client, create_client

from .config import Config
from .hermes import HermesEndpoint

log = logging.getLogger(__name__)


_TITLE_MAX = 120
_CLAIM_STALE_AFTER = timedelta(minutes=15)


def _iso_z(dt: datetime) -> str:
    return dt.isoformat().replace("+00:00", "Z")


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
        """Atomically claim and return the oldest ``preparing`` todo.

        The row stays in ``status='preparing'`` so the iOS card still renders
        the correct placeholder, but ``prep_claimed_at`` acts as a short lease
        so overlapping runner processes do not both prepare and split the
        same todo.
        """
        now = datetime.now(UTC)
        now_iso = _iso_z(now)
        stale_before = _iso_z(now - _CLAIM_STALE_AFTER)
        try:
            resp = (
                self._client.table("todos")
                .select("*")
                .eq("status", "preparing")
                .or_(f"prep_claimed_at.is.null,prep_claimed_at.lt.{stale_before}")
                .order("created_at")
                .limit(1)
                .execute()
            )
            rows = resp.data or []
            if not rows:
                return None
            candidate = rows[0]
            upd = (
                self._client.table("todos")
                .update({"prep_claimed_at": now_iso})
                .eq("id", candidate["id"])
                .eq("status", "preparing")
                .or_(f"prep_claimed_at.is.null,prep_claimed_at.lt.{stale_before}")
                .execute()
            )
            claimed = upd.data or []
            return claimed[0] if claimed else None
        except Exception as e:
            log.error("claim_next_preparing_todo failed: %s", e)
            return None

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

    def list_user_hermes_profiles(self) -> list[dict]:
        """Return ``[{user_id, profile_name}, ...]`` for every provisioned user.

        Used by the memory-backfill CLI to iterate every user without
        loading the full endpoint (host/port/api_key aren't needed for a
        local file read). Sorted by ``user_id`` so output is stable.
        """
        try:
            resp = (
                self._client.table("user_hermes")
                .select("user_id, profile_name")
                .order("user_id")
                .execute()
            )
            return [
                {"user_id": str(r["user_id"]), "profile_name": str(r["profile_name"])}
                for r in (resp.data or [])
                if r.get("user_id") and r.get("profile_name")
            ]
        except Exception as e:
            log.error("list_user_hermes_profiles failed: %s", e)
            return []

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
            row = {
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
            }
            existing = (
                self._client.table("memories")
                .select("id, source")
                .eq("user_id", user_id)
                .eq("target", target)
                .eq("hermes_fingerprint", fingerprint)
                .limit(1)
                .execute()
            )
            rows = existing.data or []
            if rows:
                # If the user pinned this exact text first, leave their row
                # alone. The reverse mirror already treats it as seen because
                # fingerprints match; overwriting it would hide that it was
                # user-authored.
                if rows[0].get("source") != "hermes":
                    return
                self._client.table("memories").update(row).eq(
                    "id", rows[0]["id"]
                ).execute()
                return
            self._client.table("memories").insert(row).execute()
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
    # Live agent activity snapshot
    # ------------------------------------------------------------------
    #
    # `todo_steps` is the audit log (every event we recognized). The
    # `todo_agent_activity` table holds the *current* snapshot of what
    # Hermes is doing right now — one row per todo. The iOS app reads
    # this snapshot for the card status line, the detail-view animated
    # cards, and the Live Activity widget. See `runner/activity.py` for
    # how the snapshot is built and the
    # `supabase/migrations/...todo_agent_activity.sql` file for shape.

    def upsert_agent_activity(
        self,
        *,
        todo_id: str,
        user_id: str,
        fields: dict[str, Any],
    ) -> None:
        """Upsert the single current-activity row for a todo.

        `fields` is the dict returned by ``ActivitySnapshot.to_db_fields``;
        we splice in the keys this table requires (`todo_id`, `user_id`,
        `started_at` for first-time inserts) so callers don't have to
        know about every column. Failures are logged but never raise — a
        missed live-activity write is annoying but never blocks the run.
        """
        if not fields:
            return
        row: dict[str, Any] = dict(fields)
        row["todo_id"] = todo_id
        row["user_id"] = user_id
        row.setdefault("started_at", datetime.now(UTC).isoformat())
        try:
            self._client.table("todo_agent_activity").upsert(
                row,
                on_conflict="todo_id",
            ).execute()
        except Exception as e:
            log.error("upsert_agent_activity(%s) failed: %s", todo_id, e)

    def clear_agent_activity(self, todo_id: str) -> None:
        """Delete the current-activity row.

        Optional helper for hard cancellations; typical exit paths write
        a terminal snapshot via ``upsert_agent_activity`` so the iOS app
        gets a chance to render the closing card.
        """
        try:
            self._client.table("todo_agent_activity").delete().eq(
                "todo_id", todo_id
            ).execute()
        except Exception as e:
            log.error("clear_agent_activity(%s) failed: %s", todo_id, e)

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

    def list_todo_messages_for_context(
        self,
        todo_id: str,
        *,
        limit: int = 20,
    ) -> list[dict]:
        """Recent user-authored chat messages for a todo, oldest first.

        This feeds the explicit same-task context block in follow-up prompts.
        We do not rely solely on Hermes' session transcript because the app's
        task detail is already the source of truth for what the user sees.
        """
        try:
            resp = (
                self._client.table("todo_messages")
                .select("body, created_at")
                .eq("todo_id", todo_id)
                .order("created_at", desc=True)
                .limit(limit)
                .execute()
            )
            return list(reversed(resp.data or []))
        except Exception as e:
            log.error("list_todo_messages_for_context(%s) failed: %s", todo_id, e)
            return []

    def list_todo_steps_for_context(
        self,
        todo_id: str,
        *,
        limit: int = 30,
    ) -> list[dict]:
        """Recent runner-visible agent activity for a todo, oldest first."""
        try:
            resp = (
                self._client.table("todo_steps")
                .select("kind, text, url, tool_name, ts")
                .eq("todo_id", todo_id)
                .order("ts", desc=True)
                .limit(limit)
                .execute()
            )
            return list(reversed(resp.data or []))
        except Exception as e:
            log.error("list_todo_steps_for_context(%s) failed: %s", todo_id, e)
            return []

    # ------------------------------------------------------------------
    # Artifacts (user-visible deliverables)
    # ------------------------------------------------------------------

    def list_todo_artifacts_for_context(
        self,
        todo_id: str,
        *,
        limit: int = 20,
    ) -> list[dict]:
        """Current user-visible deliverables for a todo, newest last.

        Artifacts are the most important context for follow-up chat because
        the user naturally refers to "the sheet" or "the doc" they can see in
        the task detail. We include the payload JSON so URLs, subjects, and
        short text artifacts survive the next Hermes run.
        """
        try:
            resp = (
                self._client.table("todo_artifacts")
                .select("artifact_key, kind, title, payload, updated_at")
                .eq("todo_id", todo_id)
                .order("updated_at", desc=True)
                .limit(limit)
                .execute()
            )
            rows = list(reversed(resp.data or []))
            # supabase-py usually returns jsonb as dict already, but older
            # versions may hand back a JSON string. Normalize defensively.
            for row in rows:
                payload = row.get("payload")
                if isinstance(payload, str):
                    try:
                        row["payload"] = json.loads(payload)
                    except json.JSONDecodeError:
                        row["payload"] = {"raw": payload}
            return rows
        except Exception as e:
            log.error("list_todo_artifacts_for_context(%s) failed: %s", todo_id, e)
            return []

    def upload_todo_audio(
        self,
        *,
        user_id: str,
        todo_id: str,
        filename: str,
        data: bytes,
        mime_type: str,
    ) -> str | None:
        """Upload generated audio to the private ``todo-audio`` bucket.

        Mirrors the per-user folder layout used by ``todo-attachments`` so
        the existing storage RLS policies apply unchanged. The runner
        uses service_role and bypasses RLS for the upload itself, but
        iOS later signs the same path with the user's JWT.

        Returns the relative storage path on success (the value the
        runner persists on the audio artifact payload), or ``None`` on
        failure.
        """
        if not data:
            log.warning(
                "upload_todo_audio(user=%s, todo=%s) skipped: empty data",
                user_id, todo_id,
            )
            return None
        storage_path = f"{user_id}/{todo_id}/{filename}"
        try:
            self._client.storage.from_("todo-audio").upload(
                path=storage_path,
                file=data,
                file_options={
                    "content-type": mime_type,
                    "upsert": "false",
                },
            )
            return storage_path
        except Exception as e:
            log.error(
                "upload_todo_audio(user=%s, todo=%s) failed: %s",
                user_id, todo_id, e,
            )
            return None

    def upload_todo_image(
        self,
        *,
        user_id: str,
        todo_id: str,
        filename: str,
        data: bytes,
        mime_type: str,
    ) -> str | None:
        """Upload an agent-produced image to the private ``todo-images`` bucket.

        Same per-user folder layout as ``upload_todo_audio`` so the same
        RLS shape applies: ``<user_id>/<todo_id>/<filename>``. Returns
        the relative storage path on success or ``None`` on failure.
        """
        if not data:
            log.warning(
                "upload_todo_image(user=%s, todo=%s) skipped: empty data",
                user_id, todo_id,
            )
            return None
        storage_path = f"{user_id}/{todo_id}/{filename}"
        try:
            self._client.storage.from_("todo-images").upload(
                path=storage_path,
                file=data,
                file_options={
                    "content-type": mime_type,
                    "upsert": "false",
                },
            )
            return storage_path
        except Exception as e:
            log.error(
                "upload_todo_image(user=%s, todo=%s) failed: %s",
                user_id, todo_id, e,
            )
            return None

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
        status: str = "todo",
    ) -> dict | None:
        """Insert an already-prepared todo for multi-task splits.

        ``status`` defaults to ``todo`` for backward compatibility, but the
        prep pipeline now passes ``requested`` so split-out tasks auto-run
        in lockstep with the original `+` sheet submission.
        """
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
            status=status,
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

    def spawned_todo_title_exists(
        self,
        user_id: str,
        title: str,
        *,
        source_todo_id: str | None = None,
        source_cron_job_id: str | None = None,
    ) -> bool:
        """Best-effort fallback dedupe when an agent emits an unstable source_key."""
        try:
            query = (
                self._client.table("todos")
                .select("id")
                .eq("user_id", user_id)
                .eq("title", title)
                .limit(1)
            )
            if source_todo_id:
                query = query.eq("spawned_by_todo_id", source_todo_id)
            elif source_cron_job_id:
                query = query.eq("spawned_by_cron_job_id", source_cron_job_id)
            else:
                return False
            resp = query.execute()
            return bool(resp.data)
        except Exception as e:
            log.error("spawned_todo_title_exists(%r) failed: %s", title, e)
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
        status: str = "todo",
    ) -> dict | None:
        """Insert a ready todo, optionally with spawn provenance.

        ``status`` defaults to ``todo`` so existing agent/cron spawned
        tasks still wait for explicit user action. Callers that want a
        row to auto-run (the `+` sheet prep split) pass ``requested``.
        """
        row: dict[str, Any] = {
            "user_id": user_id,
            "title": title,
            "original_title": original_title,
            "detail": detail,
            "status": status,
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
        """Atomically claim the oldest cron job needing configuration."""
        now = datetime.now(UTC)
        now_iso = _iso_z(now)
        stale_before = _iso_z(now - _CLAIM_STALE_AFTER)
        try:
            resp = (
                self._client.table("cron_jobs")
                .select("*")
                .eq("state", "configuring")
                .or_(f"configure_claimed_at.is.null,configure_claimed_at.lt.{stale_before}")
                .order("updated_at")
                .limit(1)
                .execute()
            )
            rows = resp.data or []
            if not rows:
                return None
            candidate = rows[0]
            upd = (
                self._client.table("cron_jobs")
                .update({"configure_claimed_at": now_iso})
                .eq("id", candidate["id"])
                .eq("state", "configuring")
                .or_(f"configure_claimed_at.is.null,configure_claimed_at.lt.{stale_before}")
                .execute()
            )
            claimed = upd.data or []
            return claimed[0] if claimed else None
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
