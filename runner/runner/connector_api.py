"""Token-scoped HTTP client for the BYO connector Edge Function."""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import httpx


@dataclass(frozen=True)
class ConnectorAPI:
    supabase_url: str
    supabase_anon_key: str
    connector_token: str

    @property
    def _endpoint(self) -> str:
        return f"{self.supabase_url.rstrip('/')}/functions/v1/connector"

    @property
    def _headers(self) -> dict[str, str]:
        return {
            "Authorization": f"Bearer {self.supabase_anon_key}",
            "apikey": self.supabase_anon_key,
            "X-Connector-Token": self.connector_token,
            "Content-Type": "application/json",
        }

    async def call(self, action: str, **payload: Any) -> dict[str, Any]:
        body = {"action": action, **payload}
        async with httpx.AsyncClient(timeout=httpx.Timeout(10.0, read=60.0)) as client:
            resp = await client.post(self._endpoint, headers=self._headers, json=body)
        resp.raise_for_status()
        data = resp.json()
        return data if isinstance(data, dict) else {}

    async def register(
        self,
        *,
        profile_name: str,
        endpoint_url: str,
        capabilities: dict[str, str],
    ) -> dict[str, Any]:
        return await self.call(
            "register",
            profile_name=profile_name,
            endpoint_url=endpoint_url,
            capabilities=capabilities,
        )

    async def heartbeat(
        self,
        *,
        profile_name: str,
        endpoint_url: str,
        capabilities: dict[str, str],
    ) -> dict[str, Any]:
        return await self.call(
            "heartbeat",
            profile_name=profile_name,
            endpoint_url=endpoint_url,
            capabilities=capabilities,
        )

    async def claim_next(self) -> dict[str, Any] | None:
        return (await self.call("claim_next")).get("todo")

    async def recover_stale(self) -> dict[str, Any] | None:
        return (await self.call("recover_stale")).get("todo")

    async def touch_lease(self, todo_id: str) -> None:
        await self.call("touch_lease", todo_id=todo_id)

    async def update_todo(self, todo_id: str, fields: dict[str, Any]) -> dict[str, Any] | None:
        return (await self.call("update_todo", todo_id=todo_id, fields=fields)).get("todo")

    async def insert_step(
        self,
        *,
        todo_id: str,
        kind: str,
        text: str | None = None,
        url: str | None = None,
        tool_name: str | None = None,
    ) -> dict[str, Any] | None:
        return (
            await self.call(
                "insert_step",
                step={
                    "todo_id": todo_id,
                    "kind": kind,
                    "text": text,
                    "url": url,
                    "tool_name": tool_name,
                },
            )
        ).get("step")
