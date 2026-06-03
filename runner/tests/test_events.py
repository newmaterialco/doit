"""Focused tests for runner.events.parse_interaction.

These are pure-Python checks — no Supabase / Hermes / network needed. Run with:

    python -m unittest discover -s runner/tests -v

They lock in the contract between Hermes' final-text JSON block and the
todo_interactions rows the runner writes.
"""
from __future__ import annotations

import unittest

from runner.events import (
    INTERACTION_CLOSE,
    INTERACTION_OPEN,
    extract_usage_total,
    parse_interaction,
    translate,
)


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


class ExtractUsageTotalTests(unittest.TestCase):
    """Hermes Runs API uses input/output/total_tokens; chat.completions
    uses prompt/completion_tokens. The helper accepts either shape."""

    def test_runs_api_shape(self) -> None:
        usage = {"input_tokens": 50, "output_tokens": 200, "total_tokens": 250}
        self.assertEqual(extract_usage_total(usage), 250)

    def test_chat_completions_shape(self) -> None:
        usage = {"prompt_tokens": 12, "completion_tokens": 34, "total_tokens": 46}
        self.assertEqual(extract_usage_total(usage), 46)

    def test_falls_back_to_sum_when_total_missing(self) -> None:
        usage = {"input_tokens": 50, "output_tokens": 200}
        self.assertEqual(extract_usage_total(usage), 250)

    def test_handles_none_and_empty(self) -> None:
        self.assertEqual(extract_usage_total(None), 0)
        self.assertEqual(extract_usage_total({}), 0)
        self.assertEqual(extract_usage_total("garbage"), 0)

    def test_negative_total_is_clamped_to_zero(self) -> None:
        # `total_tokens=-1` is nonsense; the helper rejects it and falls
        # through to the sum branch (which is 0 here).
        usage = {"total_tokens": -1}
        self.assertEqual(extract_usage_total(usage), 0)


class TranslateUsageTests(unittest.TestCase):
    """The translator should surface the per-event token total on
    `Translated.usage_total` so the runner can increment the DB without
    re-parsing event payloads itself."""

    def test_response_completed_carries_usage(self) -> None:
        data = {
            "event": "response.completed",
            "response": {
                "output": [
                    {
                        "type": "message",
                        "content": [{"type": "output_text", "text": "Done."}],
                    }
                ],
                "usage": {"input_tokens": 100, "output_tokens": 200, "total_tokens": 300},
            },
        }
        result = translate("response.completed", data)
        self.assertIsNotNone(result)
        assert result is not None
        self.assertEqual(result.usage_total, 300)

    def test_empty_response_completed_is_not_terminal(self) -> None:
        data = {
            "event": "response.completed",
            "response": {
                "output": [
                    {
                        "type": "function_call",
                        "name": "googlesheets_create_spreadsheet",
                    }
                ],
                "usage": {"total_tokens": 300},
            },
        }
        result = translate("response.completed", data)
        self.assertIsNotNone(result)
        assert result is not None
        self.assertIsNone(result.step_kind)
        self.assertIsNone(result.new_status)
        self.assertEqual(result.usage_total, 300)

    def test_run_completed_carries_usage(self) -> None:
        data = {
            "event": "run.completed",
            "output": "All done.",
            "usage": {"total_tokens": 1234},
        }
        result = translate("run.completed", data)
        self.assertIsNotNone(result)
        assert result is not None
        self.assertEqual(result.usage_total, 1234)

    def test_empty_run_completed_is_not_terminal(self) -> None:
        data = {
            "event": "run.completed",
            "output": "",
            "usage": {"total_tokens": 1234},
        }
        result = translate("run.completed", data)
        self.assertIsNotNone(result)
        assert result is not None
        self.assertIsNone(result.step_kind)
        self.assertIsNone(result.new_status)
        self.assertEqual(result.usage_total, 1234)

    def test_chat_completions_final_carries_usage(self) -> None:
        data = {
            "choices": [
                {"finish_reason": "stop", "message": {"content": "Hi."}}
            ],
            "usage": {"prompt_tokens": 10, "completion_tokens": 20, "total_tokens": 30},
        }
        result = translate("done", data)
        self.assertIsNotNone(result)
        assert result is not None
        self.assertEqual(result.usage_total, 30)

    def test_event_without_usage_defaults_to_zero(self) -> None:
        data = {"event": "tool.started", "tool": "search"}
        result = translate("tool.started", data)
        self.assertIsNotNone(result)
        assert result is not None
        self.assertEqual(result.usage_total, 0)


