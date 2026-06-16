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
    PREP_LANE_CRON,
    PREP_LANE_FULL,
    PREP_LANE_TRIVIAL,
    PREP_OPEN,
    TODO_TOPICS,
    augment_cron_from_text,
    build_prepare_prompt,
    classify_prep_lane,
    demote_unrequested_cron,
    has_recurrence_directive,
    infer_recurring_schedule,
    is_complex_task,
    parse_prepare,
    prep_fast_path,
    prep_fast_path_enabled,
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
        # is "go ahead and run" — not stuck on a question. The runner now
        # auto-queues these for execution instead of waiting on a Do it tap.
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

    def test_known_topics_include_expected_broad_buckets(self) -> None:
        for expected in ("communication", "research", "documents", "work", "other"):
            self.assertIn(expected, TODO_TOPICS)

    def test_topic_and_collection_roundtrip(self) -> None:
        text = wrap(
            '{"title":"Prep Acme board notes","connection_slug":"googledocs",'
            '"topic":"work","collection_name":"Acme",'
            '"summary":"Draft notes for the advisory call.","ready":true}'
        )
        result = parse_prepare(text)
        assert result is not None
        self.assertEqual(result.topic, "work")
        self.assertEqual(result.collection_name, "Acme")

    def test_unknown_topic_falls_back_to_other(self) -> None:
        text = wrap(
            '{"title":"x","connection_slug":null,'
            '"topic":"acme-board-notes","ready":true}'
        )
        result = parse_prepare(text)
        assert result is not None
        self.assertEqual(result.topic, "other")

    def test_generic_collection_is_dropped(self) -> None:
        text = wrap(
            '{"title":"Research laptops","connection_slug":null,'
            '"topic":"shopping","collection_name":"shopping","ready":true}'
        )
        result = parse_prepare(text)
        assert result is not None
        self.assertEqual(result.topic, "shopping")
        self.assertIsNone(result.collection_name)

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
            '"googlecalendar","topic":"scheduling","collection_name":"Lease",'
            '"summary":"Block time to review lease."}'
            ']}'
        )
        result = parse_prepare(text)
        assert result is not None
        self.assertEqual(len(result.additional_tasks), 1)
        self.assertEqual(result.additional_tasks[0].title, "Book calendar hold")
        self.assertEqual(result.additional_tasks[0].connection_slug, "googlecalendar")
        self.assertEqual(result.additional_tasks[0].topic, "scheduling")
        self.assertEqual(result.additional_tasks[0].collection_name, "Lease")

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

    def test_one_off_timed_reminder_returns_none(self) -> None:
        # Bare clock times must never count as recurring — "tomorrow at 3pm"
        # is a one-off reminder, not a cron job.
        self.assertIsNone(infer_recurring_schedule("Remind me tomorrow at 3pm"))
        self.assertIsNone(infer_recurring_schedule("Remind me at 4pm to call mom"))
        self.assertIsNone(infer_recurring_schedule("Book a table for 7pm Friday"))

    def test_dated_one_off_task_returns_none(self) -> None:
        self.assertIsNone(
            infer_recurring_schedule(
                "Check X website on Tuesday and let me know what it says"
            )
        )
        self.assertIsNone(infer_recurring_schedule("Send the report next week"))

    def test_future_use_setup_returns_none(self) -> None:
        # "every now and then" is irregular future use, not a schedule.
        self.assertIsNone(
            infer_recurring_schedule(
                "Create a Google Doc called do it bugs where I will every now "
                "and then send you a bug and you just note it down in that doc"
            )
        )
        self.assertIsNone(
            infer_recurring_schedule("Make a sheet I can occasionally add notes to")
        )
        self.assertIsNone(
            infer_recurring_schedule("Set up a place for notes whenever I need it")
        )

    def test_every_weekday_infers_weekly_cron(self) -> None:
        got = infer_recurring_schedule("Check the news site every Tuesday")
        self.assertIsNotNone(got)
        assert got is not None
        self.assertEqual(got[0], "0 9 * * 2")

    def test_every_weekday_with_time(self) -> None:
        got = infer_recurring_schedule("Every Friday at 5pm send my timesheet")
        self.assertIsNotNone(got)
        assert got is not None
        self.assertEqual(got[0], "0 17 * * 5")

    def test_recurrence_directive_detector(self) -> None:
        self.assertTrue(has_recurrence_directive("Check email every morning"))
        self.assertTrue(has_recurrence_directive("daily standup summary"))
        self.assertTrue(has_recurrence_directive("every 2 hours check inbox"))
        self.assertFalse(has_recurrence_directive("Remind me tomorrow at 3pm"))
        self.assertFalse(has_recurrence_directive("send bugs every now and then"))
        self.assertFalse(has_recurrence_directive("Send email to John"))
        self.assertFalse(has_recurrence_directive(""))

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

    def test_augment_does_not_promote_one_off_reminder(self) -> None:
        base = parse_prepare(
            wrap('{"title":"Remind me to call mom","ready":true}')
        )
        assert base is not None
        result = augment_cron_from_text(base, "Remind me tomorrow at 3pm to call mom")
        self.assertFalse(result.is_cron)
        self.assertIsNone(result.schedule)


