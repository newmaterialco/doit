"""Tests for the AgentActivityService snapshot derivation.

These exercises lock in the contract between Hermes SSE events (already
translated by `runner.events.translate`) and the `todo_agent_activity`
snapshot the runner upserts on every event. The iOS app drives the
todo-card status line, the detail-view animated card, and the Live
Activity widget off this snapshot, so the labels and phase transitions
here are user-visible.

Pure-Python — no Supabase / Hermes / network needed:

    python -m unittest discover -s runner/tests -v
"""
from __future__ import annotations

import unittest

from runner.activity import (
    AgentActivityService,
    _categorize_tool,
    _humanize_tool_name,
)
from runner.events import Translated


def _started(tool: str, text: str | None = None) -> Translated:
    body = text if text is not None else f"Using {tool}."
    return Translated(step_kind="tool_started", text=body, tool_name=tool)


def _result(tool: str, text: str | None = None) -> Translated:
    body = text if text is not None else "Tool completed."
    return Translated(step_kind="tool_result", text=body, tool_name=tool)


class HumanizeToolTests(unittest.TestCase):
    def test_humanize_gmail_search(self) -> None:
        self.assertEqual(_humanize_tool_name("gmail_search"), "Searching Gmail")

    def test_humanize_googlecalendar_create(self) -> None:
        # The verb heuristic only fires on the trailing token, so a name
        # like `googlecalendar_create_event` falls back to "Using ..." with
        # a prettified provider name. That's a fine status line; we lock
        # the actual output in so the iOS-side copy doesn't drift.
        self.assertEqual(
            _humanize_tool_name("googlecalendar_create_event"),
            "Using Google Calendar Create",
        )

    def test_humanize_text_to_speech(self) -> None:
        self.assertEqual(
            _humanize_tool_name("text_to_speech"),
            "Generating spoken summary",
        )

    def test_humanize_unknown_falls_back(self) -> None:
        self.assertEqual(_humanize_tool_name(None), "Running a tool")
        self.assertEqual(_humanize_tool_name(""), "Running a tool")

    def test_humanize_composio_prefix_stripped(self) -> None:
        # `composio_` prefixes are noise we drop before composing the label.
        self.assertEqual(
            _humanize_tool_name("composio_gmail_send"),
            "Sending Gmail",
        )


class CategorizeToolTests(unittest.TestCase):
    def test_gmail_categorized(self) -> None:
        self.assertEqual(_categorize_tool("gmail_search"), "gmail")

    def test_calendar_categorized(self) -> None:
        self.assertEqual(_categorize_tool("googlecalendar_create"), "calendar")

    def test_tts_categorized_as_audio(self) -> None:
        self.assertEqual(_categorize_tool("text_to_speech"), "audio")

    def test_unknown_categorized_as_unknown(self) -> None:
        self.assertEqual(_categorize_tool("mystery_tool"), "unknown")
        self.assertEqual(_categorize_tool(None), "unknown")


