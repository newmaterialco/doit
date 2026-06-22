"""Tests for _consume_run terminal handling on abnormal stream ends.

Locks in the silent-"Done." fix: when the SSE stream ends without a
terminal event after tool work and with no deliverable, the todo must be
marked failed (so the user can retry) instead of silently succeeding.

Pure stdlib + fakes — no Supabase / Hermes / network.
"""
from __future__ import annotations

import unittest
from types import SimpleNamespace
from typing import Any


class _FakeRunnerDB:
    """Captures the DB writes _consume_run makes."""

    def __init__(self) -> None:
        self.steps: list[dict[str, Any]] = []
        self.todo_updates: list[dict[str, Any]] = []
        self.activity: list[dict[str, Any]] = []
        self.interactions: list[dict[str, Any]] = []
        self.superseded: list[str] = []
        self.token_increments: list[int] = []
        self.artifacts: list[dict[str, Any]] = []

    def insert_step(self, *, todo_id, user_id, kind, text=None, url=None, tool_name=None):
        self.steps.append({"kind": kind, "text": text, "tool_name": tool_name})

    def update_todo(self, todo_id, fields):
        self.todo_updates.append(dict(fields))

    def upsert_agent_activity(self, *, todo_id, user_id, fields):
        self.activity.append(dict(fields))

    def supersede_open_interactions(self, todo_id):
        self.superseded.append(todo_id)

    def insert_interaction(self, **kwargs):
        self.interactions.append(kwargs)

    def increment_todo_tokens(self, todo_id, total):
        self.token_increments.append(total)

    def upsert_artifact(self, **kwargs):
        self.artifacts.append(kwargs)

    def list_todo_artifacts_for_context(self, todo_id):
        return [
            {
                "artifact_key": row.get("key"),
                "kind": row.get("kind"),
                "title": row.get("title"),
                "payload": row.get("payload") or {},
            }
            for row in self.artifacts
        ]

    def list_apns_tokens(self, user_id):
        return []


class _FakePusher:
    async def send(self, tokens, payload):
        return None

    async def send_activity_sync(self, tokens, *, todo_id):
        return None


class _FakeHermes:
    def __init__(
        self,
        events: list[tuple[str, dict]],
        repair_reply: str | None = None,
    ) -> None:
        self._events = events
        self._repair_reply = repair_reply
        self.started_runs: list[str] = []
        self.stopped_runs: list[str] = []

    async def stream_events(self, run_id: str):
        if run_id == "repair-run-1":
            if self._repair_reply is not None:
                name, data = _final_response(self._repair_reply)
                yield SimpleNamespace(event=name, data=data)
            return
        for name, data in self._events:
            yield SimpleNamespace(event=name, data=data)

    async def start_run(self, prompt, session_id=None, session_key=None, instructions=None):
        self.started_runs.append(prompt)
        return "repair-run-1"

    async def stop_run(self, run_id: str) -> None:
        self.stopped_runs.append(run_id)

    async def get_run(self, run_id: str) -> dict:
        return {}


def _tool_started(name: str = "GMAIL_FETCH_EMAILS", preview: str | None = None) -> tuple[str, dict]:
    data: dict = {"event": "tool.started", "tool": name}
    if preview is not None:
        data["preview"] = preview
    return ("tool.started", data)


def _tool_completed(name: str = "GMAIL_FETCH_EMAILS", output: Any | None = None) -> tuple[str, dict]:
    data = {"event": "tool.completed", "tool": name}
    if output is not None:
        data["output"] = output
    return ("tool.completed", data)


def _final_response(text: str) -> tuple[str, dict]:
    return (
        "response.completed",
        {
            "event": "response.completed",
            "response": {
                "output": [
                    {
                        "type": "message",
                        "content": [{"type": "output_text", "text": text}],
                    }
                ]
            },
        },
    )


_TODO = {"id": "todo-1", "user_id": "user-1"}
_CFG = SimpleNamespace(hermes_profiles_dir="/tmp/doit-test-profiles")


