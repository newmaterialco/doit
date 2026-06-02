"""Tests for the Hermes text_to_speech tool capture path.

Covers three layers:

  1. ``runner.events.translate`` recognizing ``text_to_speech`` calls and
     their successful outputs, leaving non-TTS tool flows unchanged.
  2. The artifact-kind allow-list now includes ``audio`` so the existing
     ``[[DOIT_ARTIFACT]]`` parser would also let an explicit audio block
     through (defense-in-depth even though the runner usually creates
     audio rows directly).
  3. ``runner.runner._persist_tts_audio`` reading a local file, uploading
     it to a fake DB, and upserting an ``audio`` artifact with the
     spoken text and provider in the payload.

Pure stdlib — no Hermes, no Supabase.
"""
from __future__ import annotations

import json
import os
import threading
import tempfile
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any

from runner.events import (
    ArtifactRequest,
    TTS_TOOL_NAME,
    TTSCall,
    TTSResult,
    _ARTIFACT_KINDS,
    parse_artifacts,
    translate,
)


def _function_call_event(
    *,
    name: str,
    arguments: dict[str, Any] | str,
    call_id: str = "call-1",
) -> tuple[str, dict]:
    """Build a ``response.output_item.added`` event carrying one tool call."""
    args = arguments if isinstance(arguments, str) else json.dumps(arguments)
    return (
        "response.output_item.added",
        {
            "event": "response.output_item.added",
            "item": {
                "type": "function_call",
                "name": name,
                "arguments": args,
                "call_id": call_id,
            },
        },
    )


def _function_call_output_event(
    *,
    output: dict[str, Any] | str | None,
    call_id: str = "call-1",
    name: str | None = None,
) -> tuple[str, dict]:
    """Build a ``response.output_item.done`` event carrying a tool result."""
    if isinstance(output, dict):
        payload = json.dumps(output)
    else:
        payload = output
    item: dict[str, Any] = {
        "type": "function_call_output",
        "call_id": call_id,
        "output": payload,
    }
    if name is not None:
        item["name"] = name
    return (
        "response.output_item.done",
        {
            "event": "response.output_item.done",
            "item": item,
        },
    )


