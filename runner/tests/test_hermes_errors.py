"""Tests for Hermes runner error messages."""
from __future__ import annotations

import unittest

import httpx


def _status_error(status: int, url: str = "http://127.0.0.1:8643/v1/runs") -> httpx.HTTPStatusError:
    request = httpx.Request("POST", url)
    response = httpx.Response(status, request=request)
    return httpx.HTTPStatusError(
        f"Client error '{status}' for url '{url}'",
        request=request,
        response=response,
    )


class HermesHttpFailureMessageTests(unittest.TestCase):
    def test_401_uses_operational_message_without_local_url(self) -> None:
        from runner.runner import _hermes_http_failure_message

        message, detail = _hermes_http_failure_message(_status_error(401))

        self.assertIn("authentication failed", message)
        self.assertIn("repair your Hermes profile", message)
        self.assertNotIn("127.0.0.1", message)
        self.assertNotIn("127.0.0.1", detail)

    def test_connect_error_uses_retryable_gateway_message(self) -> None:
        from runner.runner import _hermes_http_failure_message

        error = httpx.ConnectError(
            "connection refused",
            request=httpx.Request("POST", "http://127.0.0.1:8643/v1/runs"),
        )
        message, detail = _hermes_http_failure_message(error)

        self.assertIn("not reachable", message)
        self.assertIn("could not connect", detail)


if __name__ == "__main__":
    unittest.main()
