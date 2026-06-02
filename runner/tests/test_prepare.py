"""Tests for runner.prepare: the preparation-pass parser + prompt builder.

These lock in the contract between the model's preparation JSON block and
the rows the runner writes (rewritten title, connection slug, optional
clarification). Pure-Python — no Supabase / Hermes / network. Run with:

    python -m unittest discover -s tests -v
"""
from __future__ import annotations

import unittest

from runner.prepare import (
    CONNECTION_SLUGS,
    PREP_CLOSE,
    PREP_OPEN,
    augment_cron_from_text,
    build_prepare_prompt,
    infer_recurring_schedule,
    parse_prepare,
)


def wrap(json_body: str) -> str:
    return f"Some chatter we should ignore.\n{PREP_OPEN}\n{json_body}\n{PREP_CLOSE}"


class ParsePrepareTests(unittest.TestCase):
    def test_ready_with_known_slug(self) -> None:
        text = wrap(
            '{"title":"Send rent-late email to landlord",'
            '"connection_slug":"gmail",'
            '"summary":"Send one email to the landlord.",'
            '"ready":true}'
        )
        result = parse_prepare(text)
        self.assertIsNotNone(result)
        assert result is not None
        self.assertTrue(result.ready)
        self.assertFalse(result.needs_clarification)
        self.assertEqual(result.title, "Send rent-late email to landlord")
        self.assertEqual(result.connection_slug, "gmail")
        self.assertEqual(result.summary, "Send one email to the landlord.")

    def test_unknown_slug_is_dropped(self) -> None:
        text = wrap(
            '{"title":"x","connection_slug":"made_up_app","ready":true}'
        )
        result = parse_prepare(text)
        assert result is not None
        self.assertIsNone(result.connection_slug)

    def test_known_slug_is_lowercased(self) -> None:
        text = wrap('{"title":"x","connection_slug":"Gmail","ready":true}')
        result = parse_prepare(text)
        assert result is not None
        self.assertEqual(result.connection_slug, "gmail")

    def test_missing_ready_defaults_to_true(self) -> None:
        # Defensive: if the model leaves out `ready`, the safer interpretation
        # is "go ahead and let the user tap Do it" — not stuck on a question.
        text = wrap('{"title":"x","connection_slug":null}')
        result = parse_prepare(text)
        assert result is not None
        self.assertTrue(result.ready)

    def test_not_ready_without_prompt_is_promoted_to_ready(self) -> None:
        # Same defensive logic: if the model says not ready but forgets the
        # question, do not strand the user — flip it to ready.
        text = wrap(
            '{"title":"x","connection_slug":"gmail","ready":false,'
            '"clarification":{}}'
        )
        result = parse_prepare(text)
        assert result is not None
        self.assertTrue(result.ready)

    def test_clarification_with_options_roundtrips(self) -> None:
        text = wrap(
            '{"title":"Send invite","connection_slug":"googlecalendar",'
            '"ready":false,"clarification":{'
            '"prompt":"Who should I invite?",'
            '"options":[{"id":"team","label":"My team","style":"primary"},'
            '{"id":"cancel","label":"Cancel","style":"destructive"}],'
            '"allow_freeform":true,'
            '"freeform_placeholder":"Type names or emails"}}'
        )
        result = parse_prepare(text)
        assert result is not None
        self.assertFalse(result.ready)
        self.assertTrue(result.needs_clarification)
        self.assertEqual(result.clarification_prompt, "Who should I invite?")
        self.assertEqual(
            [o["id"] for o in result.clarification_options],
            ["team", "cancel"],
        )
        self.assertTrue(result.clarification_allow_freeform)
        self.assertEqual(result.clarification_placeholder, "Type names or emails")

    def test_no_block_returns_none(self) -> None:
        self.assertIsNone(parse_prepare("just chatter"))
        self.assertIsNone(parse_prepare(""))

    def test_malformed_json_returns_none(self) -> None:
        self.assertIsNone(parse_prepare(wrap("{not valid")))

    def test_known_slugs_include_expected_apps(self) -> None:
        # Guardrail: the slugs we expose must stay aligned with the iOS asset
        # catalog and the integrations Edge Function CATALOG. Drift here
        # would mean the card icon silently goes missing for popular apps.
        for expected in ("gmail", "googlecalendar", "slack", "notion"):
            self.assertIn(expected, CONNECTION_SLUGS)

    def test_cron_kind_roundtrips(self) -> None:
        text = wrap(
            '{"title":"Daily email check","connection_slug":"gmail",'
            '"summary":"Scan inbox and create tasks.",'
            '"kind":"cron","schedule":"0 9 * * *",'
            '"schedule_display":"Every day at 9:00 AM","ready":true}'
        )
        result = parse_prepare(text)
        assert result is not None
        self.assertTrue(result.is_cron)
        self.assertEqual(result.schedule, "0 9 * * *")
        self.assertEqual(result.schedule_display, "Every day at 9:00 AM")

    def test_additional_tasks_roundtrip(self) -> None:
        text = wrap(
            '{"title":"Send rent email","connection_slug":"gmail",'
            '"summary":"Email landlord.","ready":true,'
            '"tasks":['
            '{"title":"Send rent email","connection_slug":"gmail","summary":"Email landlord."},'
            '{"title":"Book calendar hold","connection_slug":'
            '"googlecalendar","summary":"Block time to review lease."}'
            ']}'
        )
        result = parse_prepare(text)
        assert result is not None
        self.assertEqual(len(result.additional_tasks), 1)
        self.assertEqual(result.additional_tasks[0].title, "Book calendar hold")
        self.assertEqual(result.additional_tasks[0].connection_slug, "googlecalendar")

    def test_single_task_array_stays_on_original_row(self) -> None:
        text = wrap(
            '{"ready":true,'
            '"tasks":[{"title":"Send rent email","connection_slug":"gmail",'
            '"summary":"Email landlord."}]}'
        )
        result = parse_prepare(text)
        assert result is not None
        self.assertEqual(result.title, "Send rent email")
        self.assertEqual(result.additional_tasks, [])