class TTSCallTranslationTests(unittest.TestCase):
    """The added/done pair carries a TTSCall and a matching TTSResult."""

    def test_tool_name_constant_matches_hermes_schema(self) -> None:
        self.assertEqual(TTS_TOOL_NAME, "text_to_speech")

    def test_function_call_emits_tts_call(self) -> None:
        ev_name, data = _function_call_event(
            name="text_to_speech",
            arguments={"text": "Here is your summary.", "voice": "alloy"},
            call_id="call-42",
        )
        effect = translate(ev_name, data)
        self.assertIsNotNone(effect)
        assert effect is not None
        self.assertIsNotNone(effect.tts_call)
        assert effect.tts_call is not None
        self.assertEqual(effect.tts_call.call_id, "call-42")
        self.assertEqual(effect.tts_call.text, "Here is your summary.")
        self.assertEqual(effect.tts_call.voice, "alloy")
        self.assertEqual(effect.step_kind, "tool_started")
        self.assertEqual(effect.tool_name, "text_to_speech")

    def test_function_call_with_string_args_still_parses(self) -> None:
        # Some Hermes runs ship the arguments as a JSON string rather than
        # a dict. Both forms should yield the same TTSCall shape.
        ev_name, data = _function_call_event(
            name="text_to_speech",
            arguments='{"text": "Spoken brief."}',
            call_id="call-7",
        )
        effect = translate(ev_name, data)
        assert effect is not None and effect.tts_call is not None
        self.assertEqual(effect.tts_call.text, "Spoken brief.")
        self.assertIsNone(effect.tts_call.voice)
        self.assertIsNone(effect.tts_call.output_path)

    def test_function_call_with_empty_text_falls_back(self) -> None:
        # Empty `text` is malformed for TTS — we don't want to start
        # tracking a call we can't act on. The generic tool_started
        # path runs instead so the activity log still shows something.
        ev_name, data = _function_call_event(
            name="text_to_speech",
            arguments={"text": "   "},
            call_id="call-8",
        )
        effect = translate(ev_name, data)
        assert effect is not None
        self.assertIsNone(effect.tts_call)
        self.assertEqual(effect.step_kind, "tool_started")
        self.assertEqual(effect.tool_name, "text_to_speech")

    def test_function_call_output_emits_tts_result(self) -> None:
        ev_name, data = _function_call_output_event(
            output={
                "success": True,
                "file_path": "/tmp/tts_20260601_120000.mp3",
                "provider": "elevenlabs",
                "voice_compatible": True,
            },
            call_id="call-42",
            name="text_to_speech",
        )
        effect = translate(ev_name, data)
        assert effect is not None
        self.assertIsNotNone(effect.tts_result)
        assert effect.tts_result is not None
        self.assertEqual(effect.tts_result.call_id, "call-42")
        self.assertEqual(
            effect.tts_result.file_path,
            "/tmp/tts_20260601_120000.mp3",
        )
        self.assertEqual(effect.tts_result.provider, "elevenlabs")
        self.assertTrue(effect.tts_result.voice_compatible)
        self.assertEqual(effect.step_kind, "tool_result")

    def test_failed_tts_output_does_not_emit_result(self) -> None:
        # `success: false` keeps the regular tool_result path so the agent
        # can see what happened in its activity log, but doesn't try to
        # upload a (non-existent) file.
        ev_name, data = _function_call_output_event(
            output={
                "success": False,
                "error": "no api key configured",
                "provider": "elevenlabs",
            },
            call_id="call-9",
        )
        effect = translate(ev_name, data)
        assert effect is not None
        self.assertIsNone(effect.tts_result)
        self.assertEqual(effect.step_kind, "tool_result")

    def test_non_tts_function_call_passes_through(self) -> None:
        # Other tool calls should be unaffected by the TTS branch.
        ev_name, data = _function_call_event(
            name="vision_analyze",
            arguments={"image_url": "https://x/y.jpg"},
            call_id="call-1",
        )
        effect = translate(ev_name, data)
        assert effect is not None
        self.assertIsNone(effect.tts_call)
        self.assertEqual(effect.step_kind, "tool_started")
        self.assertEqual(effect.tool_name, "vision_analyze")

    def test_non_tts_function_call_output_passes_through(self) -> None:
        # A regular tool result without the TTS shape stays in the
        # generic tool_result branch.
        ev_name, data = _function_call_output_event(
            output={"rows": 3, "ok": True},
            call_id="other-call",
        )
        effect = translate(ev_name, data)
        assert effect is not None
        self.assertIsNone(effect.tts_result)
        self.assertEqual(effect.step_kind, "tool_result")


class ArtifactKindIncludesAudioTests(unittest.TestCase):
    """The artifact allow-list and parser also let `audio` blocks land."""

    def test_audio_is_in_artifact_kinds(self) -> None:
        self.assertIn("audio", _ARTIFACT_KINDS)

    def test_parse_artifacts_accepts_audio_block(self) -> None:
        # The runner usually writes audio rows directly from the TTS
        # tool, but an explicit `[[DOIT_ARTIFACT]]` audio block should
        # also be accepted by the generic parser as a safety net.
        text = (
            "[[DOIT_ARTIFACT]]\n"
            '{"key":"audio","type":"audio","title":"Spoken summary",'
            '"payload":{"bucket":"todo-audio","storage_path":"u/t/a.mp3",'
            '"mime_type":"audio/mpeg","provider":"openai",'
            '"text":"This is what was spoken."}}\n'
            "[[/DOIT_ARTIFACT]]"
        )
        rows = parse_artifacts(text)
        self.assertEqual(len(rows), 1)
        row = rows[0]
        self.assertEqual(row.kind, "audio")
        self.assertEqual(row.payload["storage_path"], "u/t/a.mp3")
        self.assertEqual(row.payload["text"], "This is what was spoken.")


# ---------------------------------------------------------------------------
# Persistence path: file read + upload + upsert
# ---------------------------------------------------------------------------


class _FakeDB:
    """Captures the calls _persist_tts_audio makes against runner.db.DB."""

    def __init__(
        self,
        *,
        upload_path: str | None = "user-1/todo-1/file.mp3",
    ) -> None:
        self.uploads: list[dict[str, Any]] = []
        self.upserts: list[dict[str, Any]] = []
        self._upload_path = upload_path

    def upload_todo_audio(
        self,
        *,
        user_id: str,
        todo_id: str,
        filename: str,
        data: bytes,
        mime_type: str,
    ) -> str | None:
        self.uploads.append(
            {
                "user_id": user_id,
                "todo_id": todo_id,
                "filename": filename,
                "mime_type": mime_type,
                "size": len(data),
            }
        )
        return self._upload_path

    def upsert_artifact(
        self,
        *,
        todo_id: str,
        user_id: str,
        key: str,
        kind: str,
        title: str | None,
        payload: dict[str, Any] | None,
        hermes_run_id: str | None = None,
    ) -> None:
        self.upserts.append(
            {
                "todo_id": todo_id,
                "user_id": user_id,
                "key": key,
                "kind": kind,
                "title": title,
                "payload": payload or {},
                "hermes_run_id": hermes_run_id,
            }
        )


