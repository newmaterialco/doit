"""Tests for the per-todo Hermes session id + simplified todo prompt.

These guard the contract that lets Hermes' built-in memory actually update
between todos:

    * Every todo gets its OWN session id, so USER.md / MEMORY.md are
      reloaded as a fresh frozen snapshot each run. (Hermes' docs are
      explicit that the snapshot is captured once at session start and
      never refreshed mid-session.)
    * Cross-todo continuity comes from ``session_search`` (FTS5 over
      state.db) and the per-profile memory files, not from a shared
      session_id.
    * A stable per-user ``session_key`` is what scopes long-term memory
      providers for one Doit user even though the session_id rotates.
    * Per-todo input no longer re-injects the user's memories — Hermes
      loads them from USER.md / MEMORY.md at session start.
    * Image attachments survive the runner -> prompt -> Hermes input pipeline.

Pure stdlib — no Supabase / Hermes / network.
"""
from __future__ import annotations

import unittest
from typing import Any

from runner.prompt import (
    build_prompt as _build_prompt,
    build_resume_prompt as _build_resume_prompt,
    prep_session_id_for_todo as _prep_session_id_for_todo,
    session_id_for_todo as _session_id_for_todo,
    session_key_for_user as _session_key_for_user,
)


class SessionIdTests(unittest.TestCase):
    def test_same_todo_resolves_to_same_session_id(self) -> None:
        user_id = "11111111-1111-1111-1111-111111111111"
        todo_id = "abcdef00-0000-0000-0000-000000000000"
        self.assertEqual(
            _session_id_for_todo(user_id, todo_id),
            _session_id_for_todo(user_id, todo_id),
        )

    def test_different_todos_get_different_session_ids(self) -> None:
        user_id = "11111111-1111-1111-1111-111111111111"
        self.assertNotEqual(
            _session_id_for_todo(user_id, "todo-a"),
            _session_id_for_todo(user_id, "todo-b"),
        )

    def test_per_todo_session_lets_memory_snapshot_refresh(self) -> None:
        # The whole reason we rotate session_id per todo is that Hermes
        # freezes MEMORY.md / USER.md at session start. Two todos in a row
        # must get different ids so the second one reloads memory.
        self.assertNotEqual(
            _session_id_for_todo("u", "todo-a"),
            _session_id_for_todo("u", "todo-b"),
        )

    def test_session_id_is_prefixed_for_easy_grepping(self) -> None:
        self.assertTrue(
            _session_id_for_todo("u", "t1").startswith("doit-todo-"),
            "session ids should be identifiable in Hermes session lists",
        )

    def test_prep_session_is_separate_from_main_session(self) -> None:
        # Preparation runs with a strict no-tools system prompt; sharing
        # the execution session id would pollute that turn's transcript.
        todo_id = "todo-xyz"
        self.assertNotEqual(
            _prep_session_id_for_todo(todo_id),
            _session_id_for_todo("u", todo_id),
        )
        self.assertTrue(
            _prep_session_id_for_todo(todo_id).startswith("doit-prep-"),
        )

    def test_session_key_is_stable_per_user(self) -> None:
        # X-Hermes-Session-Key is the scoping handle for an eventual
        # external memory provider. It MUST stay stable per user even
        # though we rotate session_id per todo.
        user_id = "11111111-1111-1111-1111-111111111111"
        self.assertEqual(
            _session_key_for_user(user_id),
            _session_key_for_user(user_id),
        )
        self.assertNotEqual(
            _session_key_for_user("user-a"),
            _session_key_for_user("user-b"),
        )


