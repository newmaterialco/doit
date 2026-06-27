"""Free-form chat follow-up prompt builder.

When the user types in the detail view's composer outside of an open
interaction card, the runner re-claims the todo and weaves the unconsumed
``todo_messages`` into the next Hermes prompt via ``build_followup_prompt``.
These tests pin the contract so the conversational follow-up turn stays
distinguishable from a brand-new task and from an interaction resume.
"""
from __future__ import annotations

import unittest

from runner.prompt import build_followup_prompt, build_prompt


URL_A = "https://supabase.test/storage/v1/object/sign/todo-attachments/u/t/a.jpg?token=A"


class BuildFollowupPromptTests(unittest.TestCase):
    def test_includes_base_task_framing(self) -> None:
        prompt = build_followup_prompt(
            "Caption these photos",
            "",
            messages=["Make the captions shorter please"],
            original_title="Caption these photos for my blog",
        )
        # The base prompt's framing must survive verbatim so the agent
        # still knows which task this turn is about.
        self.assertIn("Original user request:", prompt)
        self.assertIn("Caption these photos for my blog", prompt)
        self.assertIn("Prepared title:", prompt)
        # And the follow-up framing rides on top of it.
        self.assertIn("follow-up message", prompt)
        self.assertIn("Make the captions shorter please", prompt)

    def test_multiple_messages_are_each_quoted(self) -> None:
        prompt = build_followup_prompt(
            "Send the email",
            "",
            messages=["Use a friendlier tone", "And cc Alex"],
        )
        self.assertIn("Use a friendlier tone", prompt)
        self.assertIn("And cc Alex", prompt)
        # Order is preserved (oldest first matches the DB query order).
        self.assertLess(
            prompt.index("Use a friendlier tone"),
            prompt.index("And cc Alex"),
        )

    def test_empty_messages_fall_back_to_base_prompt(self) -> None:
        base = build_prompt("Send the email", "")
        prompt = build_followup_prompt("Send the email", "", messages=[])
        self.assertEqual(prompt, base)
        whitespace = build_followup_prompt(
            "Send the email", "", messages=["", "   ", "\n"]
        )
        self.assertEqual(whitespace, base)
        self.assertNotIn("follow-up message", prompt)

    def test_continue_instruction_is_present(self) -> None:
        prompt = build_followup_prompt(
            "Send the email",
            "",
            messages=["use a friendlier tone"],
        )
        # The agent must be told this is a continuation, not a fresh task.
        self.assertIn("Continue", prompt)
        self.assertIn("Do not restart from scratch", prompt)

    def test_attachments_block_lands_after_follow_up(self) -> None:
        prompt = build_followup_prompt(
            "Caption these photos",
            "",
            messages=["use a brighter mood"],
            attachment_urls=[URL_A],
        )
        self.assertIn("Attachments (images):", prompt)
        self.assertIn(f"- {URL_A}", prompt)
        self.assertLess(
            prompt.index("use a brighter mood"),
            prompt.index("Attachments (images):"),
        )

    def test_multiline_message_is_quoted_line_by_line(self) -> None:
        prompt = build_followup_prompt(
            "Draft the email",
            "",
            messages=["please:\n- shorten\n- friendlier"],
        )
        # First line gets a `>` prefix; continuation lines are indented
        # so the model can still see them as part of the same message.
        self.assertIn("> please:", prompt)
        self.assertIn("- shorten", prompt)
        self.assertIn("- friendlier", prompt)

    def test_followup_includes_previous_task_context(self) -> None:
        prompt = build_followup_prompt(
            "Create a Google Sheet of AI training-data job subreddits",
            "",
            messages=[
                "Can you create another Google doc that explains the first "
                "5-10 customers I could reach out to?"
            ],
            task_context={
                "artifacts": [
                    {
                        "artifact_key": "sheet",
                        "kind": "link",
                        "title": "AI training-data job subreddits",
                        "payload": {
                            "provider": "googlesheets",
                            "url": "https://docs.google.com/spreadsheets/d/sheet-id",
                        },
                    },
                    {
                        "artifact_key": "strategy-doc",
                        "kind": "link",
                        "title": "AI data business strategy doc",
                        "payload": {
                            "provider": "googledocs",
                            "url": "https://docs.google.com/document/d/doc-id",
                        },
                    },
                ],
                "messages": [{"body": "please make the docs practical"}],
                "steps": [{"kind": "final", "text": "Created the sheet and docs."}],
            },
        )
        self.assertIn("Previous context for this task:", prompt)
        self.assertIn("Existing deliverables are live resources", prompt)
        self.assertIn("Artifacts already created:", prompt)
        self.assertIn("AI training-data job subreddits", prompt)
        self.assertIn("https://docs.google.com/spreadsheets/d/sheet-id", prompt)
        self.assertIn("AI data business strategy doc", prompt)
        self.assertIn("https://docs.google.com/document/d/doc-id", prompt)
        self.assertIn("Recent user chat messages:", prompt)
        self.assertIn("Created the sheet and docs.", prompt)
        self.assertLess(
            prompt.index("Previous context for this task:"),
            prompt.index("The user sent a follow-up message"),
        )

    def test_followup_highlights_current_deliverables(self) -> None:
        prompt = build_followup_prompt(
            "Build Hello Gabe website",
            "",
            messages=["Make the site cleaner and keep the same URL"],
            task_context={
                "deliverables": [
                    {
                        "kind": "link",
                        "key": "website",
                        "title": "Hello Example website",
                        "provider": "github",
                        "url": "https://example-user.github.io/hello-example-website/",
                    }
                ],
                "artifacts": [],
                "messages": [],
                "steps": [],
            },
        )
        self.assertIn("Current deliverables to continue from:", prompt)
        self.assertIn("key=website", prompt)
        self.assertIn("provider=github", prompt)
        self.assertIn("https://example-user.github.io/hello-example-website/", prompt)
        self.assertIn("instead of starting over", prompt)

    def test_context_without_messages_still_includes_deliverables(self) -> None:
        prompt = build_followup_prompt(
            "Update GitHub Pages site",
            "",
            messages=[],
            task_context={
                "deliverables": [
                    {
                        "kind": "link",
                        "key": "github-repo",
                        "title": "hello-example-website repo",
                        "provider": "github",
                        "url": "https://github.com/example-user/hello-example-website",
                    }
                ],
                "artifacts": [],
                "messages": [],
                "steps": [],
            },
        )
        self.assertIn("Previous context for this task:", prompt)
        self.assertIn("Current deliverables to continue from:", prompt)
        self.assertIn("https://github.com/example-user/hello-example-website", prompt)
        self.assertNotIn("The user sent a follow-up message", prompt)

    def test_empty_context_block_is_omitted(self) -> None:
        prompt = build_followup_prompt(
            "Draft the email",
            "",
            messages=["make it shorter"],
            task_context={"artifacts": [], "messages": [], "steps": []},
        )
        self.assertNotIn("Previous context for this task:", prompt)


if __name__ == "__main__":
    unittest.main()