class CronDemotionGuardTests(unittest.TestCase):
    def _cron_result(self):
        result = parse_prepare(
            wrap(
                '{"title":"Note bugs in doc","connection_slug":"googledocs",'
                '"kind":"cron","schedule":"0 9 * * *",'
                '"schedule_display":"Every day at 9:00 AM","ready":true}'
            )
        )
        assert result is not None
        return result

    def test_demotes_hallucinated_cron_for_setup_task(self) -> None:
        # The reported bug: model invented "Daily at 9:00 AM" for a one-off
        # Google Doc setup request.
        demoted = demote_unrequested_cron(
            self._cron_result(),
            "Can you create a Google Doc called do it bugs where I will every "
            "now and then send you a bug and you just note it down in that doc?",
        )
        self.assertFalse(demoted.is_cron)
        self.assertEqual(demoted.kind, "task")
        self.assertIsNone(demoted.schedule)
        self.assertIsNone(demoted.schedule_display)

    def test_keeps_cron_when_user_asked_for_recurrence(self) -> None:
        kept = demote_unrequested_cron(
            self._cron_result(),
            "Every morning at 9am check my email and note bugs in the doc",
        )
        self.assertTrue(kept.is_cron)
        self.assertEqual(kept.schedule, "0 9 * * *")

    def test_noop_for_task_results(self) -> None:
        base = parse_prepare(wrap('{"title":"Send email to John","ready":true}'))
        assert base is not None
        result = demote_unrequested_cron(base, "Send email to John")
        self.assertFalse(result.is_cron)

    def test_demote_then_augment_never_disagree(self) -> None:
        # The two safety nets share has_recurrence_directive, so a demoted
        # result must never be re-promoted by the augment pass.
        text = "Create a doc where I will send bugs every now and then"
        result = demote_unrequested_cron(self._cron_result(), text)
        result = augment_cron_from_text(result, text)
        self.assertFalse(result.is_cron)
        self.assertIsNone(result.schedule)


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
        self.assertIn("Allowed topic values", prompt)

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

    def test_prompt_includes_existing_organization_examples(self) -> None:
        prompt = build_prepare_prompt(
            title="Find the latest Acme invoice",
            detail="",
            organization_examples=[
                {
                    "title": "Download Acme invoice from Gmail",
                    "topic": "finance",
                    "collection_name": "Acme",
                }
            ],
        )
        self.assertIn("Existing organization examples", prompt)
        self.assertIn("Download Acme invoice from Gmail", prompt)
        self.assertIn("topic=finance", prompt)
        self.assertIn("collection_name=Acme", prompt)
        self.assertIn("reuse matching organization", prompt)

    def test_prompt_guides_invoice_tasks_to_finance(self) -> None:
        prompt = build_prepare_prompt(
            title="Upload the invoice for payment",
            detail="",
        )
        self.assertIn("Invoice, billing, receipt", prompt)
        self.assertIn('topic="finance"', prompt)
        self.assertIn('topic="documents"', prompt)

    def test_prompt_caps_organization_examples_at_eight(self) -> None:
        examples = [
            {"title": f"Task number {i}", "topic": "finance"} for i in range(20)
        ]
        prompt = build_prepare_prompt(
            title="Find the latest Acme invoice",
            detail="",
            organization_examples=examples,
        )
        self.assertIn("Task number 7", prompt)
        self.assertNotIn("Task number 8", prompt)
        self.assertNotIn("Task number 19", prompt)

    def test_prompt_attachment_count_without_signed_urls(self) -> None:
        prompt = build_prepare_prompt(
            title="Log this receipt",
            detail="",
            attachment_count=2,
        )
        self.assertIn("attached 2 image(s)", prompt)
        self.assertIn("do not analyze it now", prompt)
        self.assertNotIn("Attachments (images):", prompt)

    def test_prompt_signed_urls_take_precedence_over_count(self) -> None:
        prompt = build_prepare_prompt(
            title="Log this receipt",
            detail="",
            attachment_urls=["https://signed.test/a.jpg"],
            attachment_count=1,
        )
        self.assertIn("Attachments (images):", prompt)
        self.assertNotIn("attached 1 image(s)", prompt)