class PersistTTSAudioTests(unittest.TestCase):
    """The runner uploads the generated file and upserts an audio row."""

    def test_uploads_and_upserts_audio_artifact(self) -> None:
        from runner.runner import _persist_tts_audio  # late import

        with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as f:
            f.write(b"ID3\x00\x00fakeaudio")
            local_path = f.name
        try:
            db = _FakeDB(upload_path="user-1/todo-1/abc.mp3")
            _persist_tts_audio(
                db,  # type: ignore[arg-type]
                todo_id="todo-1",
                user_id="user-1",
                run_id="run-1",
                result=TTSResult(
                    call_id="call-1",
                    file_path=local_path,
                    provider="elevenlabs",
                    voice_compatible=True,
                ),
                call=TTSCall(
                    call_id="call-1",
                    text="This is the spoken summary.",
                    voice="alloy",
                ),
            )
        finally:
            os.unlink(local_path)

        self.assertEqual(len(db.uploads), 1)
        upload = db.uploads[0]
        self.assertEqual(upload["user_id"], "user-1")
        self.assertEqual(upload["todo_id"], "todo-1")
        self.assertTrue(upload["filename"].endswith(".mp3"))
        self.assertEqual(upload["mime_type"], "audio/mpeg")
        self.assertGreater(upload["size"], 0)

        self.assertEqual(len(db.upserts), 1)
        upsert = db.upserts[0]
        self.assertEqual(upsert["kind"], "audio")
        self.assertEqual(upsert["key"], "audio")
        self.assertEqual(upsert["hermes_run_id"], "run-1")
        payload = upsert["payload"]
        self.assertEqual(payload["storage_path"], "user-1/todo-1/abc.mp3")
        self.assertEqual(payload["bucket"], "todo-audio")
        self.assertEqual(payload["mime_type"], "audio/mpeg")
        self.assertEqual(payload["provider"], "elevenlabs")
        self.assertEqual(payload["voice"], "alloy")
        self.assertTrue(payload["voice_compatible"])
        self.assertEqual(payload["text"], "This is the spoken summary.")

    def test_missing_file_skips_silently(self) -> None:
        from runner.runner import _persist_tts_audio

        db = _FakeDB()
        _persist_tts_audio(
            db,  # type: ignore[arg-type]
            todo_id="todo-1",
            user_id="user-1",
            run_id="run-1",
            result=TTSResult(
                call_id="call-1",
                file_path="/tmp/does-not-exist-9f8a7b6c.mp3",
            ),
            call=None,
        )
        self.assertEqual(db.uploads, [])
        self.assertEqual(db.upserts, [])

    def test_empty_file_skips_upload(self) -> None:
        from runner.runner import _persist_tts_audio

        with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as f:
            local_path = f.name
        try:
            db = _FakeDB()
            _persist_tts_audio(
                db,  # type: ignore[arg-type]
                todo_id="todo-1",
                user_id="user-1",
                run_id="run-1",
                result=TTSResult(
                    call_id="call-1",
                    file_path=local_path,
                ),
                call=None,
            )
        finally:
            os.unlink(local_path)
        self.assertEqual(db.uploads, [])
        self.assertEqual(db.upserts, [])

    def test_upload_failure_skips_upsert(self) -> None:
        from runner.runner import _persist_tts_audio

        with tempfile.NamedTemporaryFile(suffix=".ogg", delete=False) as f:
            f.write(b"OggS\x00fakeogg")
            local_path = f.name
        try:
            db = _FakeDB(upload_path=None)
            _persist_tts_audio(
                db,  # type: ignore[arg-type]
                todo_id="todo-1",
                user_id="user-1",
                run_id="run-1",
                result=TTSResult(
                    call_id="call-1",
                    file_path=local_path,
                    provider="edge",
                ),
                call=TTSCall(call_id="call-1", text="Spoken."),
            )
        finally:
            os.unlink(local_path)
        self.assertEqual(len(db.uploads), 1)
        # Upload returned None, so no artifact row should be written.
        self.assertEqual(db.upserts, [])

    def test_mime_inferred_from_extension(self) -> None:
        from runner.runner import _persist_tts_audio

        with tempfile.NamedTemporaryFile(suffix=".ogg", delete=False) as f:
            f.write(b"OggS\x00data")
            local_path = f.name
        try:
            db = _FakeDB(upload_path="user-1/todo-1/x.ogg")
            _persist_tts_audio(
                db,  # type: ignore[arg-type]
                todo_id="todo-1",
                user_id="user-1",
                run_id="run-1",
                result=TTSResult(
                    call_id="call-1",
                    file_path=local_path,
                ),
                call=TTSCall(call_id="call-1", text="Hi."),
            )
        finally:
            os.unlink(local_path)
        self.assertEqual(db.uploads[0]["mime_type"], "audio/ogg")
        self.assertEqual(db.upserts[0]["payload"]["mime_type"], "audio/ogg")


