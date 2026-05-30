"""Focused tests for runner.events.parse_interaction.

These are pure-Python checks — no Supabase / Hermes / network needed. Run with:

    python -m unittest discover -s runner/tests -v

They lock in the contract between Hermes' final-text JSON block and the
todo_interactions rows the runner writes.
"""
from __future__ import annotations

import unittest

from runner.events import INTERACTION_CLOSE, INTERACTION_OPEN, parse_interaction


def wrap(json_body: str) -> str:
    return f"Here is what I drafted:\n{INTERACTION_OPEN}\n{json_body}\n{INTERACTION_CLOSE}"


class ParseInteractionTests(unittest.TestCase):
    def test_email_approval_round_trip(self) -> None:
        text = wrap(
            '{"kind":"approval","prompt":"Send this email?",'
            '"summary":"Draft to landlord","content":{"to":["lord@x.com"],'
            '"subject":"Late rent","body":"Hi…"},'
            '"options":[{"id":"send","label":"Send","style":"primary"},'
            '{"id":"rewrite","label":"Rewrite","style":"secondary"},'
            '{"id":"cancel","label":"Cancel","style":"destructive"}],'
            '"allow_freeform":true}'
        )
        result = parse_interaction(text)
        self.assertIsNotNone(result)
        assert result is not None  # for type narrowing
        self.assertEqual(result.kind, "approval")
        self.assertEqual(result.prompt, "Send this email?")
        self.assertEqual(result.payload["summary"], "Draft to landlord")
        self.assertEqual(
            result.payload["content"]["subject"], "Late rent"
        )
        self.assertEqual(
            [o["id"] for o in result.payload["options"]],
            ["send", "rewrite", "cancel"],
        )
        self.assertTrue(result.payload["allow_freeform"])

    def test_unknown_kind_falls_back_to_question(self) -> None:
        text = wrap('{"kind":"weird","prompt":"What?"}')
        result = parse_interaction(text)
        self.assertIsNotNone(result)
        assert result is not None
        self.assertEqual(result.kind, "question")

    def test_options_without_id_are_dropped(self) -> None:
        text = wrap(
            '{"kind":"choice","prompt":"Pick one",'
            '"options":[{"label":"missing id"},{"id":"a","label":"A"}]}'
        )
        result = parse_interaction(text)
        self.assertIsNotNone(result)
        assert result is not None
        self.assertEqual(result.payload["options"], [{"id": "a", "label": "A"}])

    def test_unknown_style_is_dropped_not_kept(self) -> None:
        text = wrap(
            '{"kind":"choice","prompt":"P",'
            '"options":[{"id":"a","label":"A","style":"weird"}]}'
        )
        result = parse_interaction(text)
        self.assertIsNotNone(result)
        assert result is not None
        self.assertEqual(result.payload["options"], [{"id": "a", "label": "A"}])

    def test_no_block_returns_none(self) -> None:
        self.assertIsNone(parse_interaction("Just a normal final reply."))
        self.assertIsNone(parse_interaction(""))

    def test_malformed_json_returns_none(self) -> None:
        text = wrap("{not valid json")
        self.assertIsNone(parse_interaction(text))

    def test_prompt_falls_back_to_summary(self) -> None:
        text = wrap('{"kind":"approval","summary":"Send the thing?"}')
        result = parse_interaction(text)
        self.assertIsNotNone(result)
        assert result is not None
        self.assertEqual(result.prompt, "Send the thing?")


if __name__ == "__main__":
    unittest.main()