class PromptBuilderTests(unittest.TestCase):
    def test_prompt_marks_each_request_as_a_new_todo(self) -> None:
        prompt = _build_prompt("Send a test email", "")
        # Stable session means task boundaries have to come from the prompt.
        self.assertTrue(prompt.startswith("New todo task:"))
        self.assertIn("Send a test email", prompt)
        self.assertIn("Original user request:", prompt)

    def test_prompt_does_not_enumerate_existing_user_memories(self) -> None:
        # The whole point of leaning on Hermes native memory: a normal
        # per-todo prompt should not enumerate the user's facts (Hermes'
        # frozen snapshot already does that).
        prompt = _build_prompt("Buy groceries", "milk + eggs")
        self.assertNotIn("Visible user memories", prompt)
        self.assertNotIn("User-pinned memories", prompt)
        self.assertIn("milk + eggs", prompt)

    def test_pinned_memories_surface_as_curation_nudge(self) -> None:
        # When the runner just wrote a new user-pinned entry into USER.md /
        # MEMORY.md, the prompt should ask the agent to confirm/consolidate
        # it via the memory tool instead of letting the file write be the
        # only signal. This is Phase 4 of the Hermes memory roadmap.
        prompt = _build_prompt(
            "Send Gabe a quick hello",
            "",
            pinned_memories=[
                {
                    "target": "user",
                    "title": "Personal email",
                    "body": "gabe@example.com",
                },
                {
                    "target": "memory",
                    "title": "Notion home",
                    "body": "doit.notion.so/home",
                },
            ],
        )
        self.assertIn("User-pinned memories", prompt)
        self.assertIn("memory` tool", prompt)
        self.assertIn("target=user", prompt)
        self.assertIn("target=memory", prompt)
        self.assertIn("gabe@example.com", prompt)
        self.assertIn("doit.notion.so/home", prompt)

    def test_no_pinned_memories_means_no_curation_block(self) -> None:
        # Don't add an empty "User-pinned memories" block on every turn —
        # it would be noise and could confuse the agent into hallucinating
        # entries.
        prompt = _build_prompt("Send Gabe a quick hello", "", pinned_memories=[])
        self.assertNotIn("User-pinned memories", prompt)

    def test_prompt_keeps_original_request_as_source_of_truth(self) -> None:
        prompt = _build_prompt(
            "Send a test email",
            "",
            original_title="Send a test email to gabemitchell93@gmail.com",
            preparation_summary="Send a simple test email.",
            connection_slug="gmail",
        )
        self.assertIn("source of truth", prompt)
        self.assertIn("Send a test email to gabemitchell93@gmail.com", prompt)
        self.assertIn("Prepared title:\nSend a test email", prompt)
        self.assertIn("Preparation summary:\nSend a simple test email.", prompt)
        self.assertIn("Expected connection/toolkit:\ngmail", prompt)

    def test_resume_prompt_includes_user_response(self) -> None:
        prompt = _build_resume_prompt(
            title="Send a test email",
            detail="",
            original_title="Send a test email to gabe@test.com",
            interaction={
                "prompt": "Send this draft?",
                "payload": {
                    "options": [
                        {"id": "send", "label": "Send"},
                        {"id": "cancel", "label": "Cancel"},
                    ],
                },
                "response": {"option_id": "send", "text": ""},
            },
        )
        self.assertIn("Send this draft?", prompt)
        self.assertIn("Send", prompt)
        self.assertIn("option_id=send", prompt)
        self.assertIn("Send a test email to gabe@test.com", prompt)
        self.assertTrue(prompt.startswith("New todo task:"))


class _FakeAttachmentDB:
    """Minimal stand-in for runner.db.DB for attachment-resolution tests.

    Returns rows in insertion order. ``sign_attachment_url`` formats a
    deterministic signed URL so tests can assert against it without standing
    up Supabase Storage.
    """

    def __init__(self, rows: list[dict[str, Any]]) -> None:
        self._rows = rows

    def list_todo_attachments(self, todo_id: str) -> list[dict[str, Any]]:
        return [r for r in self._rows if r.get("todo_id") == todo_id]

    def sign_attachment_url(self, storage_path: str, **_: Any) -> str | None:
        if storage_path.endswith(".broken"):
            return None
        return f"https://signed.test/{storage_path}?token=abc"


class RunnerAttachmentPipelineTests(unittest.TestCase):
    """The runner is supposed to look up attachment rows, sign each path,
    and pass the signed URLs into the prompt builder. We exercise both ends
    of that handoff with a fake DB.
    """

    def test_resolve_returns_signed_urls_in_order(self) -> None:
        from runner.runner import _resolve_attachment_urls  # late import

        db = _FakeAttachmentDB(
            [
                {"todo_id": "T1", "storage_path": "u/T1/a.jpg"},
                {"todo_id": "T1", "storage_path": "u/T1/b.jpg"},
                {"todo_id": "T2", "storage_path": "u/T2/x.jpg"},
            ]
        )
        urls = _resolve_attachment_urls(db, "T1")
        self.assertEqual(
            urls,
            [
                "https://signed.test/u/T1/a.jpg?token=abc",
                "https://signed.test/u/T1/b.jpg?token=abc",
            ],
        )

    def test_resolve_drops_rows_that_fail_to_sign(self) -> None:
        from runner.runner import _resolve_attachment_urls

        db = _FakeAttachmentDB(
            [
                {"todo_id": "T1", "storage_path": "u/T1/a.jpg"},
                {"todo_id": "T1", "storage_path": "u/T1/missing.broken"},
            ]
        )
        urls = _resolve_attachment_urls(db, "T1")
        self.assertEqual(urls, ["https://signed.test/u/T1/a.jpg?token=abc"])

    def test_resolved_urls_appear_in_hermes_input(self) -> None:
        from runner.runner import _resolve_attachment_urls

        db = _FakeAttachmentDB(
            [{"todo_id": "T1", "storage_path": "u/T1/a.jpg"}]
        )
        urls = _resolve_attachment_urls(db, "T1")
        prompt = _build_prompt("Look at this", "", attachment_urls=urls)
        self.assertIn("Attachments (images):", prompt)
        self.assertIn("https://signed.test/u/T1/a.jpg?token=abc", prompt)
        self.assertIn("vision_analyze", prompt)


if __name__ == "__main__":
    unittest.main()