class CronHeuristicTests(unittest.TestCase):
    def test_infer_daily_morning(self) -> None:
        got = infer_recurring_schedule(
            "Every morning at 9am check email and create tasks"
        )
        self.assertIsNotNone(got)
        assert got is not None
        self.assertEqual(got[0], "0 9 * * *")

    def test_infer_every_two_hours(self) -> None:
        got = infer_recurring_schedule("Check inbox every 2 hours")
        self.assertIsNotNone(got)
        assert got is not None
        self.assertEqual(got[0], "every 2h")

    def test_one_off_returns_none(self) -> None:
        self.assertIsNone(infer_recurring_schedule("Send email to John"))

    def test_augment_promotes_task_to_cron(self) -> None:
        base = parse_prepare(
            wrap('{"title":"Check email","connection_slug":"gmail","ready":true}')
        )
        assert base is not None
        self.assertFalse(base.is_cron)
        promoted = augment_cron_from_text(
            base,
            "Every morning at 9am check email and create tasks",
        )
        self.assertTrue(promoted.is_cron)
        self.assertEqual(promoted.schedule, "0 9 * * *")


class BuildPreparePromptTests(unittest.TestCase):
    def test_prompt_does_not_ask_model_to_execute(self) -> None:
        prompt = build_prepare_prompt(
            title="Email landlord rent is late",
            detail="",
        )
        self.assertIn("do NOT execute", prompt)
        self.assertIn("Email landlord rent is late", prompt)

    def test_prompt_lists_allowed_slugs(self) -> None:
        prompt = build_prepare_prompt(
            title="x", detail="", allowed_slugs={"gmail", "slack"}
        )
        self.assertIn("gmail", prompt)
        self.assertIn("slack", prompt)

    def test_prompt_includes_prior_user_response_when_resuming(self) -> None:
        prompt = build_prepare_prompt(
            title="Send invite",
            detail="",
            prior={
                "prompt": "Who should I invite?",
                "payload": {},
                "response": {"option_id": "team", "text": "Add Alice too"},
            },
        )
        self.assertIn("Who should I invite?", prompt)
        self.assertIn("team", prompt)
        self.assertIn("Add Alice too", prompt)
        self.assertIn("Do not ask the same question", prompt)


if __name__ == "__main__":
    unittest.main()
