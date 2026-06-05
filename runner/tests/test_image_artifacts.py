"""Tests for the image artifact persistence path in runner.runner.

Covers:

  1. The ``[[DOIT_ARTIFACT]]`` parser allows ``image`` blocks (defense-in-
     depth — the runner's persistence helper is the actual writer).
  2. ``_maybe_persist_image_artifact`` downloads a remote image URL,
     uploads the bytes via ``upload_todo_image``, and upserts an
     ``image`` artifact whose payload points at the storage path.
  3. The same helper handles a local ``file_path`` (covers Hermes
     built-in image tools that drop bytes into a profile cache dir).
  4. Pre-hosted artifacts (``bucket=todo-images``) are persisted
     unchanged so a re-emit on a follow-up turn doesn't re-upload.

Pure stdlib — no Hermes, no Supabase. The remote URL test uses a tiny
threaded ``http.server`` so the runner's ``httpx`` client has something
real to fetch.
"""
from __future__ import annotations

import os
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any

from runner.events import ArtifactRequest, _ARTIFACT_KINDS, parse_artifacts


class ArtifactKindIncludesImageTests(unittest.TestCase):
    """The parser must round-trip image blocks intact for the runner."""

    def test_image_kind_in_allowlist(self) -> None:
        self.assertIn("image", _ARTIFACT_KINDS)

    def test_parse_image_block_keeps_payload(self) -> None:
        text = (
            "[[DOIT_ARTIFACT]]\n"
            '{"key":"figma-home","type":"image","title":"Home screen",'
            '"payload":{"url":"https://example.com/img.png","provider":"figma",'
            '"width":390,"height":844,"prompt":"Mobile home screen"}}\n'
            "[[/DOIT_ARTIFACT]]"
        )
        result = parse_artifacts(text)
        self.assertEqual(len(result), 1)
        artifact = result[0]
        self.assertEqual(artifact.kind, "image")
        self.assertEqual(artifact.key, "figma-home")
        self.assertEqual(artifact.payload["provider"], "figma")
        self.assertEqual(artifact.payload["prompt"], "Mobile home screen")


