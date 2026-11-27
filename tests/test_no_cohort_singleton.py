"""Deterministic guard (Ticket C8): no runtime module in core/, api/, or bot/
may import the deprecated single-cohort singleton `core.cohort`."""
from __future__ import annotations

import ast
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUNTIME_DIRS = ("core", "api", "bot")


class NoCohortSingletonTests(unittest.TestCase):
    def test_no_runtime_module_imports_core_cohort(self) -> None:
        offenders: list[str] = []
        for d in RUNTIME_DIRS:
            for py_file in sorted((ROOT / d).rglob("*.py")):
                rel = py_file.relative_to(ROOT).as_posix()
                if rel == "core/cohort.py":
                    continue
                tree = ast.parse(py_file.read_text("utf-8"), filename=str(py_file))
                for node in ast.walk(tree):
                    if isinstance(node, ast.Import):
                        for alias in node.names:
                            if alias.name == "core.cohort":
                                offenders.append(f"{rel}:{node.lineno}")
                    elif isinstance(node, ast.ImportFrom):
                        if node.module == "core.cohort":
                            offenders.append(f"{rel}:{node.lineno}")
                        elif node.module == "core" and any(a.name == "cohort" for a in node.names):
                            offenders.append(f"{rel}:{node.lineno}")
        self.assertEqual(
            offenders,
            [],
            f"Runtime modules must use core.scope instead of core.cohort singleton: {offenders}",
        )


if __name__ == "__main__":
    unittest.main()
