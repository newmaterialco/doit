"""Focused tests for runner.events.parse_interaction.

These are pure-Python checks — no Supabase / Hermes / network needed. Run with:

    python -m unittest discover -s runner/tests -v

They lock in the contract between Hermes' final-text JSON block and the
todo_interactions rows the runner writes.
"""
from __future__ import annotations

import unittest

from runner.events import (
    ACTIVITY_CLOSE,
    ACTIVITY_OPEN,
    INTERACTION_CLOSE,
    INTERACTION_OPEN,
    extract_usage_total,
    find_placeholder_matches,
    is_outbound_send_tool,
    looks_like_placeholder,
    outbound_send_approved_from_resume,
    parse_activity,
    parse_interaction,
    parse_public_reasoning,
    strip_activity,
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


class OutboundSendGateTests(unittest.TestCase):
    def test_send_email_tools_are_outbound(self) -> None:
        self.assertTrue(is_outbound_send_tool("GMAIL_SEND_EMAIL"))
        self.assertTrue(is_outbound_send_tool("gmail_send_message"))

    def test_draft_tools_are_not_outbound(self) -> None:
        self.assertFalse(is_outbound_send_tool("GMAIL_CREATE_DRAFT"))
        self.assertFalse(is_outbound_send_tool("GMAIL_FETCH_EMAILS"))

    def test_calendar_create_is_outbound(self) -> None:
        self.assertTrue(is_outbound_send_tool("GOOGLECALENDAR_CREATE_EVENT"))

    def test_approved_resume_detection(self) -> None:
        self.assertTrue(
            outbound_send_approved_from_resume(
                {
                    "kind": "approval",
                    "response": {"option_id": "send"},
                }
            )
        )
        self.assertFalse(
            outbound_send_approved_from_resume(
                {
                    "kind": "approval",
                    "response": {"option_id": "edit"},
                }
            )
        )
        self.assertFalse(outbound_send_approved_from_resume(None))


class HermesToolProgressTests(unittest.TestCase):
    def test_browser_progress_preserves_action_details(self) -> None:
        effect = translate(
            "hermes.tool.progress",
            {
                "event": "hermes.tool.progress",
                "tool": "browser_navigate",
                "message": "Loading tee times",
                "url": "https://example.com/tee-times",
                "status": "loading",
            },
        )

        self.assertIsNotNone(effect)
        assert effect is not None
        self.assertEqual(effect.step_kind, "tool_started")
        self.assertEqual(effect.tool_name, "browser_navigate")
        self.assertIn("Loading tee times", effect.text or "")
        self.assertIn("url=https://example.com/tee-times", effect.text or "")
        self.assertIn("status=loading", effect.text or "")


class PlaceholderDetectorTests(unittest.TestCase):
    """Phase 4a: catch fake content in drafts before it ships."""

    def test_flags_common_placeholder_patterns(self) -> None:
        for text in (
            "Send to john@example.com",
            "Reach me at test@test.com",
            "[placeholder] for the agenda",
            "Lorem ipsum dolor sit amet",
            "Dear John Doe,",
            "Your Name Here",
            "Call 123-456-7890",
            "Hi [insert name],",
            "Hello {{first_name}}",
            "Subject: TODO write this",
            "Budget: TBD",
        ):
            with self.subTest(text=text):
                self.assertTrue(looks_like_placeholder(text))

    def test_normal_content_passes(self) -> None:
        for text in (
            "Hi Sam, following up on our call Tuesday.",
            "Send to sam@acme-corp.io",
            "Your tasks and todos are listed below.",  # lowercase "todo" ok
            "",
        ):
            with self.subTest(text=text):
                self.assertFalse(looks_like_placeholder(text))

    def test_lowercase_todo_is_not_flagged(self) -> None:
        # The product is literally about todos; only uppercase TODO/TBD
        # markers count as placeholders.
        self.assertFalse(looks_like_placeholder("added it to your todo list"))
        self.assertTrue(looks_like_placeholder("TODO: fill in"))

    def test_find_matches_walks_nested_payloads(self) -> None:
        payload = {
            "to": "john@example.com",
            "subject": "Intro",
            "body": "Hi Jane Doe, lorem ipsum.",
            "cc": ["real.person@acme-corp.io"],
            "meta": {"note": "looks fine"},
        }
        matches = find_placeholder_matches(payload)
        lowered = [m.lower() for m in matches]
        self.assertTrue(any("example." in m for m in lowered))
        self.assertTrue(any("jane doe" in m for m in lowered))
        self.assertTrue(any("lorem" in m for m in lowered))

    def test_find_matches_dedupes_and_handles_clean_payloads(self) -> None:
        payload = {"a": "john@example.com", "b": "another john@example.com"}
        matches = find_placeholder_matches(payload)
        self.assertEqual(len(matches), 1)
        self.assertEqual(find_placeholder_matches({"to": "sam@acme-corp.io"}), [])
        self.assertEqual(find_placeholder_matches(None), [])


class OptionSynthesisTests(unittest.TestCase):
    """Runner-side default buttons when a model omits the options array."""

    def test_approval_without_options_gets_default_buttons(self) -> None:
        text = wrap('{"kind":"approval","prompt":"Send this email?"}')
        result = parse_interaction(text)
        assert result is not None
        self.assertEqual(result.kind, "approval")
        self.assertEqual(
            [(o["id"], o["style"]) for o in result.payload["options"]],
            [("send", "primary"), ("edit", "secondary"), ("cancel", "destructive")],
        )

    def test_confirmation_without_options_gets_yes_no(self) -> None:
        text = wrap('{"kind":"confirmation","prompt":"Delete the event?"}')
        result = parse_interaction(text)
        assert result is not None
        self.assertEqual(result.kind, "confirmation")
        self.assertEqual(
            [(o["id"], o["style"]) for o in result.payload["options"]],
            [("yes", "primary"), ("no", "secondary")],
        )

    def test_choice_without_options_degrades_to_freeform_question(self) -> None:
        text = wrap('{"kind":"choice","prompt":"Which one?"}')
        result = parse_interaction(text)
        assert result is not None
        self.assertEqual(result.kind, "question")
        self.assertNotIn("options", result.payload)
        self.assertTrue(result.payload["allow_freeform"])

    def test_choice_with_all_invalid_options_degrades_to_freeform(self) -> None:
        # Options present but all dropped during cleaning — same as missing.
        text = wrap(
            '{"kind":"choice","prompt":"Pick one",'
            '"options":[{"label":"no id"},{"label":"also no id"}]}'
        )
        result = parse_interaction(text)
        assert result is not None
        self.assertEqual(result.kind, "question")
        self.assertNotIn("options", result.payload)
        self.assertTrue(result.payload["allow_freeform"])

    def test_existing_options_are_never_replaced(self) -> None:
        text = wrap(
            '{"kind":"approval","prompt":"Send?",'
            '"options":[{"id":"go","label":"Go","style":"primary"}]}'
        )
        result = parse_interaction(text)
        assert result is not None
        self.assertEqual(result.payload["options"], [
            {"id": "go", "label": "Go", "style": "primary"},
        ])

    def test_question_without_options_is_untouched(self) -> None:
        text = wrap('{"kind":"question","prompt":"What city?"}')
        result = parse_interaction(text)
        assert result is not None
        self.assertEqual(result.kind, "question")
        self.assertNotIn("options", result.payload)


class PublicActivityTests(unittest.TestCase):
    def test_parse_activity_extracts_short_public_copy(self) -> None:
        text = f"{ACTIVITY_OPEN}Reading the GitHub repo docs{ACTIVITY_CLOSE}"
        self.assertEqual(parse_activity(text), "Reading the GitHub repo docs")

    def test_parse_activity_rejects_missing_block(self) -> None:
        self.assertIsNone(parse_activity("Reading files"))

    def test_parse_public_reasoning_extracts_first_status_sentence(self) -> None:
        text = "Looking through the Figma file now. Then I will pick the screen."
        self.assertEqual(
            parse_public_reasoning(text),
            "Looking through the Figma file now.",
        )

    def test_parse_public_reasoning_rejects_tool_noise(self) -> None:
        self.assertIsNone(parse_public_reasoning("Tool completed. (0.2s)"))
        self.assertIsNone(parse_public_reasoning("frompath=/tmp/foo topath=/tmp/bar"))
        self.assertIsNone(parse_public_reasoning('{"call_id": "abc", "output": "..."}'))

    def test_strip_activity_removes_block_from_visible_text(self) -> None:
        text = (
            f"{ACTIVITY_OPEN}Reading files{ACTIVITY_CLOSE}\n\n"
            "Done — I updated the repo."
        )
        self.assertEqual(strip_activity(text).strip(), "Done — I updated the repo.")

    def test_reasoning_activity_becomes_thought(self) -> None:
        result = translate(
            "reasoning.available",
            {
                "event": "reasoning.available",
                "text": f"{ACTIVITY_OPEN}Preparing the PR summary{ACTIVITY_CLOSE}",
            },
        )
        self.assertIsNotNone(result)
        assert result is not None
        self.assertEqual(result.step_kind, "thought")
        self.assertEqual(result.text, "Preparing the PR summary")

    def test_reasoning_available_without_marker_becomes_thought(self) -> None:
        result = translate(
            "reasoning.available",
            {
                "event": "reasoning.available",
                "text": "Reviewing the selected mobile screen before editing.",
            },
        )
        self.assertIsNotNone(result)
        assert result is not None
        self.assertEqual(result.step_kind, "thought")
        self.assertEqual(result.text, "Reviewing the selected mobile screen before editing.")

    def test_reasoning_available_noise_is_dropped(self) -> None:
        result = translate(
            "reasoning.available",
            {
                "event": "reasoning.available",
                "text": "tool_call_id=call_1 stdout=README.md",
            },
        )
        self.assertIsNone(result)

    def test_final_reply_activity_marker_is_not_visible(self) -> None:
        result = translate(
            "run.completed",
            {
                "event": "run.completed",
                "output": (
                    f"{ACTIVITY_OPEN}Wrapping up{ACTIVITY_CLOSE}\n\n"
                    "Done — I updated the rules."
                ),
            },
        )
        self.assertIsNotNone(result)
        assert result is not None
        self.assertEqual(result.step_kind, "final")
        self.assertEqual(result.text, "Done — I updated the rules.")

    def test_final_reply_with_connection_link_pauses_for_oauth(self) -> None:
        result = translate(
            "run.completed",
            {
                "event": "run.completed",
                "output": (
                    "Please connect your Gmail account: "
                    "https://connect.composio.dev/link/abc123"
                ),
            },
        )
        self.assertIsNotNone(result)
        assert result is not None
        self.assertEqual(result.step_kind, "oauth_needed")
        self.assertEqual(result.new_status, "needs_auth")
        self.assertEqual(result.url, "https://connect.composio.dev/link/abc123")


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