class TranslateFailureTests(unittest.TestCase):
    def test_tool_completed_error_is_recoverable_tool_result(self) -> None:
        result = translate(
            "tool.completed",
            {"event": "tool.completed", "tool": "web_search", "error": "timeout"},
        )
        self.assertIsNotNone(result)
        assert result is not None
        self.assertEqual(result.step_kind, "tool_result")
        self.assertIsNone(result.new_status)
        self.assertEqual(result.tool_name, "web_search")
        self.assertIn("issue", result.text or "")

    def test_run_failed_is_terminal_failure(self) -> None:
        result = translate(
            "run.failed",
            {"event": "run.failed", "error": "model crashed"},
        )
        self.assertIsNotNone(result)
        assert result is not None
        self.assertEqual(result.step_kind, "error")
        self.assertEqual(result.new_status, "failed")


class MemoryToolObservabilityTests(unittest.TestCase):
    """The activity log is how we prove Hermes is actually using its memory
    and session_search tools. The generic ``Using <tool>.`` text is too
    quiet for that diagnostic — we want a label a human can spot at a
    glance in the iOS run timeline.
    """

    def test_memory_tool_started_has_friendly_label(self) -> None:
        result = translate(
            "tool.started",
            {"event": "tool.started", "tool": "memory"},
        )
        self.assertIsNotNone(result)
        assert result is not None
        self.assertEqual(result.step_kind, "tool_started")
        self.assertIn("long-term memory", (result.text or "").lower())
        self.assertEqual(result.tool_name, "memory")

    def test_session_search_started_has_friendly_label(self) -> None:
        result = translate(
            "tool.started",
            {"event": "tool.started", "tool": "session_search"},
        )
        self.assertIsNotNone(result)
        assert result is not None
        self.assertEqual(result.step_kind, "tool_started")
        self.assertIn("past tasks", (result.text or "").lower())
        self.assertEqual(result.tool_name, "session_search")

    def test_memory_tool_completed_has_friendly_label(self) -> None:
        result = translate(
            "tool.completed",
            {"event": "tool.completed", "tool": "memory"},
        )
        self.assertIsNotNone(result)
        assert result is not None
        self.assertEqual(result.text, "Memory updated.")
        self.assertEqual(result.tool_name, "memory")

    def test_memory_tool_completed_error_has_friendly_label(self) -> None:
        result = translate(
            "tool.completed",
            {"event": "tool.completed", "tool": "memory", "error": "limit"},
        )
        self.assertIsNotNone(result)
        assert result is not None
        self.assertIn("Memory update failed", result.text or "")
        self.assertIsNone(result.new_status)  # not run-level failure

    def test_responses_api_memory_function_call_surfaces_action_and_text(self) -> None:
        result = translate(
            "response.output_item.added",
            {
                "event": "response.output_item.added",
                "item": {
                    "type": "function_call",
                    "name": "memory",
                    "call_id": "call-1",
                    "arguments": (
                        '{"action": "add", "target": "user",'
                        ' "text": "Personal email is gabe@example.com"}'
                    ),
                },
            },
        )
        self.assertIsNotNone(result)
        assert result is not None
        self.assertEqual(result.tool_name, "memory")
        self.assertIn("long-term memory", (result.text or "").lower())
        # The label includes the action and a snippet so a human reading
        # the activity log can tell what the agent saved.
        self.assertIn("add", (result.text or "").lower())
        self.assertIn("gabe@example.com", result.text or "")

    def test_responses_api_session_search_surfaces_query(self) -> None:
        result = translate(
            "response.output_item.added",
            {
                "event": "response.output_item.added",
                "item": {
                    "type": "function_call",
                    "name": "session_search",
                    "call_id": "call-2",
                    "arguments": '{"query": "personal email"}',
                },
            },
        )
        self.assertIsNotNone(result)
        assert result is not None
        self.assertEqual(result.tool_name, "session_search")
        self.assertIn("past tasks", (result.text or "").lower())
        self.assertIn("personal email", result.text or "")


if __name__ == "__main__":
    unittest.main()
