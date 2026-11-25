"""Deterministic guard: every top-level third-party import in core/, api/, and bot/
must be covered by the matching requirements file."""
from __future__ import annotations

import ast
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOCAL_PACKAGES = {"core", "api", "bot", "tests", "scripts", "index"}

# Import name -> distribution name listed in requirements*.txt
IMPORT_TO_PACKAGE: dict[str, str] = {
    "telegram": "python-telegram-bot",
    "dotenv": "python-dotenv",
    "PIL": "pillow",
    "pydantic": "fastapi",  # direct dependency of fastapi
}


def _parse_requirements(path: Path) -> set[str]:
    packages: set[str] = set()
    for raw in path.read_text("utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line or line.startswith("-"):
            continue
        match = re.match(r"([A-Za-z0-9_.-]+)", line)
        if match:
            packages.add(match.group(1).lower().replace("_", "-"))
    return packages


def _top_level_third_party_imports(directory: Path) -> dict[str, list[str]]:
    """Return {package_name: [relative_file_paths]} for top-level third-party imports."""
    found: dict[str, list[str]] = {}
    stdlib = sys.stdlib_module_names
    for py_file in sorted(directory.rglob("*.py")):
        tree = ast.parse(py_file.read_text("utf-8"), filename=str(py_file))
        for node in tree.body:
            names: list[str] = []
            if isinstance(node, ast.Import):
                names = [alias.name.split(".")[0] for alias in node.names]
            elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
                names = [node.module.split(".")[0]]
            for mod in names:
                if mod in stdlib or mod in LOCAL_PACKAGES:
                    continue
                pkg = IMPORT_TO_PACKAGE.get(mod, mod).lower().replace("_", "-")
                rel = py_file.relative_to(ROOT).as_posix()
                found.setdefault(pkg, [])
                if rel not in found[pkg]:
                    found[pkg].append(rel)
    return found


class RequirementsCoverImportsTests(unittest.TestCase):
    def _assert_covered(self, dirs: tuple[str, ...], req_file: str) -> None:
        declared = _parse_requirements(ROOT / req_file)
        missing: dict[str, list[str]] = {}
        for d in dirs:
            for pkg, files in _top_level_third_party_imports(ROOT / d).items():
                if pkg not in declared:
                    missing.setdefault(pkg, []).extend(files)
        self.assertEqual(
            missing,
            {},
            f"Missing from {req_file}: {missing}",
        )

    def test_api_and_core_imports_in_requirements_txt(self) -> None:
        self._assert_covered(("core", "api"), "requirements.txt")

    def test_bot_and_core_imports_in_requirements_bot_txt(self) -> None:
        self._assert_covered(("core", "bot"), "requirements-bot.txt")


if __name__ == "__main__":
    unittest.main()
