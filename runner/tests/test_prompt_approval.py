"""Approval-policy guidance baked into every execution prompt.

When the `+` sheet auto-runs prepared tasks (no manual "Do it" tap), the
agent is the only line of defence between the user and externally
visible actions. ``runner.prompt`` appends an approval policy block on
every turn so the agent knows when to draft-and-ask vs. just-do-it.

These tests pin that contract so a future refactor doesn't silently
drop the policy and start sending unreviewed emails.
"""
from __future__ import annotations

import unittest

from runner.prompt import build_followup_prompt, build_prompt, build_resume_prompt


class ApprovalPolicyPromptTests(unittest.TestCase):
    def test_initial_prompt_carries_the_policy(self) -> None:
        prompt = build_prompt("Send the email", "")
        self.assertIn("Approval policy", prompt)
        # Drafting must come before any approval interaction.
        self.assertIn("draft before asking", prompt.lower())

    def test_email_and_invite_are_approval_gated(self) -> None:
        prompt = build_prompt("Send the email", "")
        # Lower-case the prompt so the assertion is robust to copy edits.
        lowered = prompt.lower()
        self.assertIn("sending an email", lowered)
        self.assertIn("calendar", lowered)
        self.assertIn("[[doit_interaction]]", lowered)
        self.assertIn("approval", lowered)

    def test_creation_tasks_do_not_require_approval(self) -> None:
        prompt = build_prompt("Make me a spreadsheet of leads", "")
        lowered = prompt.lower()
        # Spreadsheets / docs / drafts run without a gate by default.
        self.assertIn("spreadsheets", lowered)
        self.assertIn("not required", lowered)

    def test_followup_prompt_keeps_policy(self) -> None:
        prompt = build_followup_prompt(
            "Draft the email",
            "",
            messages=["use a friendlier tone"],
        )
        self.assertIn("Approval policy", prompt)
        # Follow-up framing still rides on top of the base prompt.
        self.assertIn("follow-up message", prompt)

    def test_resume_prompt_keeps_policy(self) -> None:
        prompt = build_resume_prompt(
            title="Send the email",
            detail="",
            interaction={
                "prompt": "Send this draft?",
                "payload": {"options": [{"id": "send", "label": "Send"}]},
                "response": {"option_id": "send"},
            },
        )
        self.assertIn("Approval policy", prompt)
        # Resume framing still wins over policy text in ordering.
        self.assertIn("Continue from where you left off", prompt)


if __name__ == "__main__":
    unittest.main()
