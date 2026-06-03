"""Tests for runner.mirror_memory_cli — the Settings > Memory backfill tool.

We stub the DB + the Hermes mirror function so the CLI can be exercised
end-to-end without touching Supabase. The point of these tests is to nail
the routing contract:

  * --user-id calls the mirror once for the matching profile.
  * --all iterates every row from list_user_hermes_profiles().
  * --profile resolves the right user_id from the same list.
  * Missing rows produce a non-zero exit.
"""
from __future__ import annotations

import unittest
from dataclasses import dataclass
from typing import Any
from unittest import mock


@dataclass
class _FakeEndpoint:
    profile_name: str
    host: str = "127.0.0.1"
    port: int = 5510
    api_key: str = "key"


class _FakeDB:
    def __init__(
        self,
        *,
        profiles: list[dict[str, str]] | None = None,
        endpoints: dict[str, _FakeEndpoint] | None = None,
    ) -> None:
        self._profiles = profiles or []
        self._endpoints = endpoints or {}

    def list_user_hermes_profiles(self) -> list[dict[str, str]]:
        return list(self._profiles)

    def get_user_hermes(self, user_id: str) -> _FakeEndpoint | None:
        return self._endpoints.get(user_id)


class _FakeStore:
    """Stand-in for HermesMemoryStore that pretends both files exist."""

    def __init__(self, *_args: Any, **_kwargs: Any) -> None:
        pass

    def path_for(self, target: str):
        class _Path:
            def exists(self) -> bool:
                return True

        return _Path()

    def read_entries(self, target: str) -> list[Any]:
        return []


@dataclass
class _FakeConfig:
    hermes_profiles_dir: str = "/tmp/hermes-profiles"


class _CliRouting(unittest.TestCase):
    """Verify the CLI hands off the right (user_id, profile_name) tuples
    to the mirror function. We don't care what the mirror function actually
    does here — that's covered by the runner's mirror logic + the
    hermes_memory tests.
    """

    def _run(self, argv: list[str], db: _FakeDB) -> tuple[int, list[tuple[str, str]]]:
        from runner import mirror_memory_cli as cli

        mirrored: list[tuple[str, str]] = []

        def _fake_mirror(_db, store, user_id):
            # The CLI builds one store per user; we just need to know which
            # user was mirrored and what profile name the store used. The
            # _FakeStore stores nothing, so reach for ctor args via a side
            # channel: the CLI passes profile_name into HermesMemoryStore
            # which we mock to capture it on the store instance.
            mirrored.append((user_id, getattr(store, "_profile", "")))

        with (
            mock.patch.object(cli, "load_config", return_value=_FakeConfig()),
            mock.patch.object(cli, "DB", return_value=db),
            mock.patch.object(cli, "_mirror_hermes_memory_to_supabase", _fake_mirror),
            mock.patch.object(
                cli,
                "HermesMemoryStore",
                side_effect=lambda _dir, profile: type(
                    "_S",
                    (_FakeStore,),
                    {"_profile": profile},
                )(),
            ),
        ):
            code = cli.main(argv)
        return code, mirrored

    def test_user_id_route(self) -> None:
        db = _FakeDB(endpoints={"u1": _FakeEndpoint(profile_name="alpha")})
        code, mirrored = self._run(["--user-id", "u1"], db)
        self.assertEqual(code, 0)
        self.assertEqual(mirrored, [("u1", "alpha")])

    def test_user_id_missing_returns_error_code(self) -> None:
        db = _FakeDB(endpoints={})
        code, mirrored = self._run(["--user-id", "u-missing"], db)
        self.assertEqual(code, 2)
        self.assertEqual(mirrored, [])

    def test_all_iterates_every_profile(self) -> None:
        db = _FakeDB(
            profiles=[
                {"user_id": "u1", "profile_name": "alpha"},
                {"user_id": "u2", "profile_name": "beta"},
            ]
        )
        code, mirrored = self._run(["--all"], db)
        self.assertEqual(code, 0)
        self.assertEqual(
            sorted(mirrored), [("u1", "alpha"), ("u2", "beta")]
        )

    def test_all_with_empty_table_returns_error_code(self) -> None:
        code, mirrored = self._run(["--all"], _FakeDB(profiles=[]))
        self.assertEqual(code, 2)
        self.assertEqual(mirrored, [])

    def test_profile_resolves_user_id_from_table(self) -> None:
        db = _FakeDB(
            profiles=[
                {"user_id": "u1", "profile_name": "alpha"},
                {"user_id": "u2", "profile_name": "beta"},
            ]
        )
        code, mirrored = self._run(["--profile", "beta"], db)
        self.assertEqual(code, 0)
        self.assertEqual(mirrored, [("u2", "beta")])

    def test_profile_unknown_returns_error_code(self) -> None:
        db = _FakeDB(profiles=[{"user_id": "u1", "profile_name": "alpha"}])
        code, mirrored = self._run(["--profile", "ghost"], db)
        self.assertEqual(code, 2)
        self.assertEqual(mirrored, [])


if __name__ == "__main__":
    unittest.main()
