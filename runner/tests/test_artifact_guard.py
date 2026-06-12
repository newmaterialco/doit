from __future__ import annotations

import unittest
from unittest.mock import MagicMock

from runner.artifact_guard import (
    RunUrlTracker,
    artifact_matches_task,
    maybe_upsert_artifact,
)
from runner.events import ArtifactRequest


_FISHING_TODO = {
    "id": "fish-1",
    "title": "Draft follow-up email to Jackson Hole Fly Fishing School",
    "detail": "Ask about availability for a half-day guided trip in July.",
}

_MOVING_ARTIFACT = ArtifactRequest(
    key="sheet",
    kind="link",
    title="Top moving companies comparison",
    payload={
        "url": "https://docs.google.com/spreadsheets/d/moving123",
        "subject": "Moving company quotes",
    },
)

_FISHING_ARTIFACT = ArtifactRequest(
    key="email_draft",
    kind="email",
    title="Follow-up to Jackson Hole Fly Fishing School",
    payload={
        "subject": "Half-day guided trip in July",
        "body": "Hi, I'm interested in a half-day guided fly fishing trip in July.",
    },
)


class ArtifactGuardTests(unittest.TestCase):
    def test_moving_artifact_rejected_for_fishing_task(self) -> None:
        self.assertFalse(
            artifact_matches_task(_FISHING_TODO, _MOVING_ARTIFACT, frozenset())
        )

    def test_fishing_email_accepted_for_fishing_task(self) -> None:
        self.assertTrue(
            artifact_matches_task(_FISHING_TODO, _FISHING_ARTIFACT, frozenset())
        )

    def test_url_seen_in_run_accepts_off_topic_title(self) -> None:
        tracker = RunUrlTracker()
        tracker.observe_text(
            "Created sheet: https://docs.google.com/spreadsheets/d/moving123"
        )
        self.assertTrue(
            artifact_matches_task(
                _FISHING_TODO, _MOVING_ARTIFACT, tracker.urls
            )
        )

    def test_maybe_upsert_skips_off_topic(self) -> None:
        db = MagicMock()
        persisted = maybe_upsert_artifact(
            db,
            todo=_FISHING_TODO,
            artifact=_MOVING_ARTIFACT,
            user_id="user-1",
            run_id="run-1",
            url_tracker=RunUrlTracker(),
        )
        self.assertFalse(persisted)
        db.upsert_artifact.assert_not_called()

    def test_maybe_upsert_persists_on_topic(self) -> None:
        db = MagicMock()
        persisted = maybe_upsert_artifact(
            db,
            todo=_FISHING_TODO,
            artifact=_FISHING_ARTIFACT,
            user_id="user-1",
            run_id="run-1",
            url_tracker=RunUrlTracker(),
        )
        self.assertTrue(persisted)
        db.upsert_artifact.assert_called_once()

    def test_audio_kind_bypasses_keyword_gate(self) -> None:
        audio = ArtifactRequest(
            key="audio",
            kind="audio",
            title="Spoken summary",
            payload={"text": "Unrelated moving company recap"},
        )
        self.assertTrue(
            artifact_matches_task(_FISHING_TODO, audio, frozenset())
        )


if __name__ == "__main__":
    unittest.main()
