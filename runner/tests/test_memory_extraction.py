from __future__ import annotations

import unittest

from runner.memory_extraction import (
    MEMORY_CLOSE,
    MEMORY_OPEN,
    build_memory_extraction_prompt,
    parse_memory_extraction,
)


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
        self.assertTrue(memories[0].should_auto_activate)

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
        self.assertFalse(memories[0].should_auto_activate)

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
        self.assertIn("medium-confidence suggested user memory", prompt)


if __name__ == "__main__":
    unittest.main()