class AgentActivityServiceTests(unittest.TestCase):
    def test_initial_snapshot_is_running_starting(self) -> None:
        svc = AgentActivityService()
        snap = svc.initial(title="Starting agent…")
        self.assertEqual(snap.phase, "starting")
        self.assertEqual(snap.state, "running")
        self.assertEqual(snap.title, "Starting agent…")
        fields = snap.to_db_fields(hermes_run_id="run-1")
        self.assertEqual(fields["state"], "running")
        self.assertEqual(fields["hermes_run_id"], "run-1")
        self.assertEqual(fields["payload"]["steps"], [])

    def test_heartbeat_refreshes_latest_snapshot(self) -> None:
        svc = AgentActivityService()
        latest = svc.observe(_started("gmail_search", text="Using gmail_search. q=foo"))
        assert latest is not None

        snap = svc.heartbeat(latest)

        self.assertEqual(snap.phase, latest.phase)
        self.assertEqual(snap.state, "running")
        self.assertEqual(snap.title, "Searching Gmail")
        self.assertEqual(snap.detail, "q=foo")
        self.assertEqual(snap.tool_name, "gmail_search")
        self.assertEqual(snap.tool_category, "gmail")

    def test_heartbeat_without_snapshot_uses_neutral_status(self) -> None:
        svc = AgentActivityService()

        snap = svc.heartbeat()

        self.assertEqual(snap.phase, "thinking")
        self.assertEqual(snap.state, "running")
        self.assertEqual(snap.title, "Still working")
        self.assertEqual(snap.detail, "Still working on this")
        self.assertEqual(snap.tool_category, "thinking")

    def test_tool_started_then_tool_result_flow(self) -> None:
        svc = AgentActivityService()
        snap = svc.observe(_started("gmail_search", text="Using gmail_search. q=foo"))
        self.assertIsNotNone(snap)
        assert snap is not None
        self.assertEqual(snap.phase, "tool")
        self.assertEqual(snap.state, "running")
        self.assertEqual(snap.title, "Searching Gmail")
        self.assertEqual(snap.tool_name, "gmail_search")
        self.assertEqual(snap.tool_category, "gmail")
        self.assertEqual(snap.detail, "q=foo")
        self.assertEqual(len(snap.recent), 1)

        result_snap = svc.observe(_result("gmail_search"))
        assert result_snap is not None
        self.assertEqual(result_snap.phase, "tool_done")
        self.assertEqual(result_snap.state, "running")
        # The matching recent step should be completed now.
        completed = [s for s in result_snap.recent if s.completed_at is not None]
        self.assertEqual(len(completed), 1)

    def test_tool_issue_stays_running_not_failed(self) -> None:
        svc = AgentActivityService()
        snap = svc.observe(
            Translated(
                step_kind="tool_result",
                text="Tool hit an issue. (1.2s)",
                tool_name="web_search",
            )
        )
        assert snap is not None
        self.assertEqual(snap.state, "running")
        self.assertEqual(snap.phase, "tool_done")
        self.assertEqual(snap.tool_category, "search")
        self.assertIn("hit an issue", snap.title)

    def test_thought_event_collapses_to_thinking(self) -> None:
        svc = AgentActivityService()
        snap = svc.observe(
            Translated(step_kind="thought", text="I should search the inbox first.")
        )
        assert snap is not None
        self.assertEqual(snap.phase, "thinking")
        self.assertEqual(snap.title, "Thinking")
        self.assertEqual(snap.tool_category, "thinking")

    def test_thought_with_interaction_marker_is_dropped(self) -> None:
        svc = AgentActivityService()
        snap = svc.observe(
            Translated(step_kind="thought", text="[[DOIT_INTERACTION]] stuff [[/DOIT_INTERACTION]]")
        )
        self.assertIsNone(snap)

    def test_oauth_needed_is_paused(self) -> None:
        svc = AgentActivityService()
        snap = svc.observe(
            Translated(
                step_kind="oauth_needed",
                text="Connect an account to continue.",
                tool_name="composio_manage_connections",
            )
        )
        assert snap is not None
        self.assertEqual(snap.phase, "needs_auth")
        self.assertEqual(snap.state, "paused")

    def test_input_needed_is_paused(self) -> None:
        svc = AgentActivityService()
        snap = svc.observe(
            Translated(step_kind="input_needed", text="Should I send the email?")
        )
        assert snap is not None
        self.assertEqual(snap.phase, "needs_input")
        self.assertEqual(snap.state, "paused")
        self.assertEqual(snap.title, "Needs your input")

    def test_final_marks_completed(self) -> None:
        svc = AgentActivityService()
        snap = svc.observe(Translated(step_kind="final", text="All done!"))
        assert snap is not None
        self.assertEqual(snap.phase, "final")
        self.assertEqual(snap.state, "completed")
        self.assertIsNotNone(snap.completed_at)

    def test_error_marks_failed(self) -> None:
        svc = AgentActivityService()
        snap = svc.observe(Translated(step_kind="error", text="Hermes timed out"))
        assert snap is not None
        self.assertEqual(snap.phase, "failed")
        self.assertEqual(snap.state, "failed")
        self.assertEqual(snap.detail, "Hermes timed out")

    def test_unknown_event_is_noop(self) -> None:
        svc = AgentActivityService()
        # Translated with no step_kind/text is a translator no-op; the
        # activity service should match it.
        self.assertIsNone(svc.observe(None))
        snap = svc.observe(Translated())
        # Translated() defaults all fields to None — step_kind is None too,
        # so the service ignores it.
        self.assertIsNone(snap)

    def test_recent_steps_capped_at_8(self) -> None:
        svc = AgentActivityService()
        for i in range(20):
            svc.observe(_started(f"tool_{i}", text=f"call {i}"))
        # Drain through a thought to make sure capping still works on
        # mixed events.
        snap = svc.observe(Translated(step_kind="thought", text="step"))
        assert snap is not None
        self.assertLessEqual(len(snap.recent), 8)

    def test_consecutive_duplicate_thoughts_collapse(self) -> None:
        svc = AgentActivityService()
        svc.observe(Translated(step_kind="thought", text="Still thinking."))
        snap = svc.observe(Translated(step_kind="thought", text="Still thinking."))
        assert snap is not None
        self.assertEqual(len(snap.recent), 1)

    def test_mark_terminal_writes_completed_at_for_terminal_states(self) -> None:
        svc = AgentActivityService()
        snap = svc.mark_terminal(state="completed", title="Done")
        self.assertEqual(snap.state, "completed")
        self.assertIsNotNone(snap.completed_at)
        # Paused doesn't get a completed_at — the run might resume.
        paused = svc.mark_terminal(state="paused", title="Waiting on you", phase="needs_input")
        self.assertEqual(paused.state, "paused")
        self.assertIsNone(paused.completed_at)

    def test_to_db_fields_clears_completed_at_for_non_terminal_states(self) -> None:
        svc = AgentActivityService()
        paused = svc.mark_terminal(state="paused", title="Waiting on you", phase="needs_input")
        fields = paused.to_db_fields(hermes_run_id="run-1")
        self.assertIn("completed_at", fields)
        self.assertIsNone(fields["completed_at"])

    def test_to_db_fields_clips_oversized_title(self) -> None:
        long = "x" * 500
        svc = AgentActivityService()
        snap = svc.mark_terminal(state="completed", title=long)
        fields = snap.to_db_fields(hermes_run_id=None)
        self.assertLessEqual(len(fields["title"]), 200)


if __name__ == "__main__":
    unittest.main()
