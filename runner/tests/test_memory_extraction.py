from __future__ import annotations

import unittest

from runner.memory_extraction import (
    MEMORY_CLOSE,
    MEMORY_OPEN,
    build_memory_extraction_prompt,
    parse_memory_extraction,
    storage_status_for_extracted_memory,
)


class MemoryModelOverrideTests(unittest.IsolatedAsyncioTestCase):
    """DOIT_MEMORY_MODEL: fixed cheap model for the extraction pass."""

    def test_unset_by_default(self) -> None:
        import os
        from unittest import mock

        from runner.runner import _memory_model_override

        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("DOIT_MEMORY_MODEL", None)
            self.assertIsNone(_memory_model_override())
        with mock.patch.dict(
            os.environ, {"DOIT_MEMORY_MODEL": "google/gemini-flash"}
        ):
            self.assertEqual(_memory_model_override(), "google/gemini-flash")
        with mock.patch.dict(os.environ, {"DOIT_MEMORY_MODEL": "  "}):
            self.assertIsNone(_memory_model_override())

    async def test_direct_call_without_api_keys_falls_back(self) -> None:
        import os
        from unittest import mock

        from runner.runner import _extract_memories_text_direct

        with mock.patch.dict(
            os.environ,
            {"OPENROUTER_API_KEY": "", "OPENAI_API_KEY": ""},
        ):
            result = await _extract_memories_text_direct(
                "prompt", model="google/gemini-flash"
            )
        # None → caller falls back to the Hermes-profile extraction run.
        self.assertIsNone(result)


class TrivialTodoSkipTests(unittest.TestCase):
    """Trivial read-only tasks skip the post-task memory extraction run."""

    def _todo(self, original: str, title: str | None = None, detail: str = "") -> dict:
        return {
            "id": "t1",
            "user_id": "u1",
            "original_title": original,
            "title": title or original,
            "detail": detail,
        }

    def test_list_query_is_trivial(self) -> None:
        from runner.runner import _is_trivial_readonly_todo

        self.assertTrue(
            _is_trivial_readonly_todo(
                self._todo("List the Github repos you have access to.")
            )
        )
        self.assertTrue(
            _is_trivial_readonly_todo(self._todo("What is on my calendar today?"))
        )
        self.assertTrue(
            _is_trivial_readonly_todo(self._todo("How many unread emails do I have"))
        )

    def test_mutating_tasks_are_not_trivial(self) -> None:
        from runner.runner import _is_trivial_readonly_todo

        self.assertFalse(
            _is_trivial_readonly_todo(self._todo("Send an email to John"))
        )
        self.assertFalse(
            _is_trivial_readonly_todo(
                self._todo("Check my inbox and draft replies to anything urgent")
            )
        )
        self.assertFalse(
            _is_trivial_readonly_todo(self._todo("Create a Google Doc for bugs"))
        )

    def test_long_research_tasks_are_not_trivial(self) -> None:
        from runner.runner import _is_trivial_readonly_todo

        self.assertFalse(
            _is_trivial_readonly_todo(
                self._todo(
                    "Check international moving companies for a July move from "
                    "San Francisco to London, compare at least four solid "
                    "options including cost, timeline, insurance coverage, and "
                    "reviews, and put everything in a spreadsheet I can share "
                    "with my partner so we can decide together"
                )
            )
        )

    def test_empty_todo_is_not_trivial(self) -> None:
        from runner.runner import _is_trivial_readonly_todo

        self.assertFalse(_is_trivial_readonly_todo(self._todo("")))


