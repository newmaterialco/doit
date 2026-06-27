"""Supabase REST client wrapper for the runner (uses service_role)."""
from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any

from supabase import Client, create_client

from .config import Config
from .hermes import HermesEndpoint
from .memory_dedupe import best_duplicate_memory
from .memory_symbol import infer_memory_symbol, resolve_memory_symbol

log = logging.getLogger(__name__)


UTC = timezone.utc
_TITLE_MAX = 120
_CLAIM_STALE_AFTER = timedelta(minutes=15)


def _iso_z(dt: datetime) -> str:
    return dt.isoformat().replace("+00:00", "Z")


def _parse_supabase_datetime(value: Any) -> datetime | None:
    if value is None:
        return None
    if isinstance(value, datetime):
        return value if value.tzinfo is not None else value.replace(tzinfo=UTC)
    if not isinstance(value, str):
        return None
    text = value.strip()
    if not text:
        return None
    try:
        parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo is not None else parsed.replace(tzinfo=UTC)


def _cron_config_claimable(row: dict[str, Any], stale_before: datetime) -> bool:
    claimed_at = _parse_supabase_datetime(row.get("configure_claimed_at"))
    if claimed_at is None:
        return True
    if claimed_at < stale_before:
        return True
    updated_at = _parse_supabase_datetime(row.get("updated_at"))
    if updated_at is None:
        return False
    # Reconfiguration updates `updated_at`; a runner claim also touches
    # `updated_at`, so require a real gap to avoid immediately reclaiming
    # our own fresh lease.
    return updated_at > claimed_at + timedelta(seconds=1)


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
    apply_status: str | None = None


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

    def claim_next_requested_todo(
        self,
        *,
        exclude_user_ids: list[str] | None = None,
    ) -> dict | None:
        """Atomically transition one 'requested' todo to 'running' and return it.

        We do this in two phases: select one row id, then update WHERE id=?
        AND status='requested'. PostgREST returns the updated row, which is
        empty if someone else won the race — in which case we retry.

        ``exclude_user_ids`` skips users currently at their per-user
        execution cap; their todos stay ``requested`` until a slot frees up.
        The claim also stamps ``run_claimed_at`` so a crashed runner's work
        can be recovered (see ``claim_stale_running_todo``).
        """
        query = (
            self._client.table("todos")
            .select("*")
            .eq("status", "requested")
        )
        if exclude_user_ids:
            query = query.not_.in_("user_id", exclude_user_ids)
        resp = query.order("created_at").limit(1).execute()
        rows = resp.data or []
        if not rows:
            return None
        candidate = rows[0]

        # Try to claim it.
        upd = (
            self._client.table("todos")
            .update(
                {
                    "status": "running",
                    "run_claimed_at": _iso_z(datetime.now(UTC)),
                    "error_message": None,
                }
            )
            .eq("id", candidate["id"])
            .eq("status", "requested")
            .execute()
        )
        claimed = upd.data or []
        if not claimed:
            # Lost the race; caller can retry.
            return None
        return claimed[0]

    def claim_stale_running_todo(
        self,
        *,
        exclude_user_ids: list[str] | None = None,
    ) -> dict | None:
        """Recover one ``running`` todo whose execution lease went stale.

        A healthy run heartbeats ``run_claimed_at`` (see
        ``touch_todo_run_lease``); a stale lease means the runner that
        claimed the todo died mid-run. Re-claiming restarts the work from
        the same Hermes session instead of stranding the row in ``running``.
        Rows with a NULL ``run_claimed_at`` are also recovered — they were
        claimed by a pre-lease runner version that no longer exists.
        """
        now = datetime.now(UTC)
        stale_before = _iso_z(now - _CLAIM_STALE_AFTER)
        try:
            query = (
                self._client.table("todos")
                .select("*")
                .eq("status", "running")
                .or_(f"run_claimed_at.is.null,run_claimed_at.lt.{stale_before}")
            )
            if exclude_user_ids:
                query = query.not_.in_("user_id", exclude_user_ids)
            resp = query.order("created_at").limit(1).execute()
            rows = resp.data or []
            if not rows:
                return None
            candidate = rows[0]
            upd = (
                self._client.table("todos")
                .update({"run_claimed_at": _iso_z(now)})
                .eq("id", candidate["id"])
                .eq("status", "running")
                .or_(f"run_claimed_at.is.null,run_claimed_at.lt.{stale_before}")
                .execute()
            )
            claimed = upd.data or []
            if claimed:
                log.warning(
                    "recovered stale running todo %s (lease expired)",
                    candidate["id"],
                )
            return claimed[0] if claimed else None
        except Exception as e:
            log.error("claim_stale_running_todo failed: %s", e)
            return None

    def touch_todo_run_lease(self, todo_id: str) -> None:
        """Heartbeat the execution lease for an in-flight todo."""
        try:
            self._client.table("todos").update(
                {"run_claimed_at": _iso_z(datetime.now(UTC))}
            ).eq("id", todo_id).execute()
        except Exception as e:
            log.error("touch_todo_run_lease(%s) failed: %s", todo_id, e)

    # ------------------------------------------------------------------
    # Provisioning (invite-gated agent creation; see runner/provision.py)
    # ------------------------------------------------------------------

    def claim_next_provisioning_user(self) -> dict | None:
        """Claim one user awaiting provisioning (CAS pending -> provisioning).

        Also recovers rows stuck in ``provisioning`` whose ``claimed_at``
        lease went stale (crashed provisioner), mirroring the todo claim
        pattern.
        """
        now = datetime.now(UTC)
        now_iso = _iso_z(now)
        stale_before = _iso_z(now - _CLAIM_STALE_AFTER)
        try:
            resp = (
                self._client.table("user_provisioning")
                .select("*")
                .or_(
                    "status.eq.pending,"
                    f"and(status.eq.provisioning,claimed_at.lt.{stale_before})"
                )
                .order("created_at")
                .limit(1)
                .execute()
            )
            rows = resp.data or []
            if not rows:
                return None
            candidate = rows[0]
            upd = (
                self._client.table("user_provisioning")
                .update({"status": "provisioning", "claimed_at": now_iso})
                .eq("user_id", candidate["user_id"])
                .or_(
                    "status.eq.pending,"
                    f"and(status.eq.provisioning,claimed_at.lt.{stale_before})"
                )
                .execute()
            )
            claimed = upd.data or []
            return claimed[0] if claimed else None
        except Exception as e:
            log.error("claim_next_provisioning_user failed: %s", e)
            return None

    def update_user_provisioning(self, user_id: str, fields: dict[str, Any]) -> None:
        try:
            self._client.table("user_provisioning").update(fields).eq(
                "user_id", user_id
            ).execute()
        except Exception as e:
            log.error("update_user_provisioning(%s) failed: %s", user_id, e)

    def count_user_hermes(self) -> int:
        resp = (
            self._client.table("user_hermes")
            .select("user_id", count="exact")
            .limit(1)
            .execute()
        )
        return int(resp.count or 0)

    def max_user_hermes_port(self) -> int | None:
        resp = (
            self._client.table("user_hermes")
            .select("api_port")
            .order("api_port", desc=True)
            .limit(1)
            .execute()
        )
        rows = resp.data or []
        return int(rows[0]["api_port"]) if rows else None

    def upsert_user_hermes(
        self,
        *,
        user_id: str,
        profile_name: str,
        api_host: str,
        api_port: int,
        api_key: str,
        composio_entity: str,
    ) -> None:
        """Insert/refresh the user's gateway mapping. Raises on failure so the
        provisioner marks the run failed instead of reporting a phantom
        success (this row is what makes the agent usable)."""
        self._client.table("user_hermes").upsert(
            {
                "user_id": user_id,
                "profile_name": profile_name,
                "api_host": api_host,
                "api_port": api_port,
                "api_key": api_key,
                "composio_entity": composio_entity,
            },
            on_conflict="user_id",
        ).execute()

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
            .select("provider, model, apply_status")
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
            apply_status=setting.get("apply_status"),
        )

    def get_agent_model_setting(self, user_id: str) -> AgentModelSetting | None:
        settings_resp = (
            self._client.table("agent_model_settings")
            .select("provider, model, apply_status")
            .eq("user_id", user_id)
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
            apply_status=setting.get("apply_status"),
        )

    def get_memory_settings(self, user_id: str) -> dict:
        try:
            resp = (
                self._client.table("memory_settings")
                .select("automatic_suggestions_enabled, custom_instructions")
                .eq("user_id", user_id)
                .limit(1)
                .execute()
            )
            rows = resp.data or []
            if not rows:
                return {
                    "automatic_suggestions_enabled": True,
                    "custom_instructions": None,
                }
            return rows[0]
        except Exception as e:
            log.error("get_memory_settings(%s) failed: %s", user_id, e)
            return {
                "automatic_suggestions_enabled": True,
                "custom_instructions": None,
            }

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

    def list_waiting_todos_for_reminder(
        self,
        *,
        older_than: datetime,
        limit: int = 25,
    ) -> list[dict]:
        """Todos paused on the user long enough to warrant a reminder."""
        try:
            resp = (
                self._client.table("todos")
                .select("id,user_id,title,status,updated_at")
                .in_("status", ["needs_input", "needs_auth"])
                .lt("updated_at", _iso_z(older_than))
                .order("updated_at")
                .limit(limit)
                .execute()
            )
            return resp.data or []
        except Exception as e:
            log.error("list_waiting_todos_for_reminder failed: %s", e)
            return []

    def get_todo_organization_examples(
        self,
        user_id: str,
        *,
        exclude_todo_id: str | None = None,
        limit: int = 20,
    ) -> list[dict]:
        """Recent organized todos to keep prep topic/collection choices consistent."""
        try:
            resp = (
                self._client.table("todos")
                .select("id,title,topic,collection_name,updated_at,status")
                .eq("user_id", user_id)
                .order("updated_at", desc=True)
                .limit(max(limit * 3, limit))
                .execute()
            )
            rows = resp.data or []
        except Exception as e:
            log.error("get_todo_organization_examples(%s) failed: %s", user_id, e)
            return []

        examples: list[dict] = []
        for row in rows:
            if exclude_todo_id and row.get("id") == exclude_todo_id:
                continue
            if not (row.get("topic") or row.get("collection_name")):
                continue
            examples.append(row)
            if len(examples) >= limit:
                break
        return examples

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

    def get_last_terminal_step_ts(self, todo_id: str) -> str | None:
        """Timestamp of the most recent final/error step for a todo.

        ``None`` on first runs (no terminal step yet). Used to split the
        Attachments prompt block into previously-processed vs newly-attached
        images on follow-up turns.
        """
        try:
            resp = (
                self._client.table("todo_steps")
                .select("ts")
                .eq("todo_id", todo_id)
                .in_("kind", ["final", "error"])
                .order("ts", desc=True)
                .limit(1)
                .execute()
            )
            rows = resp.data or []
            ts = rows[0].get("ts") if rows else None
            return str(ts) if ts else None
        except Exception as e:
            log.error("get_last_terminal_step_ts(%s) failed: %s", todo_id, e)
            return None

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

    def list_apns_tokens(self, user_id: str) -> list[dict[str, str]]:
        resp = (
            self._client.table("devices")
            .select("apns_token, apns_environment")
            .eq("user_id", user_id)
            .execute()
        )
        return [
            {
                "token": r["apns_token"],
                "environment": r.get("apns_environment") or "production",
            }
            for r in (resp.data or [])
            if r.get("apns_token")
        ]

    def delete_apns_token(self, token: str) -> None:
        try:
            self._client.table("devices").delete().eq("apns_token", token).execute()
        except Exception as e:
            log.error("delete_apns_token(%s) failed: %s", token[:8], e)

    def list_live_activity_tokens(self, todo_id: str) -> list[dict[str, str]]:
        try:
            resp = (
                self._client.table("todo_live_activity_tokens")
                .select("push_token, apns_environment")
                .eq("todo_id", todo_id)
                .is_("ended_at", "null")
                .execute()
            )
        except Exception as e:
            log.error("list_live_activity_tokens(%s) failed: %s", todo_id, e)
            return []
        return [
            {
                "token": r["push_token"],
                "environment": r.get("apns_environment") or "production",
            }
            for r in (resp.data or [])
            if r.get("push_token")
        ]

    def delete_live_activity_token(self, token: str) -> None:
        try:
            self._client.table("todo_live_activity_tokens").update(
                {"ended_at": datetime.now(UTC).isoformat()}
            ).eq("push_token", token).execute()
        except Exception as e:
            log.error("delete_live_activity_token(%s) failed: %s", token[:8], e)

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

    def list_active_memories_for_sync(self, user_id: str) -> list[dict]:
        """Active memories that should be projected into Hermes files."""
        try:
            resp = (
                self._client.table("memories")
                .select("*")
                .eq("user_id", user_id)
                .eq("memory_status", "active")
                .order("updated_at", desc=True)
                .execute()
            )
            return resp.data or []
        except Exception as e:
            log.error("list_active_memories_for_sync(%s) failed: %s", user_id, e)
            return []

    def list_memories_for_extraction_context(self, user_id: str) -> list[dict]:
        """Existing non-deleted memories shown to the extractor for dedupe."""
        try:
            resp = (
                self._client.table("memories")
                .select("id, title, body, target, source, memory_status")
                .eq("user_id", user_id)
                .neq("memory_status", "deleted")
                .order("updated_at", desc=True)
                .limit(80)
                .execute()
            )
            return resp.data or []
        except Exception as e:
            log.error("list_memories_for_extraction_context(%s) failed: %s", user_id, e)
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

    def requeue_failed_memory_full(self, *, user_id: str | None = None) -> int:
        """Re-queue rows that failed only because Hermes memory was full."""
        try:
            q = (
                self._client.table("memories")
                .update({"sync_status": "pending", "sync_error": None})
                .eq("sync_status", "failed")
                .like("sync_error", "%memory is full%")
            )
            if user_id:
                q = q.eq("user_id", user_id)
            resp = q.execute()
            return len(resp.data or [])
        except Exception as e:
            log.error("requeue_failed_memory_full failed: %s", e)
            return 0

    def mark_memory_deleted(self, memory_id: str) -> None:
        """Soft-delete a memory so the next source-of-truth rewrite drops it."""
        try:
            self._client.table("memories").update(
                {
                    "memory_status": "deleted",
                    "sync_status": "pending",
                    "hermes_fingerprint": None,
                    "reviewed_at": datetime.now(UTC).isoformat(),
                }
            ).eq("id", memory_id).execute()
        except Exception as e:
            log.error("mark_memory_deleted(%s) failed: %s", memory_id, e)

    def upsert_extracted_memory(
        self,
        *,
        user_id: str,
        target: str,
        title: str,
        body: str,
        confidence: str,
        reason: str,
        source_todo_id: str,
        memory_status: str,
        symbol_name: str | None = None,
    ) -> None:
        """Insert or refresh a memory candidate from the post-task extractor."""
        try:
            existing = (
                self._client.table("memories")
                .select("id, title, body, target, source, memory_status")
                .eq("user_id", user_id)
                .eq("target", target)
                .neq("memory_status", "deleted")
                .limit(100)
                .execute()
            )
            rows = existing.data or []
            candidate = {"title": title, "body": body}
            duplicate = best_duplicate_memory(rows, candidate)
            title = title[:_TITLE_MAX]
            body = body[:2000]
            patch = {
                "title": title,
                "body": body,
                "target": target,
                "source": "doit",
                "memory_status": memory_status,
                "memory_confidence": confidence,
                "memory_reason": reason[:500] if reason else None,
                "source_todo_id": source_todo_id,
                "sync_status": "pending" if memory_status == "active" else "pending",
                "hermes_fingerprint": None,
                "sync_error": None,
                "symbol_name": resolve_memory_symbol(
                    symbol_name=symbol_name,
                    title=title,
                    body=body,
                ),
            }
            if duplicate is not None:
                if duplicate.get("source") == "user":
                    patch.pop("source", None)
                self._client.table("memories").update(patch).eq(
                    "id", duplicate["id"]
                ).execute()
                return
            row = {"user_id": user_id, "category": None, **patch}
            self._client.table("memories").insert(row).execute()
        except Exception as e:
            log.error(
                "upsert_extracted_memory(user=%s, target=%s, title=%r) failed: %s",
                user_id,
                target,
                title,
                e,
            )

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
        symbol_name = infer_memory_symbol(title, body)
        try:
            row = {
                "user_id": user_id,
                "title": title,
                "body": body,
                "category": None,
                "target": target,
                "source": "hermes",
                "memory_status": "active",
                "sync_status": "synced",
                "hermes_fingerprint": fingerprint,
                "last_sync_at": when_iso,
                "sync_error": None,
                "symbol_name": symbol_name,
            }
            existing = (
                self._client.table("memories")
                .select("id, source, title, body")
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
                row["symbol_name"] = infer_memory_symbol(title, body)
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
        topic: str | None = None,
        collection_name: str | None = None,
        preparation_summary: str | None = None,
        spawned_by_todo_id: str | None = None,
        status: str = "todo",
    ) -> dict | None:
        """Insert an already-prepared todo for multi-task splits.

        ``status`` defaults to ``todo`` so split-out rows wait for an
        explicit Do it tap. The parent row from the same `+` sheet
        submission auto-runs; extras inherit the parent's request context
        via ``original_title`` / ``detail`` and ``spawned_by_todo_id``.
        """
        return self.insert_spawned_todo(
            user_id=user_id,
            title=title,
            original_title=original_title,
            detail=detail,
            connection_slug=connection_slug,
            topic=topic,
            collection_name=collection_name,
            preparation_summary=preparation_summary,
            spawn_key=None,
            spawned_by_todo_id=spawned_by_todo_id,
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
        topic: str | None = None,
        collection_name: str | None = None,
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
        if topic:
            row["topic"] = topic
        if collection_name:
            row["collection_name"] = collection_name
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

    def claim_due_cron_jobs(
        self,
        *,
        limit: int = 3,
        exclude_user_ids: list[str] | None = None,
    ) -> list[dict]:
        """Return due cron jobs and mark them running (best-effort claim)."""
        now = datetime.now(UTC)
        now_iso = now.isoformat()
        try:
            query = (
                self._client.table("cron_jobs")
                .select("*")
                .eq("enabled", True)
                .eq("state", "scheduled")
                .lte("next_run_at", now_iso)
            )
            if exclude_user_ids:
                query = query.not_.in_("user_id", exclude_user_ids)
            resp = query.order("next_run_at").limit(limit).execute()
        except Exception as e:
            log.error("claim_due_cron_jobs select failed: %s", e)
            return []
        claimed: list[dict] = []
        for row in resp.data or []:
            job_id = row["id"]
            upd = (
                self._client.table("cron_jobs")
                .update({"state": "running", "run_claimed_at": _iso_z(now)})
                .eq("id", job_id)
                .eq("state", "scheduled")
                .execute()
            )
            if upd.data:
                claimed.append(upd.data[0])
        return claimed

    def claim_stale_running_cron_job(
        self,
        *,
        exclude_user_ids: list[str] | None = None,
    ) -> dict | None:
        """Recover one cron job stuck in ``running`` after a runner crash."""
        now = datetime.now(UTC)
        stale_before = _iso_z(now - _CLAIM_STALE_AFTER)
        try:
            query = (
                self._client.table("cron_jobs")
                .select("*")
                .eq("state", "running")
                .or_(f"run_claimed_at.is.null,run_claimed_at.lt.{stale_before}")
            )
            if exclude_user_ids:
                query = query.not_.in_("user_id", exclude_user_ids)
            resp = query.order("next_run_at").limit(1).execute()
            rows = resp.data or []
            if not rows:
                return None
            candidate = rows[0]
            upd = (
                self._client.table("cron_jobs")
                .update({"run_claimed_at": _iso_z(now)})
                .eq("id", candidate["id"])
                .eq("state", "running")
                .or_(f"run_claimed_at.is.null,run_claimed_at.lt.{stale_before}")
                .execute()
            )
            claimed = upd.data or []
            if claimed:
                log.warning(
                    "recovered stale running cron job %s (lease expired)",
                    candidate["id"],
                )
            return claimed[0] if claimed else None
        except Exception as e:
            log.error("claim_stale_running_cron_job failed: %s", e)
            return None

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
        stale_before = now - _CLAIM_STALE_AFTER
        try:
            resp = (
                self._client.table("cron_jobs")
                .select("*")
                .eq("state", "configuring")
                .order("updated_at")
                .limit(25)
                .execute()
            )
            rows = resp.data or []
            candidate = next(
                (row for row in rows if _cron_config_claimable(row, stale_before)),
                None,
            )
            if candidate is None:
                return None
            update = (
                self._client.table("cron_jobs")
                .update({"configure_claimed_at": now_iso})
                .eq("id", candidate["id"])
                .eq("state", "configuring")
            )
            claimed_raw = candidate.get("configure_claimed_at")
            if claimed_raw is None:
                update = update.is_("configure_claimed_at", "null")
            else:
                update = update.eq("configure_claimed_at", claimed_raw)
            upd = update.execute()
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
