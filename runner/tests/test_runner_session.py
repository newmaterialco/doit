"""Tests for the per-user Hermes session id + simplified todo prompt.

These guard the contract that lets Hermes' built-in memory + session_search
actually span every todo for one user:

    * Every todo for the same user shares one Hermes session id.
    * Different users get different session ids.
    * Per-todo input no longer re-injects the user's memories — Hermes loads
      them from USER.md/MEMORY.md at session start.

Pure stdlib — no Supabase / Hermes / network.
"""
from __future__ import annotations

import unittest

from runner.prompt import (
    build_prompt as _build_prompt,
    build_resume_prompt as _build_resume_prompt,
    prep_session_id_for_user as _prep_session_id_for_user,
    session_id_for_user as _session_id_for_user,
)


class SessionIdTests(unittest.TestCase):
    def test_same_user_two_todos_share_session(self) -> None:
        user_id = "11111111-1111-1111-1111-111111111111"
        self.assertEqual(
            _session_id_for_user(user_id),
            _session_id_for_user(user_id),
        )

    def test_different_users_get_different_sessions(self) -> None:
        self.assertNotEqual(
            _session_id_for_user("user-a"),
            _session_id_for_user("user-b"),
        )

    def test_session_id_is_prefixed_for_easy_grepping(self) -> None:
        self.assertTrue(
            _session_id_for_user("abc").startswith("doit-user-"),
            "session ids should be identifiable in Hermes session lists",
        )

    def test_prep_session_is_separate_from_main_session(self) -> None:
        # Preparation runs with a strict no-tools system prompt; sharing the
        # main user session would pollute its conversation history. Memory
        # is still per-profile so the prep session still sees user facts.
        user = "abc"
        self.assertNotEqual(
            _prep_session_id_for_user(user),
            _session_id_for_user(user),
        )
        self.assertTrue(
            _prep_session_id_for_user(user).startswith("doit-prep-user-"),
        )


class PromptBuilderTests(unittest.TestCase):
    def test_prompt_marks_each_request_as_a_new_todo(self) -> None:
        prompt = _build_prompt("Send a test email", "")
        # Stable session means task boundaries have to come from the prompt.
        self.assertTrue(prompt.startswith("New todo task:"))
        self.assertIn("Send a test email", prompt)

    def test_prompt_does_not_inject_user_memories(self) -> None:
        # The whole point of leaning on Hermes native memory: per-todo input
        # should not enumerate the user's facts (Hermes' frozen snapshot
        # already does that).
        prompt = _build_prompt("Buy groceries", "milk + eggs")
        self.assertNotIn("Visible user memories", prompt)
        self.assertIn("milk + eggs", prompt)

    def test_resume_prompt_includes_user_response(self) -> None:
        prompt = _build_resume_prompt(
            title="Send a test email",
            detail="",
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
        self.assertTrue(prompt.startswith("New todo task:"))


if __name__ == "__main__":
    unittest.main()