class PrepFastPathTests(unittest.TestCase):
    """Deterministic prep bypass (1c): only the narrow obvious cases."""

    def test_disabled_by_default(self) -> None:
        import os
        from unittest import mock

        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("DOIT_PREP_FAST_PATH", None)
            self.assertFalse(prep_fast_path_enabled())
        with mock.patch.dict(os.environ, {"DOIT_PREP_FAST_PATH": "1"}):
            self.assertTrue(prep_fast_path_enabled())

    def test_bare_reminder_with_time_is_fast_pathed(self) -> None:
        decision = prep_fast_path("Remind me at 4pm to call mom")
        assert decision is not None
        self.assertEqual(decision.kind, "task")

    def test_bare_reminder_tomorrow_is_fast_pathed(self) -> None:
        decision = prep_fast_path("Remind me tomorrow to take out the trash")
        assert decision is not None
        self.assertEqual(decision.kind, "task")

    def test_reminder_without_time_goes_to_llm(self) -> None:
        self.assertIsNone(prep_fast_path("Remind me to call mom"))

    def test_confident_recurring_is_fast_pathed_to_cron(self) -> None:
        decision = prep_fast_path("Remind me every day at 9am to stretch")
        assert decision is not None
        self.assertEqual(decision.kind, "cron")
        self.assertIsNotNone(decision.schedule)
        self.assertIsNotNone(decision.schedule_display)

    def test_action_verbs_go_to_llm(self) -> None:
        # Tool-ish work needs connection_slug + title rewrite from prep.
        self.assertIsNone(prep_fast_path("Remind me at 4pm to email Sam"))
        self.assertIsNone(prep_fast_path("Check my inbox for the invoice"))

    def test_websites_go_to_llm(self) -> None:
        self.assertIsNone(
            prep_fast_path("Remind me at 9am about news.ycombinator.com")
        )

    def test_date_qualified_tasks_go_to_llm(self) -> None:
        # "on Tuesday" is the one-off vs recurring gray zone — LLM's call.
        self.assertIsNone(
            prep_fast_path("Remind me on Tuesday at 4pm to call mom")
        )

    def test_long_inputs_go_to_llm(self) -> None:
        self.assertIsNone(prep_fast_path("Remind me at 4pm " + "x" * 300))

    def test_recurrence_without_inferable_schedule_goes_to_llm(self) -> None:
        # Directive present but the inferencer can't produce a confident
        # schedule — ambiguity belongs to the LLM.
        self.assertIsNone(prep_fast_path("Do this every other weekend"))


_MOVING_TASK = (
    "I'm planning a move from San Francisco to London in July. Find "
    "international moving companies, build a spreadsheet of 4 solid "
    "options, and draft an email to each one."
)


class ComplexTaskLaneTests(unittest.TestCase):
    """Phase 2e: complex multi-step work always keeps the full agent lane."""

    def test_moving_workflow_is_complex(self) -> None:
        self.assertTrue(is_complex_task(_MOVING_TASK))

    def test_research_plus_creation_is_complex(self) -> None:
        self.assertTrue(
            is_complex_task("Find a venue and then draft the invitations")
        )

    def test_external_actions_are_complex(self) -> None:
        self.assertTrue(is_complex_task("Book a table for Friday night"))
        self.assertTrue(is_complex_task("Send the contract to the client"))

    def test_comparison_words_are_complex(self) -> None:
        self.assertTrue(is_complex_task("Give me a shortlist of 4 solid options"))
        self.assertTrue(is_complex_task("Compare the top CRM vendors"))

    def test_simple_inputs_are_not_complex(self) -> None:
        self.assertFalse(is_complex_task("Remind me at 4pm to call mom"))
        self.assertFalse(is_complex_task("What's on my calendar today?"))

    def test_complex_task_never_fast_pathed(self) -> None:
        # Even a complex task phrased with recurrence stays in the full
        # lane — deterministic prep must not split or simplify it.
        self.assertIsNone(prep_fast_path(_MOVING_TASK))
        self.assertIsNone(
            prep_fast_path("Compare hotel options every day at 9am")
        )

    def test_classifier_three_lanes(self) -> None:
        self.assertEqual(
            classify_prep_lane("Remind me at 4pm to call mom").lane,
            PREP_LANE_TRIVIAL,
        )
        cron = classify_prep_lane("Remind me every day at 9am to stretch")
        self.assertEqual(cron.lane, PREP_LANE_CRON)
        self.assertIsNotNone(cron.schedule)
        self.assertEqual(
            classify_prep_lane(
                "Check the Acme status page on Tuesday and let me know"
            ).lane,
            PREP_LANE_FULL,
        )
        self.assertEqual(classify_prep_lane(_MOVING_TASK).lane, PREP_LANE_FULL)

    def test_full_lane_is_the_default(self) -> None:
        self.assertEqual(classify_prep_lane("").lane, PREP_LANE_FULL)
        self.assertEqual(classify_prep_lane("Do the thing").lane, PREP_LANE_FULL)


if __name__ == "__main__":
    unittest.main()
