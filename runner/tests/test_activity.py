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
    execution_start_snapshot,
    prep_queue_snapshot,
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

    def test_browser_tools_categorized(self) -> None:
        self.assertEqual(_categorize_tool("browser_navigate"), "browser")
        self.assertEqual(_categorize_tool("browser_snapshot"), "browser")

    def test_browse_terminal_call_categorized_as_browser(self) -> None:
        self.assertEqual(
            _categorize_tool("terminal", "Using terminal. browse open https://example.com --remote"),
            "browser",
        )

    def test_browse_skill_terminal_call_categorized_as_browser(self) -> None:
        self.assertEqual(
            _categorize_tool("terminal", "Using terminal. browse skills find flights"),
            "browser",
        )
        self.assertEqual(
            _categorize_tool(
                "terminal",
                "Using terminal. python3 /opt/doit/hermes/scripts/sync_browse_skill.py --query flights",
            ),
            "browser",
        )

    def test_skill_tools_categorized_as_search(self) -> None:
        self.assertEqual(_categorize_tool("skills_list"), "search")
        self.assertEqual(_categorize_tool("skill_view"), "search")

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
        self.assertEqual(snap.detail, "Starting agent…")
        self.assertEqual(snap.tool_category, "thinking")
        fields = snap.to_db_fields(hermes_run_id="run-1")
        self.assertEqual(fields["state"], "running")
        self.assertEqual(fields["hermes_run_id"], "run-1")
        self.assertEqual(fields["payload"]["steps"], [])

    def test_initial_snapshot_clears_stale_paused_question_payload(self) -> None:
        paused_service = AgentActivityService()
        paused = paused_service.observe(
            Translated(step_kind="input_needed", text="Which screen should I update?")
        )
        assert paused is not None
        self.assertEqual(len(paused.to_db_fields(hermes_run_id="run-1")["payload"]["steps"]), 1)

        resumed_service = AgentActivityService()
        fresh = resumed_service.initial(title="Starting agent…")
        fields = fresh.to_db_fields(hermes_run_id="run-2")

        self.assertEqual(fields["state"], "running")
        self.assertEqual(fields["phase"], "starting")
        self.assertIsNone(fields["completed_at"])
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

    def test_browser_tool_started_has_browser_label(self) -> None:
        svc = AgentActivityService()
        snap = svc.observe(_started("browser_navigate", text="Using browser_navigate. url=https://example.com"))
        assert snap is not None
        self.assertEqual(snap.title, "Browsing the web")
        self.assertEqual(snap.tool_category, "browser")
        self.assertEqual(snap.detail, "url=https://example.com")

    def test_terminal_browse_command_has_browser_label(self) -> None:
        svc = AgentActivityService()
        snap = svc.observe(
            _started(
                "terminal",
                text="Using terminal. browse open https://example.com --remote",
            )
        )
        assert snap is not None
        self.assertEqual(snap.title, "Browsing the web")
        self.assertEqual(snap.tool_category, "browser")

    def test_browse_skill_terminal_command_has_skill_label(self) -> None:
        svc = AgentActivityService()
        snap = svc.observe(
            _started(
                "terminal",
                text="Using terminal. browse skills find flights",
            )
        )
        assert snap is not None
        self.assertEqual(snap.title, "Finding browser skill")
        self.assertEqual(snap.tool_category, "browser")

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


class StalledSnapshotTests(unittest.TestCase):
    """Phase 3a/3c: distinct stalled phase when a run stops emitting events."""

    def test_stalled_without_context_uses_generic_copy(self) -> None:
        svc = AgentActivityService()
        snap = svc.stalled(None)
        self.assertEqual(snap.phase, "stalled")
        # The run is not over — state must stay running so iOS keeps the
        # live surfaces alive instead of showing a terminal card.
        self.assertEqual(snap.state, "running")
        self.assertIn("Still working", snap.title)
        self.assertIsNone(snap.completed_at)

    def test_stalled_keeps_last_known_tool_context(self) -> None:
        svc = AgentActivityService()
        latest = svc.observe(_started("GMAIL_SEARCH_EMAILS"))
        assert latest is not None
        snap = svc.stalled(latest)
        self.assertEqual(snap.phase, "stalled")
        self.assertEqual(snap.tool_name, "GMAIL_SEARCH_EMAILS")
        assert snap.detail is not None
        self.assertIn("Still on:", snap.detail)

    def test_stalled_differs_from_heartbeat_phase(self) -> None:
        svc = AgentActivityService()
        heartbeat = svc.heartbeat(None)
        stalled = svc.stalled(None)
        self.assertNotEqual(heartbeat.phase, stalled.phase)


class ExecutionStartSnapshotTests(unittest.TestCase):
    def test_first_run_uses_getting_ready(self) -> None:
        snap = execution_start_snapshot({"title": "Book a flight to NYC"})
        self.assertEqual(snap.phase, "starting")
        self.assertEqual(snap.title, "Getting ready…")
        self.assertEqual(snap.detail, "Getting ready…")
        self.assertNotIn("Book a flight", snap.title)
        self.assertNotIn("Book a flight", snap.detail or "")

    def test_pending_message_uses_reading_copy(self) -> None:
        snap = execution_start_snapshot(
            {"title": "Book a flight to NYC"},
            pending_messages=["Can you also add a hotel?"],
        )
        self.assertEqual(snap.title, "Reading your message…")
        self.assertNotIn("Book a flight", snap.detail or "")

    def test_resume_uses_picking_up_copy(self) -> None:
        snap = execution_start_snapshot(
            {"title": "Book a flight to NYC"},
            resumed_from_interaction=True,
        )
        self.assertEqual(snap.title, "Picking up your answer…")
        self.assertNotIn("Book a flight", snap.detail or "")

    def test_prep_summary_does_not_echo_task_title(self) -> None:
        snap = execution_start_snapshot(
            {
                "title": "Book a flight to NYC",
                "preparation_summary": "Search SFO to JFK flights",
            }
        )
        self.assertEqual(snap.title, "Getting ready…")
        self.assertNotIn("Book a flight", snap.detail or "")
        self.assertNotIn("SFO", snap.title)


class PrepQueueSnapshotTests(unittest.TestCase):
    def test_queued_to_run_without_summary_echo(self) -> None:
        snap = prep_queue_snapshot(summary="Search SFO to JFK flights")
        self.assertEqual(snap.title, "Queued to run…")
        self.assertEqual(snap.detail, "Queued to run…")
        self.assertNotIn("SFO", snap.title)


class HeartbeatStartingEscalationTests(unittest.TestCase):
    def test_heartbeat_escalates_starting_without_steps(self) -> None:
        svc = AgentActivityService()
        starting = svc.initial(phase="starting", title="Getting ready…", detail=None)
        snap = svc.heartbeat(starting)
        self.assertEqual(snap.phase, "starting")
        self.assertEqual(snap.title, "Connecting…")

    def test_heartbeat_keeps_real_work_snapshot(self) -> None:
        svc = AgentActivityService()
        latest = svc.observe(_started("gmail_search", text="Using gmail_search. q=foo"))
        assert latest is not None
        snap = svc.heartbeat(latest)
        self.assertEqual(snap.title, "Searching Gmail")


if __name__ == "__main__":
    unittest.main()
