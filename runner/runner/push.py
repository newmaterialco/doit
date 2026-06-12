"""APNs push via token-based auth (.p8)."""
from __future__ import annotations

import time
import logging
from dataclasses import dataclass

import httpx
import jwt

from .config import Config

log = logging.getLogger(__name__)


@dataclass
class PushPayload:
    title: str
    body: str
    todo_id: str
    kind: str  # "oauth_needed" | "done" | "failed" | "activity_sync"


class Pusher:
    def __init__(self, cfg: Config) -> None:
        self._enabled = bool(
            cfg.apns_key_path
            and cfg.apns_key_id
            and cfg.apns_team_id
            and cfg.apns_topic
        )
        self._cfg = cfg
        self._client: httpx.AsyncClient | None = None
        self._jwt: str | None = None
        self._jwt_iat = 0
        if not self._enabled:
            log.warning("APNs not configured; pushes will be no-ops.")

    def _ensure(self) -> httpx.AsyncClient:
        if self._client is None:
            assert self._enabled
            self._client = httpx.AsyncClient(
                http2=True,
                base_url=(
                    "https://api.sandbox.push.apple.com"
                    if self._cfg.apns_use_sandbox
                    else "https://api.push.apple.com"
                ),
                timeout=20.0,
            )
        return self._client

    def _bearer_token(self) -> str:
        # Apple recommends reusing APNs provider tokens for up to one hour.
        now = int(time.time())
        if self._jwt and now - self._jwt_iat < 50 * 60:
            return self._jwt
        with open(self._cfg.apns_key_path, "r", encoding="utf-8") as f:
            private_key = f.read()
        self._jwt_iat = now
        self._jwt = jwt.encode(
            {"iss": self._cfg.apns_team_id, "iat": now},
            private_key,
            algorithm="ES256",
            headers={"kid": self._cfg.apns_key_id},
        )
        return self._jwt

    async def send(self, tokens: list[str], payload: PushPayload) -> None:
        if not self._enabled or not tokens:
            return
        client = self._ensure()
        message = {
            "aps": {
                "alert": {"title": payload.title, "body": payload.body},
                "sound": "default",
            },
            "todo_id": payload.todo_id,
            "kind": payload.kind,
        }
        for token in tokens:
            try:
                resp = await client.post(
                    f"/3/device/{token}",
                    json=message,
                    headers={
                        "authorization": f"bearer {self._bearer_token()}",
                        "apns-topic": self._cfg.apns_topic,
                        "apns-push-type": "alert",
                        "apns-priority": "10",
                    },
                )
                if resp.status_code == 200:
                    log.info("APNs send succeeded for token %s", token[:8])
                else:
                    log.warning(
                        "APNs send failed for token %s: %s %s",
                        token[:8],
                        resp.status_code,
                        resp.text,
                    )
            except Exception as e:
                log.warning("APNs send failed for token %s: %s", token[:8], e)

    async def send_activity_sync(self, tokens: list[str], todo_id: str) -> None:
        """Silent push so the app can refresh agent activity and update Live Activities."""
        if not self._enabled or not tokens:
            return
        client = self._ensure()
        message = {
            "aps": {"content-available": 1},
            "todo_id": todo_id,
            "kind": "activity_sync",
        }
        for token in tokens:
            try:
                resp = await client.post(
                    f"/3/device/{token}",
                    json=message,
                    headers={
                        "authorization": f"bearer {self._bearer_token()}",
                        "apns-topic": self._cfg.apns_topic,
                        "apns-push-type": "background",
                        "apns-priority": "5",
                    },
                )
                if resp.status_code == 200:
                    log.info("APNs activity_sync succeeded for token %s", token[:8])
                else:
                    log.warning(
                        "APNs activity_sync failed for token %s: %s %s",
                        token[:8],
                        resp.status_code,
                        resp.text,
                    )
            except Exception as e:
                log.warning("APNs activity_sync failed for token %s: %s", token[:8], e)
