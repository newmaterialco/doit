"""Tests for [[DOIT_TASKS]] parsing and spawn application."""
from __future__ import annotations

import unittest
from unittest.mock import MagicMock

from runner.events import (
    TASKS_CLOSE,
    TASKS_OPEN,
    parse_spawned_tasks,
    strip_tasks,
    translate,
)
from runner.spawn import apply_spawned_tasks


def wrap_tasks(json_body: str) -> str:
    return f"{TASKS_OPEN}\n{json_body}\n{TASKS_CLOSE}"


class ParseSpawnedTasksTests(unittest.TestCase):
    def test_parses_tasks_block(self) -> None:
        text = (
            "Scanned inbox.\n"
            + wrap_tasks(
                '{"tasks":[{"title":"Reply to Alex","source_key":"gmail:msg:1",'
                '"connection_slug":"gmail","summary":"Draft reply"}]}'
            )
        )
        tasks = parse_spawned_tasks(text)
        self.assertEqual(len(tasks), 1)
        self.assertEqual(tasks[0].title, "Reply to Alex")
        self.assertEqual(tasks[0].source_key, "gmail:msg:1")
        self.assertEqual(tasks[0].connection_slug, "gmail")
        self.assertEqual(tasks[0].summary, "Draft reply")

    def test_skips_incomplete_tasks(self) -> None:
        text = wrap_tasks(
            '{"tasks":[{"title":"No key"},{"source_key":"x"},{"title":"Ok",'
            '"source_key":"k1"}]}'
        )
        tasks = parse_spawned_tasks(text)
        self.assertEqual(len(tasks), 1)
        self.assertEqual(tasks[0].source_key, "k1")

    def test_strip_tasks_removes_block(self) -> None:
        text = "Done.\n" + wrap_tasks('{"tasks":[]}')
        self.assertNotIn(TASKS_OPEN, strip_tasks(text))
        self.assertIn("Done.", strip_tasks(text))

    def test_dedupes_same_title_even_with_different_source_keys(self) -> None:
        text = wrap_tasks(
            '{"tasks":['
            '{"title":"Review unread Gmail emails and propose next steps","source_key":"k1"},'
            '{"title":" Review  unread  Gmail emails and propose next steps ","source_key":"k2"}'
            ']}'
        )
        tasks = parse_spawned_tasks(text)
        self.assertEqual(len(tasks), 1)
        self.assertEqual(tasks[0].source_key, "k1")

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

    def test_translate_final_includes_spawned_tasks(self) -> None:
        body = (
            "Found one action.\n"
            + wrap_tasks(
                '{"tasks":[{"title":"Book flight","source_key":"email:42"}]}'
            )
        )
        effect = translate("response.completed", self._completed_event(body))
        self.assertIsNotNone(effect)
        assert effect is not None
        self.assertEqual(effect.new_status, "done")
        self.assertEqual(len(effect.spawned_tasks), 1)
        self.assertNotIn(TASKS_OPEN, effect.text)


class ApplySpawnedTasksTests(unittest.TestCase):
    def test_inserts_and_dedupes(self) -> None:
        from runner.events import SpawnedTaskRequest

        db = MagicMock()
        db.spawn_key_exists.return_value = False
        db.spawned_todo_title_exists.return_value = False
        db.insert_spawned_todo.side_effect = [
            {"id": "t1"},
            None,
        ]
        tasks = [
            SpawnedTaskRequest(title="A", source_key="k1"),
            SpawnedTaskRequest(title="B", source_key="k2"),
        ]
        db.spawn_key_exists.side_effect = [False, True]

        count = apply_spawned_tasks(
            db, "user-1", tasks, source_todo_id="parent-1"
        )
        self.assertEqual(count, 1)
        db.insert_spawned_todo.assert_called_once()
        call_kw = db.insert_spawned_todo.call_args.kwargs
        self.assertEqual(call_kw["spawned_by_todo_id"], "parent-1")
        self.assertEqual(call_kw["spawn_key"], "k1")

    def test_skips_existing_title_for_same_cron_source(self) -> None:
        from runner.events import SpawnedTaskRequest

        db = MagicMock()
        db.spawn_key_exists.return_value = False
        db.spawned_todo_title_exists.return_value = True

        count = apply_spawned_tasks(
            db,
            "user-1",
            [SpawnedTaskRequest(title="Reply to Alex", source_key="unstable-2")],
            source_cron_job_id="cron-1",
        )

        self.assertEqual(count, 0)
        db.spawned_todo_title_exists.assert_called_once_with(
            "user-1",
            "Reply to Alex",
            source_todo_id=None,
            source_cron_job_id="cron-1",
        )
        db.insert_spawned_todo.assert_not_called()


if __name__ == "__main__":
    unittest.main()