async def _run(
    events: list[tuple[str, dict]],
    db: _FakeRunnerDB,
    *,
    hermes: _FakeHermes | None = None,
    todo: dict | None = None,
    outbound_send_approved: bool = False,
) -> str:
    from runner.runner import _consume_run

    return await _consume_run(
        _CFG,  # type: ignore[arg-type]
        db,  # type: ignore[arg-type]
        _FakePusher(),  # type: ignore[arg-type]
        hermes or _FakeHermes(events),  # type: ignore[arg-type]
        todo or _TODO,
        "run-1",
        profile_name="test",
        outbound_send_approved=outbound_send_approved,
    )


class SilentDoneFixTests(unittest.IsolatedAsyncioTestCase):
    async def test_tool_run_with_no_terminal_or_deliverable_fails(self) -> None:
        db = _FakeRunnerDB()
        terminal = await _run([_tool_started(), _tool_completed()], db)

        self.assertEqual(terminal, "failed")
        statuses = [u.get("status") for u in db.todo_updates]
        self.assertIn("failed", statuses)
        self.assertNotIn("done", statuses)
        error_steps = [s for s in db.steps if s["kind"] == "error"]
        self.assertEqual(len(error_steps), 1)
        self.assertIn("stopped before finishing", error_steps[0]["text"])

    async def test_quiet_stream_without_tool_work_still_completes(self) -> None:
        # No tool calls at all (trivial run): keep the legacy lenient
        # behavior so a quiet stream end doesn't strand the todo.
        db = _FakeRunnerDB()
        terminal = await _run([], db)

        self.assertEqual(terminal, "done")
        statuses = [u.get("status") for u in db.todo_updates]
        self.assertIn("done", statuses)
        final_steps = [s for s in db.steps if s["kind"] == "final"]
        self.assertEqual(final_steps[-1]["text"], "Done.")

    async def test_normal_final_reply_still_completes(self) -> None:
        db = _FakeRunnerDB()
        terminal = await _run(
            [
                _tool_started(),
                _tool_completed(),
                _final_response("All done — sent the email."),
            ],
            db,
        )

        self.assertEqual(terminal, "done")
        statuses = [u.get("status") for u in db.todo_updates]
        self.assertIn("done", statuses)
        self.assertNotIn("failed", statuses)
        final_steps = [s for s in db.steps if s["kind"] == "final"]
        self.assertEqual(len(final_steps), 1)
        self.assertIn("sent the email", final_steps[0]["text"])

    async def test_late_tool_events_after_done_do_not_reopen_activity(self) -> None:
        db = _FakeRunnerDB()
        terminal = await _run(
            [
                _tool_started(),
                _tool_completed(),
                _final_response("Done — created the page."),
                _tool_started("MCP_SEARCH"),
                _tool_completed("MCP_SEARCH"),
            ],
            db,
        )

        self.assertEqual(terminal, "done")
        terminal_indices = [
            i for i, row in enumerate(db.activity)
            if row.get("state") in {"completed", "failed", "paused"}
        ]
        self.assertTrue(terminal_indices)
        first_terminal = terminal_indices[0]
        late_running = [
            row for row in db.activity[first_terminal + 1:]
            if row.get("state") == "running"
        ]
        self.assertEqual(late_running, [])
        self.assertEqual(db.activity[first_terminal]["state"], "completed")

    async def test_tool_run_with_artifact_but_no_terminal_completes(self) -> None:
        # Deliverables landed mid-stream; a missing terminal event should
        # not erase a successful run.
        artifact_reply = (
            "Done — created the doc.\n"
            "[[DOIT_ARTIFACT]]\n"
            '{"key":"doc","type":"link","title":"Bugs doc",'
            '"payload":{"url":"https://docs.google.com/d/x","provider":"googledocs"}}\n'
            "[[/DOIT_ARTIFACT]]"
        )
        db = _FakeRunnerDB()
        terminal = await _run(
            [_tool_started(), _tool_completed(), _final_response(artifact_reply)],
            db,
        )

        self.assertEqual(terminal, "done")
        self.assertEqual(len(db.artifacts), 1)
        self.assertEqual(db.artifacts[0]["kind"], "link")

    async def test_github_url_tool_output_promotes_link_artifact(self) -> None:
        db = _FakeRunnerDB()
        terminal = await _run(
            [
                _tool_started("COMPOSIO_GITHUB_CREATE_REPOSITORY"),
                _tool_completed(
                    "COMPOSIO_GITHUB_CREATE_REPOSITORY",
                    '{"html_url":"https://github.com/gabrielmitchell/hello-gabe-website"}',
                ),
                _final_response("Done — created the repository."),
            ],
            db,
            todo={
                "id": "todo-1",
                "user_id": "user-1",
                "title": "Create a GitHub Pages website",
                "detail": "",
            },
        )

        self.assertEqual(terminal, "done")
        promoted = [a for a in db.artifacts if a["key"] == "github-repo"]
        self.assertEqual(len(promoted), 1)
        self.assertEqual(
            promoted[0]["payload"]["url"],
            "https://github.com/gabrielmitchell/hello-gabe-website",
        )