class _AudioHandler(BaseHTTPRequestHandler):
    """Tiny local HTTP server for the remote audio-link fallback test."""

    body = b"ID3\x00remote-audio"
    content_type = "audio/mpeg"

    def do_GET(self) -> None:  # noqa: N802 - stdlib hook name
        self.send_response(200)
        self.send_header("Content-Type", self.content_type)
        self.send_header("Content-Length", str(len(self.body)))
        self.end_headers()
        self.wfile.write(self.body)

    def log_message(self, *_: Any) -> None:
        # Keep unittest output clean.
        return


class AudioLinkFallbackTests(unittest.IsolatedAsyncioTestCase):
    """Composio/R2 audio links should become native audio artifacts."""

    async def test_audio_link_artifact_downloads_uploads_and_skips_link(self) -> None:
        from runner.runner import (
            _maybe_persist_audio_link_artifact,
            _looks_like_audio_link_artifact,
        )

        server = HTTPServer(("127.0.0.1", 0), _AudioHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        port = server.server_port
        artifact = ArtifactRequest(
            key="hermesagent-mobile-audio",
            kind="link",
            title="Audio recording: HermesAgent mobile-app summary",
            payload={
                "url": f"http://127.0.0.1:{port}/audio",
                "provider": "composio",
            },
        )
        self.assertTrue(_looks_like_audio_link_artifact(artifact))
        db = _FakeDB(upload_path="user-1/todo-1/remote.mp3")

        consumed = await _maybe_persist_audio_link_artifact(
            db,  # type: ignore[arg-type]
            todo_id="todo-1",
            user_id="user-1",
            run_id="run-1",
            artifact=artifact,
            fallback_text="Long-form summary under the player.",
        )

        self.assertTrue(consumed)
        self.assertEqual(len(db.uploads), 1)
        self.assertTrue(db.uploads[0]["filename"].endswith(".mp3"))
        self.assertEqual(db.uploads[0]["mime_type"], "audio/mpeg")
        self.assertEqual(len(db.upserts), 1)
        upsert = db.upserts[0]
        self.assertEqual(upsert["key"], "audio")
        self.assertEqual(upsert["kind"], "audio")
        self.assertEqual(upsert["title"], "Audio recording: HermesAgent mobile-app summary")
        self.assertEqual(upsert["payload"]["storage_path"], "user-1/todo-1/remote.mp3")
        self.assertEqual(upsert["payload"]["provider"], "composio")
        self.assertEqual(upsert["payload"]["text"], "Long-form summary under the player.")

    async def test_non_audio_link_is_not_consumed(self) -> None:
        from runner.runner import _maybe_persist_audio_link_artifact

        db = _FakeDB()
        consumed = await _maybe_persist_audio_link_artifact(
            db,  # type: ignore[arg-type]
            todo_id="todo-1",
            user_id="user-1",
            run_id="run-1",
            artifact=ArtifactRequest(
                key="sheet",
                kind="link",
                title="Budget sheet",
                payload={"url": "https://docs.google.com/sheets/d/x"},
            ),
            fallback_text=None,
        )

        self.assertFalse(consumed)
        self.assertEqual(db.uploads, [])
        self.assertEqual(db.upserts, [])


if __name__ == "__main__":
    unittest.main()
