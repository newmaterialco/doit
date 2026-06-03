"""Focused tests for runner.events.parse_artifacts + strip_artifacts.

These are pure-Python checks — no Supabase / Hermes / network needed. Run with:

    python -m unittest discover -s runner/tests -v

They lock in the contract between the agent's `[[DOIT_ARTIFACT]]` blocks and
the `todo_artifacts` rows the runner upserts: parsing every block, stripping
them out of the chat-visible final reply, and yielding to interactions when
both markers show up in the same reply.
"""
from __future__ import annotations

import unittest

from runner.events import (
    ARTIFACT_CLOSE,
    ARTIFACT_OPEN,
    INTERACTION_CLOSE,
    INTERACTION_OPEN,
    collapse_done_leadins,
    merge_terminal_translated,
    normalize_visible_reply,
    parse_artifacts,
    strip_artifacts,
    translate,
)


def wrap(json_body: str) -> str:
    return f"{ARTIFACT_OPEN}\n{json_body}\n{ARTIFACT_CLOSE}"


class ParseArtifactsTests(unittest.TestCase):
    def test_single_link_artifact(self) -> None:
        text = (
            "Here is the sheet you asked for.\n"
            + wrap(
                '{"key":"sheet","type":"link","title":"Q2 Budget",'
                '"payload":{"url":"https://docs.google.com/spreadsheets/d/abc",'
                '"provider":"googlesheets"}}'
            )
        )
        result = parse_artifacts(text)
        self.assertEqual(len(result), 1)
        artifact = result[0]
        self.assertEqual(artifact.key, "sheet")
        self.assertEqual(artifact.kind, "link")
        self.assertEqual(artifact.title, "Q2 Budget")
        self.assertEqual(artifact.payload["provider"], "googlesheets")
        self.assertIn("spreadsheets", artifact.payload["url"])

    def test_multiple_blocks_in_one_reply(self) -> None:
        text = (
            "Created the doc and sent the invite.\n"
            + wrap(
                '{"key":"doc","type":"link","title":"Spec",'
                '"payload":{"url":"https://docs.google.com/document/d/xyz"}}'
            )
            + "\n"
            + wrap(
                '{"key":"invite","type":"calendar","title":"Kickoff",'
                '"payload":{"title":"Kickoff","start":"2025-06-01T15:00:00Z",'
                '"end":"2025-06-01T16:00:00Z","attendees":["a@b.com"],'
                '"url":"https://calendar.google.com/event?eid=abc"}}'
            )
        )
        result = parse_artifacts(text)
        self.assertEqual([a.key for a in result], ["doc", "invite"])
        self.assertEqual([a.kind for a in result], ["link", "calendar"])

    def test_key_defaults_to_kind_when_omitted(self) -> None:
        text = wrap('{"type":"text","payload":{"text":"hello"}}')
        result = parse_artifacts(text)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0].key, "text")

    def test_unknown_type_is_dropped(self) -> None:
        text = wrap('{"key":"weird","type":"video","payload":{"url":"x"}}')
        self.assertEqual(parse_artifacts(text), [])

    def test_malformed_json_is_skipped(self) -> None:
        # First block is unparseable; the second is fine. The good one
        # should still come through.
        text = (
            wrap('{"key":"bad","type":"link", "payload":{"url":"x"')
            + "\n"
            + wrap('{"key":"good","type":"text","payload":{"text":"ok"}}')
        )
        result = parse_artifacts(text)
        self.assertEqual([a.key for a in result], ["good"])

    def test_non_object_block_is_skipped(self) -> None:
        text = wrap("[1, 2, 3]")
        self.assertEqual(parse_artifacts(text), [])

    def test_duplicate_keys_collapse_with_later_winning(self) -> None:
        # Two blocks with the same `key` in one reply: the upsert in
        # `db.upsert_artifact` would clobber the earlier row anyway, so the
        # parser dedupes proactively and keeps the later value.
        text = (
            wrap(
                '{"key":"sheet","type":"link","title":"Draft",'
                '"payload":{"url":"https://x/draft"}}'
            )
            + "\n"
            + wrap(
                '{"key":"sheet","type":"link","title":"Final",'
                '"payload":{"url":"https://x/final"}}'
            )
        )
        result = parse_artifacts(text)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0].title, "Final")
        self.assertEqual(result[0].payload["url"], "https://x/final")

    def test_no_marker_returns_empty(self) -> None:
        self.assertEqual(parse_artifacts(""), [])
        self.assertEqual(parse_artifacts("no markers here"), [])


class StripArtifactsTests(unittest.TestCase):
    def test_removes_block_from_final_text(self) -> None:
        body = (
            "Here is your sheet:\n"
            + wrap(
                '{"key":"sheet","type":"link",'
                '"payload":{"url":"https://x"}}'
            )
            + "\nLet me know if you want changes."
        )
        stripped = strip_artifacts(body).strip()
        self.assertNotIn(ARTIFACT_OPEN, stripped)
        self.assertNotIn(ARTIFACT_CLOSE, stripped)
        self.assertNotIn("googlesheets", stripped)
        self.assertIn("Here is your sheet", stripped)
        self.assertIn("Let me know", stripped)

    def test_no_block_is_noop(self) -> None:
        body = "Just a normal reply."
        self.assertEqual(strip_artifacts(body), body)