class BrowserFailureMessageTests(unittest.IsolatedAsyncioTestCase):
    async def test_run_failure_stores_friendly_browser_message(self) -> None:
        raw = "CDP WebSocket connect failed: HTTP error: 410 Gone"
        db = _FakeRunnerDB()
        terminal = await _run([("error", {"event": "error", "message": raw})], db)

        self.assertEqual(terminal, "failed")
        failed_updates = [u for u in db.todo_updates if u.get("status") == "failed"]
        self.assertEqual(len(failed_updates), 1)
        message = failed_updates[0]["error_message"]
        self.assertIn("browser session disconnected", message)
        self.assertIn("Try again", message)
        self.assertNotIn("CDP", message)
        self.assertEqual(db.steps[-1]["text"], raw)
        terminal_activity = db.activity[-1]
        self.assertEqual(terminal_activity["title"], "Browser disconnected")
        self.assertEqual(terminal_activity["detail"], raw)


class TimeoutMessageTests(unittest.TestCase):
    def test_timeout_message_is_actionable(self) -> None:
        from runner.runner import _timeout_user_message

        message = _timeout_user_message({"connection_slug": ""})
        self.assertIn("went too long", message)
        self.assertIn("Try again", message)
        self.assertNotEqual(message, "Timed out.")

    def test_timeout_message_mentions_connection_when_known(self) -> None:
        from runner.runner import _timeout_user_message

        message = _timeout_user_message({"connection_slug": "github"})
        self.assertIn("GitHub", message)
        self.assertIn("connected in Settings", message)


def _email_artifact_reply(to: str, body: str) -> str:
    return (
        "Sent the email.\n"
        "[[DOIT_ARTIFACT]]\n"
        '{"key":"email-1","type":"email","title":"Email to Sam",'
        f'"payload":{{"to":"{to}","subject":"Intro","body":"{body}"}}}}\n'
        "[[/DOIT_ARTIFACT]]"
    )


class OutboundSendGateTests(unittest.IsolatedAsyncioTestCase):
    """Runner blocks send/invite tools until the user approves on the card."""

    async def test_unauthorized_send_tool_halts_to_needs_input(self) -> None:
        db = _FakeRunnerDB()
        hermes = _FakeHermes(
            [_tool_started("GMAIL_SEND_EMAIL", preview="To: sam@acme.com\nHi")]
        )
        terminal = await _run([], db, hermes=hermes)

        self.assertEqual(terminal, "needs_input")
        self.assertEqual(hermes.stopped_runs, ["run-1"])
        self.assertEqual(len(db.interactions), 1)
        self.assertEqual(db.interactions[0]["kind"], "approval")
        self.assertIn("Review this draft before I send it", db.interactions[0]["prompt"])
        statuses = [u.get("status") for u in db.todo_updates]
        self.assertIn("needs_input", statuses)
        self.assertNotIn("done", statuses)

    async def test_approved_resume_allows_send_tool(self) -> None:
        events = [
            _tool_started("GMAIL_SEND_EMAIL"),
            _tool_completed("GMAIL_SEND_EMAIL"),
            _final_response("Sent the email."),
        ]
        db = _FakeRunnerDB()
        terminal = await _run(
            events, db, outbound_send_approved=True
        )

        self.assertEqual(terminal, "done")
        self.assertEqual(db.interactions, [])

    async def test_send_after_tool_result_still_blocks_done(self) -> None:
        # If tool_started was missed, tool_result must still prevent done.
        events = [
            _tool_completed("GMAIL_SEND_EMAIL"),
            _final_response("Sent the email."),
        ]
        db = _FakeRunnerDB()
        terminal = await _run(events, db)

        self.assertEqual(terminal, "needs_input")
        self.assertEqual(len(db.interactions), 1)