class _FakeDB:
    """Captures the calls _maybe_persist_image_artifact makes."""

    def __init__(
        self,
        *,
        upload_path: str | None = "user-1/todo-1/img.png",
    ) -> None:
        self.image_uploads: list[dict[str, Any]] = []
        self.upserts: list[dict[str, Any]] = []
        self._upload_path = upload_path

    def upload_todo_image(
        self,
        *,
        user_id: str,
        todo_id: str,
        filename: str,
        data: bytes,
        mime_type: str,
    ) -> str | None:
        self.image_uploads.append(
            {
                "user_id": user_id,
                "todo_id": todo_id,
                "filename": filename,
                "mime_type": mime_type,
                "size": len(data),
                "data": data,
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


# Smallest valid PNG: 1x1 transparent pixel. Used as the test fixture so
# the local HTTP server can serve "real" image bytes without bundling a
# binary asset in the test directory.
_PNG_BYTES = bytes.fromhex(
    "89504e470d0a1a0a0000000d49484452"
    "0000000100000001080600000080a8"
    "ed44000000124944415478da6364fcffff3f0300"
    "07"
    "fc02fe5deebf3f0000000049454e44ae426082"
)


class _ImageHandler(BaseHTTPRequestHandler):
    """Tiny local HTTP server returning a 1x1 PNG."""

    body = _PNG_BYTES
    content_type = "image/png"

    def do_GET(self) -> None:  # noqa: N802 - stdlib hook name
        self.send_response(200)
        self.send_header("Content-Type", self.content_type)
        self.send_header("Content-Length", str(len(self.body)))
        self.end_headers()
        self.wfile.write(self.body)

    def log_message(self, *_: Any) -> None:
        return


class MaybePersistImageArtifactTests(unittest.IsolatedAsyncioTestCase):
    """Image artifacts upload bytes and persist a storage-backed row."""

    async def test_remote_url_is_downloaded_and_rehosted(self) -> None:
        from runner.runner import _maybe_persist_image_artifact

        server = HTTPServer(("127.0.0.1", 0), _ImageHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        port = server.server_port

        artifact = ArtifactRequest(
            key="image-home",
            kind="image",
            title="Home screen",
            payload={
                "url": f"http://127.0.0.1:{port}/figma.png",
                "provider": "figma",
                "width": 390,
                "height": 844,
                "prompt": "Mobile home screen",
            },
        )
        db = _FakeDB(upload_path="user-1/todo-1/abc.png")

        consumed = await _maybe_persist_image_artifact(
            db,  # type: ignore[arg-type]
            todo_id="todo-1",
            user_id="user-1",
            run_id="run-1",
            artifact=artifact,
        )

        self.assertTrue(consumed)
        self.assertEqual(len(db.image_uploads), 1)
        upload = db.image_uploads[0]
        self.assertEqual(upload["mime_type"], "image/png")
        self.assertTrue(upload["filename"].endswith(".png"))
        self.assertEqual(upload["data"], _PNG_BYTES)

        self.assertEqual(len(db.upserts), 1)
        upsert = db.upserts[0]
        self.assertEqual(upsert["key"], "image-home")
        self.assertEqual(upsert["kind"], "image")
        self.assertEqual(upsert["title"], "Home screen")
        payload = upsert["payload"]
        self.assertEqual(payload["bucket"], "todo-images")
        self.assertEqual(payload["storage_path"], "user-1/todo-1/abc.png")
        self.assertEqual(payload["mime_type"], "image/png")
        self.assertEqual(payload["provider"], "figma")
        self.assertEqual(payload["width"], 390)
        self.assertEqual(payload["height"], 844)
        self.assertEqual(payload["prompt"], "Mobile home screen")
        self.assertIn("source_url", payload)

    async def test_local_file_path_is_uploaded(self) -> None:
        from runner.runner import _maybe_persist_image_artifact

        with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
            f.write(_PNG_BYTES)
            local_path = f.name
        try:
            artifact = ArtifactRequest(
                key="screenshot",
                kind="image",
                title="App screenshot",
                payload={
                    "file_path": local_path,
                    "provider": "browser",
                },
            )
            db = _FakeDB(upload_path="user-1/todo-1/screenshot.png")

            consumed = await _maybe_persist_image_artifact(
                db,  # type: ignore[arg-type]
                todo_id="todo-1",
                user_id="user-1",
                run_id="run-1",
                artifact=artifact,
            )
        finally:
            os.unlink(local_path)

        self.assertTrue(consumed)
        self.assertEqual(len(db.image_uploads), 1)
        self.assertEqual(db.image_uploads[0]["mime_type"], "image/png")
        self.assertEqual(len(db.upserts), 1)
        payload = db.upserts[0]["payload"]
        self.assertEqual(payload["bucket"], "todo-images")
        self.assertEqual(payload["provider"], "browser")
        self.assertNotIn("source_url", payload)

    async def test_prehosted_storage_path_is_persisted_unchanged(self) -> None:
        from runner.runner import _maybe_persist_image_artifact

        artifact = ArtifactRequest(
            key="image-cached",
            kind="image",
            title="Cached image",
            payload={
                "bucket": "todo-images",
                "storage_path": "user-1/todo-1/existing.png",
                "mime_type": "image/png",
                "provider": "figma",
            },
        )
        db = _FakeDB()

        consumed = await _maybe_persist_image_artifact(
            db,  # type: ignore[arg-type]
            todo_id="todo-1",
            user_id="user-1",
            run_id="run-2",
            artifact=artifact,
        )

        self.assertTrue(consumed)
        # Re-emit must not re-upload.
        self.assertEqual(db.image_uploads, [])
        self.assertEqual(len(db.upserts), 1)
        upsert = db.upserts[0]
        self.assertEqual(upsert["kind"], "image")
        self.assertEqual(
            upsert["payload"]["storage_path"], "user-1/todo-1/existing.png"
        )

    async def test_non_image_artifact_is_not_consumed(self) -> None:
        from runner.runner import _maybe_persist_image_artifact

        db = _FakeDB()
        consumed = await _maybe_persist_image_artifact(
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
        )

        self.assertFalse(consumed)
        self.assertEqual(db.image_uploads, [])
        self.assertEqual(db.upserts, [])

    async def test_image_with_no_bytes_is_dropped(self) -> None:
        from runner.runner import _maybe_persist_image_artifact

        artifact = ArtifactRequest(
            key="missing",
            kind="image",
            title="Broken image",
            payload={"file_path": "/tmp/does-not-exist-doit-test.png"},
        )
        db = _FakeDB()

        consumed = await _maybe_persist_image_artifact(
            db,  # type: ignore[arg-type]
            todo_id="todo-1",
            user_id="user-1",
            run_id="run-1",
            artifact=artifact,
        )

        # Claim the artifact (return True) so the caller doesn't fall back
        # to a generic upsert with broken metadata, but skip persistence.
        self.assertTrue(consumed)
        self.assertEqual(db.image_uploads, [])
        self.assertEqual(db.upserts, [])


if __name__ == "__main__":
    unittest.main()