class CollapseDoneLeadinsTests(unittest.TestCase):
    def test_merges_second_done_paragraph(self) -> None:
        body = (
            "Done — I created and verified the Google Doc here: https://example.com/doc\n\n"
            "Done — I made the one-pager focused on pricing and scope."
        )
        merged = collapse_done_leadins(body)
        self.assertEqual(merged.count("Done —"), 1)
        self.assertIn("pricing and scope", merged)
        self.assertIn("https://example.com/doc", merged)


class MergeTerminalTranslatedTests(unittest.TestCase):
    def test_combines_two_terminal_replies(self) -> None:
        first = translate(
            "response.completed",
            {
                "event": "response.completed",
                "response": {
                    "output": [
                        {
                            "type": "message",
                            "content": [
                                {
                                    "type": "output_text",
                                    "text": "Done — Doc ready: https://example.com/doc",
                                }
                            ],
                        }
                    ]
                },
            },
        )
        second = translate(
            "run.completed",
            {
                "event": "run.completed",
                "output": "Done — The doc covers pricing and pilot scope.",
            },
        )
        self.assertIsNotNone(first)
        self.assertIsNotNone(second)
        merged = merge_terminal_translated(first, second)  # type: ignore[arg-type]
        self.assertEqual(merged.step_kind, "final")
        self.assertEqual(merged.text.count("Done —"), 1)
        self.assertIn("pricing", merged.text)
        self.assertIn("https://example.com/doc", merged.text)


class NormalizeVisibleReplyTests(unittest.TestCase):
    def test_collapses_blank_lines_after_artifact_strip(self) -> None:
        body = (
            "Done — links:\n"
            "Google Sheet: https://docs.google.com/spreadsheets/d/abc\n\n"
            + wrap(
                '{"key":"sheet","type":"link",'
                '"payload":{"url":"https://docs.google.com/spreadsheets/d/abc"}}'
            )
            + "\n\n\n"
            + wrap(
                '{"key":"doc","type":"link",'
                '"payload":{"url":"https://docs.google.com/document/d/xyz"}}'
            )
            + "\n\n\nClosing paragraph."
        )
        visible = normalize_visible_reply(strip_artifacts(body))
        self.assertNotIn("\n\n\n", visible)
        self.assertIn("Closing paragraph.", visible)
        self.assertIn("Google Sheet:", visible)


class TranslateFinalArtifactTests(unittest.TestCase):
    """End-to-end: `translate` on a `response.completed` event should
    attach artifacts to the Translated effect and clean them out of the
    visible step text."""

    def _completed_event(self, text: str) -> dict:
        return {
            "event": "response.completed",
            "response": {
                "output": [
                    {
                        "type": "message",
                        "content": [{"type": "output_text", "text": text}],
                    }
                ]
            },
        }

    def test_final_with_artifact_attaches_and_strips(self) -> None:
        body = (
            "Sent it.\n"
            + wrap(
                '{"key":"email","type":"email","title":"Late rent",'
                '"payload":{"to":["lord@x.com"],"subject":"Late rent",'
                '"body":"Hi…"}}'
            )
        )
        effect = translate("response.completed", self._completed_event(body))
        self.assertIsNotNone(effect)
        assert effect is not None
        self.assertEqual(effect.new_status, "done")
        self.assertEqual(effect.step_kind, "final")
        self.assertEqual(len(effect.artifacts), 1)
        self.assertEqual(effect.artifacts[0].kind, "email")
        # The chat-visible text should not contain the raw block.
        assert effect.text is not None
        self.assertNotIn(ARTIFACT_OPEN, effect.text)
        self.assertIn("Sent it", effect.text)

    def test_interaction_block_wins_over_artifact_in_same_reply(self) -> None:
        body = (
            f"{INTERACTION_OPEN}\n"
            '{"kind":"approval","prompt":"Send this?",'
            '"content":{"subject":"x","body":"y"}}'
            f"\n{INTERACTION_CLOSE}\n"
            + wrap(
                '{"key":"draft","type":"text",'
                '"payload":{"text":"ignored until user replies"}}'
            )
        )
        effect = translate("response.completed", self._completed_event(body))
        self.assertIsNotNone(effect)
        assert effect is not None
        self.assertEqual(effect.new_status, "needs_input")
        self.assertEqual(effect.step_kind, "input_needed")
        self.assertIsNotNone(effect.interaction)
        # When pausing for input, artifacts are skipped — the agent is
        # expected to re-emit them with its actual final reply later.
        self.assertEqual(effect.artifacts, [])

    def test_final_without_artifact_has_empty_list(self) -> None:
        effect = translate(
            "response.completed", self._completed_event("All done!")
        )
        self.assertIsNotNone(effect)
        assert effect is not None
        self.assertEqual(effect.new_status, "done")
        self.assertEqual(effect.artifacts, [])


if __name__ == "__main__":
    unittest.main()