class PlaceholderGateTests(unittest.IsolatedAsyncioTestCase):
    """Phase 4b: placeholder content in outbound drafts blocks `done`."""

    async def test_log_only_by_default_still_completes(self) -> None:
        import os
        from unittest import mock

        db = _FakeRunnerDB()
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("DOIT_PLACEHOLDER_GATE", None)
            terminal = await _run(
                [_final_response(_email_artifact_reply("john@example.com", "Hi"))],
                db,
            )

        self.assertEqual(terminal, "done")
        statuses = [u.get("status") for u in db.todo_updates]
        self.assertIn("done", statuses)
        self.assertEqual(db.interactions, [])

    async def test_enforced_gate_converts_done_to_needs_input(self) -> None:
        import os
        from unittest import mock

        db = _FakeRunnerDB()
        with mock.patch.dict(os.environ, {"DOIT_PLACEHOLDER_GATE": "1"}):
            terminal = await _run(
                [
                    _final_response(
                        _email_artifact_reply("john@example.com", "lorem ipsum")
                    )
                ],
                db,
            )

        self.assertEqual(terminal, "needs_input")
        statuses = [u.get("status") for u in db.todo_updates]
        self.assertIn("needs_input", statuses)
        self.assertNotIn("done", statuses)
        self.assertEqual(len(db.interactions), 1)
        interaction = db.interactions[0]
        self.assertEqual(interaction["kind"], "question")
        self.assertIn("placeholder", interaction["prompt"])
        # The artifact draft is still persisted so the user can see what
        # the agent produced.
        self.assertEqual(len(db.artifacts), 1)

    async def test_enforced_gate_lets_clean_drafts_complete(self) -> None:
        import os
        from unittest import mock

        db = _FakeRunnerDB()
        with mock.patch.dict(os.environ, {"DOIT_PLACEHOLDER_GATE": "1"}):
            terminal = await _run(
                [
                    _final_response(
                        _email_artifact_reply(
                            "sam@acme-corp.io", "Hi Sam, following up on Tuesday."
                        )
                    )
                ],
                db,
            )

        self.assertEqual(terminal, "done")
        statuses = [u.get("status") for u in db.todo_updates]
        self.assertIn("done", statuses)
        self.assertEqual(db.interactions, [])


_EMAIL_TODO = {
    "id": "todo-1",
    "user_id": "user-1",
    "title": "Send an email to Sam about the offsite",
}

_REPAIR_ARTIFACT_REPLY = (
    "[[DOIT_ARTIFACT]]\n"
    '{"key":"email-1","type":"email","title":"Email sent",'
    '"payload":{"to":"sam@acme-corp.io","subject":"Offsite","body":"Hi Sam"}}\n'
    "[[/DOIT_ARTIFACT]]"
)

_REPAIR_INTERACTION_REPLY = (
    "[[DOIT_INTERACTION]]\n"
    '{"kind":"approval","prompt":"Send this email to Sam?",'
    '"payload":{"content":"Hi Sam, offsite details..."}}\n'
    "[[/DOIT_INTERACTION]]"
)