class MemoryExtractionTests(unittest.TestCase):
    def test_parse_extracts_high_confidence_preference(self) -> None:
        text = (
            f"{MEMORY_OPEN}\n"
            '{"memories":[{"target":"user","title":"Preferred signoff",'
            '"body":"User wants email signoffs to be Gabe.",'
            '"confidence":"high","reason":"User said change my signoff to Gabe."}]}'
            f"\n{MEMORY_CLOSE}"
        )
        memories = parse_memory_extraction(text)
        self.assertEqual(len(memories), 1)
        self.assertEqual(memories[0].target, "user")
        self.assertEqual(memories[0].confidence, "high")

    def test_parse_drops_invalid_and_duplicate_items(self) -> None:
        text = (
            f"{MEMORY_OPEN}\n"
            '{"memories":['
            '{"target":"user","title":"Tone","body":"User prefers concise drafts.",'
            '"confidence":"medium","reason":"preference"},'
            '{"target":"user","title":"Tone duplicate","body":" user prefers concise drafts. ",'
            '"confidence":"medium","reason":"duplicate"},'
            '{"target":"user","title":"","body":"missing title","confidence":"high"}'
            "]}"
            f"\n{MEMORY_CLOSE}"
        )
        memories = parse_memory_extraction(text)
        self.assertEqual(len(memories), 1)
        self.assertEqual(memories[0].confidence, "medium")

    def test_parse_shortens_repeated_title_body(self) -> None:
        text = (
            f"{MEMORY_OPEN}\n"
            '{"memories":[{"target":"user",'
            '"title":"User\\u0027s birthday: June 15, 1993.",'
            '"body":"User\\u0027s birthday: June 15, 1993.",'
            '"confidence":"high","reason":"The user shared their birthday."}]}'
            f"\n{MEMORY_CLOSE}"
        )
        memories = parse_memory_extraction(text)
        self.assertEqual(len(memories), 1)
        self.assertEqual(memories[0].title, "Birthday")
        self.assertEqual(memories[0].body, "User's birthday: June 15, 1993.")

    def test_prompt_calls_out_implicit_preference_changes(self) -> None:
        prompt = build_memory_extraction_prompt(
            todo={"title": "Change my signoff to Gabe", "id": "t1"},
            task_context={"messages": [], "steps": [], "artifacts": []},
            existing_memories=[],
        )
        self.assertIn("change my signoff to Gabe", prompt)
        self.assertIn("did not say remember", prompt)

    def test_prompt_calls_out_relationship_contact_clues(self) -> None:
        prompt = build_memory_extraction_prompt(
            todo={
                "title": "Send a test email to my wife Alessandra",
                "id": "t1",
            },
            task_context={
                "messages": [
                    {
                        "body": (
                            "Can you send a test email to my wife? Her name "
                            "is Alessandra and her email is a@example.com."
                        )
                    }
                ],
                "steps": [],
                "artifacts": [],
            },
            existing_memories=[],
        )
        self.assertIn("relationship/contact/work/life context", prompt)
        self.assertIn("my wife Alessandra", prompt)
        self.assertIn("medium-confidence user memory", prompt)

    def test_parse_extracts_symbol_name(self) -> None:
        text = (
            f"{MEMORY_OPEN}\n"
            '{"memories":[{"target":"user","title":"Flight preferences",'
            '"body":"Prefers aisle seats on long flights.",'
            '"confidence":"medium","reason":"Travel preference.",'
            '"symbol_name":"airplane"}]}'
            f"\n{MEMORY_CLOSE}"
        )
        memories = parse_memory_extraction(text)
        self.assertEqual(len(memories), 1)
        self.assertEqual(memories[0].symbol_name, "airplane")

    def test_prompt_mentions_symbol_name(self) -> None:
        from runner.memory_extraction import MEMORY_EXTRACT_INSTRUCTIONS

        self.assertIn("symbol_name", MEMORY_EXTRACT_INSTRUCTIONS)
        self.assertIn("person.crop.circle", MEMORY_EXTRACT_INSTRUCTIONS)

    def test_medium_confidence_memory_stores_active(self) -> None:
        text = (
            f"{MEMORY_OPEN}\n"
            '{"memories":[{"target":"user","title":"Wife",'
            '"body":"User\\u0027s wife is Alessandra.",'
            '"confidence":"medium","reason":"Relationship clue from the task."}]}'
            f"\n{MEMORY_CLOSE}"
        )
        memories = parse_memory_extraction(text)
        self.assertEqual(len(memories), 1)
        self.assertEqual(memories[0].confidence, "medium")
        self.assertEqual(storage_status_for_extracted_memory(memories[0]), "active")


if __name__ == "__main__":
    unittest.main()

