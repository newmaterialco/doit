from __future__ import annotations

import unittest

from runner.memory_symbol import (
    DEFAULT_SYMBOL,
    infer_memory_symbol,
    resolve_memory_symbol,
    sanitize_symbol_name,
)


class MemorySymbolTests(unittest.TestCase):
    def test_sanitize_accepts_valid_symbol(self) -> None:
        self.assertEqual(sanitize_symbol_name(" Airplane "), "airplane")
        self.assertEqual(sanitize_symbol_name("person.crop.circle"), "person.crop.circle")

    def test_sanitize_rejects_invalid(self) -> None:
        self.assertIsNone(sanitize_symbol_name(""))
        self.assertIsNone(sanitize_symbol_name("!!!"))
        self.assertIsNone(sanitize_symbol_name(None))

    def test_infer_maps_keywords(self) -> None:
        self.assertEqual(
            infer_memory_symbol("Flight preferences", "Prefers aisle seats."),
            "airplane",
        )
        self.assertEqual(
            infer_memory_symbol("Kim Totah", "Business associate contact."),
            "person.crop.circle",
        )
        self.assertEqual(
            infer_memory_symbol("Random fact", "Something generic."),
            DEFAULT_SYMBOL,
        )

    def test_resolve_prefers_agent_symbol(self) -> None:
        self.assertEqual(
            resolve_memory_symbol(
                symbol_name="figure.hiking",
                title="Flight preferences",
                body="Prefers aisle seats.",
            ),
            "figure.hiking",
        )

    def test_resolve_falls_back_to_heuristic(self) -> None:
        self.assertEqual(
            resolve_memory_symbol(
                symbol_name="!!!",
                title="Email Enrichment Tool",
                body="Uses Apollo for CRM enrichment.",
            ),
            "envelope.fill",
        )


if __name__ == "__main__":
    unittest.main()