class StructuredRepairTests(unittest.IsolatedAsyncioTestCase):
    """Phase 2c: one cheap repair turn when structured blocks went missing."""

    def _email_done_events(self) -> list[tuple[str, dict]]:
        # Email task that "completes" with plain text and no artifact or
        # interaction — use draft tool (not send) so the outbound-send gate
        # does not interfere with structured-repair tests.
        return [
            _tool_started("GMAIL_CREATE_DRAFT"),
            _tool_completed("GMAIL_CREATE_DRAFT"),
            _final_response("Drafted the email to Sam."),
        ]

    async def test_disabled_by_default_no_repair_run(self) -> None:
        import os
        from unittest import mock

        events = self._email_done_events()
        hermes = _FakeHermes(events, repair_reply=_REPAIR_ARTIFACT_REPLY)
        db = _FakeRunnerDB()
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("DOIT_STRUCTURED_REPAIR", None)
            terminal = await _run(events, db, hermes=hermes, todo=_EMAIL_TODO)

        self.assertEqual(terminal, "done")
        self.assertEqual(hermes.started_runs, [])
        self.assertEqual(db.artifacts, [])

    async def test_repair_recovers_missing_artifact(self) -> None:
        import os
        from unittest import mock

        events = self._email_done_events()
        hermes = _FakeHermes(events, repair_reply=_REPAIR_ARTIFACT_REPLY)
        db = _FakeRunnerDB()
        with mock.patch.dict(os.environ, {"DOIT_STRUCTURED_REPAIR": "1"}):
            terminal = await _run(events, db, hermes=hermes, todo=_EMAIL_TODO)

        self.assertEqual(terminal, "done")
        self.assertEqual(len(hermes.started_runs), 1)
        self.assertIn("Re-emit ONLY", hermes.started_runs[0])
        self.assertEqual(len(db.artifacts), 1)
        self.assertEqual(db.artifacts[0]["kind"], "email")
        repair_steps = [
            s for s in db.steps if s["text"] and "repair_attempted" in s["text"]
        ]
        self.assertEqual(len(repair_steps), 1)

    async def test_repair_interaction_pauses_for_input(self) -> None:
        import os
        from unittest import mock

        events = self._email_done_events()
        hermes = _FakeHermes(events, repair_reply=_REPAIR_INTERACTION_REPLY)
        db = _FakeRunnerDB()
        with mock.patch.dict(os.environ, {"DOIT_STRUCTURED_REPAIR": "1"}):
            terminal = await _run(events, db, hermes=hermes, todo=_EMAIL_TODO)

        self.assertEqual(terminal, "needs_input")
        self.assertEqual(len(db.interactions), 1)
        self.assertEqual(db.interactions[0]["kind"], "approval")
        statuses = [u.get("status") for u in db.todo_updates]
        self.assertEqual(statuses[-1], "needs_input")

    async def test_non_structured_task_not_repaired(self) -> None:
        import os
        from unittest import mock

        events = [
            _tool_started("GITHUB_LIST_REPOS"),
            _tool_completed("GITHUB_LIST_REPOS"),
            _final_response("You have 3 repos: a, b, c."),
        ]
        todo = {"id": "todo-1", "user_id": "user-1", "title": "List my repos"}
        hermes = _FakeHermes(events, repair_reply=_REPAIR_ARTIFACT_REPLY)
        db = _FakeRunnerDB()
        with mock.patch.dict(os.environ, {"DOIT_STRUCTURED_REPAIR": "1"}):
            terminal = await _run(events, db, hermes=hermes, todo=todo)

        self.assertEqual(terminal, "done")
        self.assertEqual(hermes.started_runs, [])

    async def test_run_with_artifact_skips_repair(self) -> None:
        import os
        from unittest import mock

        events = [
            _tool_started("GMAIL_CREATE_DRAFT"),
            _tool_completed("GMAIL_CREATE_DRAFT"),
            _final_response(
                _email_artifact_reply("sam@acme-corp.io", "Hi Sam, see you there.")
            ),
        ]
        hermes = _FakeHermes(events, repair_reply=_REPAIR_ARTIFACT_REPLY)
        db = _FakeRunnerDB()
        with mock.patch.dict(os.environ, {"DOIT_STRUCTURED_REPAIR": "1"}):
            terminal = await _run(events, db, hermes=hermes, todo=_EMAIL_TODO)

        self.assertEqual(terminal, "done")
        self.assertEqual(hermes.started_runs, [])
        self.assertEqual(len(db.artifacts), 1)


if __name__ == "__main__":
    unittest.main()
