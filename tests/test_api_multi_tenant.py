"""Multi-tenant end-to-end tests for Tickets C6, C7, and C8 (API, core, worker, and IT3 seed)."""
from __future__ import annotations

import asyncio
import datetime as dt
import hashlib
import hmac
import importlib.util
import json
import time
import unittest
from typing import Any
from unittest.mock import patch
from urllib.parse import urlencode

from core.assignments import validate_assignment_meta
from core.scope import ScopeNode, ScopeResolver, build_cohort_context
from core.store import StoreError
from core.text import normalize_practical, normalize_theory
from scripts.seed_scope_tree import generate_seed_sql

HAS_FASTAPI = importlib.util.find_spec("fastapi") is not None
TEST_TOKEN = "987654:MULTI_TENANT_TEST_TOKEN"


def _sample_nodes() -> list[dict[str, Any]]:
    return [
        {"id": 1, "kind": "college", "parent_id": None, "code": "csit", "name_ar": "الكلية", "path": [1], "meta": {}, "sort": 1, "is_active": True},
        {"id": 2, "kind": "major", "parent_id": 1, "code": "it", "name_ar": "تقنية المعلومات", "path": [1, 2], "meta": {}, "sort": 1, "is_active": True},
        {"id": 3, "kind": "major", "parent_id": 1, "code": "cs", "name_ar": "علوم الحاسوب", "path": [1, 3], "meta": {}, "sort": 2, "is_active": True},
        {"id": 10, "kind": "cohort", "parent_id": 2, "code": "it3", "name_ar": "الدفعة الثالثة", "path": [1, 2, 10], "meta": {"batch": "3", "theory_prefix": "IT3_G"}, "sort": 1, "is_active": True},
        {"id": 100, "kind": "theory_group", "parent_id": 10, "code": "IT3_G1", "name_ar": "IT3_G1", "path": [1, 2, 10, 100], "meta": {}, "sort": 1, "is_active": True},
        {"id": 1001, "kind": "practical_group", "parent_id": 100, "code": "G1", "name_ar": "G1", "path": [1, 2, 10, 100, 1001], "meta": {}, "sort": 1, "is_active": True},
        {"id": 20, "kind": "cohort", "parent_id": 3, "code": "cs3", "name_ar": "الدفعة الثالثة", "path": [1, 3, 20], "meta": {"batch": "26", "theory_prefix": "CS3_G"}, "sort": 1, "is_active": True},
        {"id": 200, "kind": "theory_group", "parent_id": 20, "code": "CS3_G1", "name_ar": "CS3_G1", "path": [1, 3, 20, 200], "meta": {}, "sort": 1, "is_active": True},
        {"id": 2001, "kind": "practical_group", "parent_id": 200, "code": "G1", "name_ar": "G1", "path": [1, 3, 20, 200, 2001], "meta": {}, "sort": 1, "is_active": True},
    ]


class MultiTenantCoreAndSeedTests(unittest.TestCase):
    def test_assignment_validation_and_normalization_respect_cohort_context(self) -> None:
        nodes = [ScopeNode.from_row(r) for r in _sample_nodes()]
        it3 = build_cohort_context(10, nodes)
        cs3 = build_cohort_context(20, nodes)
        assert it3 is not None and cs3 is not None

        now = dt.datetime(2026, 10, 1, 10, 0, tzinfo=dt.timezone.utc)
        ok_it3, err = validate_assignment_meta(
            {"subject_id": 1, "part": "theory", "group": "IT3_G1", "due_local": "2026-10-10 20:00"},
            now,
            cohort_ctx=it3,
        )
        self.assertIsNone(err)
        self.assertIsNotNone(ok_it3)

        # CS3_G1 must be rejected when validating under IT3 CohortContext
        bad_cross, err_cross = validate_assignment_meta(
            {"subject_id": 1, "part": "theory", "group": "CS3_G1", "due_local": "2026-10-10 20:00"},
            now,
            cohort_ctx=it3,
        )
        self.assertIsNone(bad_cross)
        self.assertEqual(err_cross, "invalid_group")

        self.assertEqual(normalize_theory("1", cohort_ctx=it3), "IT3_G1")
        self.assertEqual(normalize_theory("1", cohort_ctx=cs3), "CS3_G1")
        self.assertEqual(normalize_practical("1", cohort_ctx=it3), "G1")
        self.assertEqual(normalize_practical("1", cohort_ctx=cs3), "G1")

    def test_seed_scope_tree_generates_idempotent_it3_sql(self) -> None:
        sql = generate_seed_sql()
        self.assertIn("'csit'", sql)
        self.assertIn("'it'", sql)
        self.assertIn("'it3'", sql)
        for g in ("IT3_G1", "IT3_G2", "IT3_G3", "IT3_G4", "G1", "G8"):
            self.assertIn(f"'{g}'", sql)
        self.assertNotIn("'G9'", sql)

    def test_worker_all_theory_targets_enumerates_every_cohort(self) -> None:
        import tests.stubs  # noqa: F401
        from bot.worker import Worker

        class FakeStore:
            async def list_scope_nodes(self) -> list[dict[str, Any]]:
                return _sample_nodes()

            async def versions(self) -> dict[str, int]:
                return {"scopes": 1}

        class FakeSvc:
            def __init__(self) -> None:
                self.store = FakeStore()
                self.scopes = ScopeResolver(self.store)

        w = Worker(object(), FakeSvc())
        targets = asyncio.run(w._all_theory_targets())
        self.assertEqual(targets, [("IT3_G1", 100), ("CS3_G1", 200)])


def _auth_header(tg_id: int, name: str = "مستخدم") -> dict[str, str]:
    pairs = {
        "auth_date": str(int(time.time())),
        "query_id": "AAH",
        "user": json.dumps({"id": tg_id, "first_name": name}, separators=(",", ":")),
    }
    check = "\n".join(f"{k}={v}" for k, v in sorted(pairs.items()))
    secret = hmac.new(b"WebAppData", TEST_TOKEN.encode(), hashlib.sha256).digest()
    pairs["hash"] = hmac.new(secret, check.encode(), hashlib.sha256).hexdigest()
    return {"Authorization": f"tma {urlencode(pairs)}"}


@unittest.skipUnless(HAS_FASTAPI, "fastapi not installed in this environment")
class MultiTenantApiTests(unittest.TestCase):
    def test_bootstrap_and_scope_mutations_enforce_tenant_isolation(self) -> None:
        from fastapi.testclient import TestClient

        from api import deps
        from api.app import app

        class FakeApiStore:
            async def bootstrap(self, tg_id: int, name: str | None, username: str | None, cohort_node_id: int | None = None) -> dict[str, Any]:
                if tg_id == 1001 and cohort_node_id == 20:
                    raise StoreError("forbidden", 403, "42501")
                cid = cohort_node_id or 10
                return {"user": {"telegram_id": tg_id, "kind": "student"}, "active_cohort": {"id": cid, "code": "it3"}}

            async def create_scope_node(self, actor_id: int, parent_id: int | None, kind: str, code: str, name_ar: str, meta=None, sort: int = 0) -> dict[str, Any]:
                if actor_id == 1001 and parent_id == 20:
                    raise StoreError("forbidden", 403, "42501")
                return {"status": "ok", "node": {"id": 300, "code": code}}

        fake_store = FakeApiStore()
        fake_settings = type("S", (), {"bot_token": TEST_TOKEN, "init_data_max_age": 3600})()
        client = TestClient(app)
        with patch.object(deps, "store", return_value=fake_store), \
             patch.object(deps, "settings", return_value=fake_settings), \
             patch("api.app.store", return_value=fake_store):
            self.assertEqual(client.get("/api/bootstrap?cohort_node_id=10", headers=_auth_header(1001)).status_code, 200)
            self.assertEqual(client.get("/api/bootstrap?cohort_node_id=20", headers=_auth_header(1001)).status_code, 403)
            self.assertEqual(
                client.post(
                    "/api/scopes/nodes",
                    json={"parent_id": 20, "kind": "theory_group", "code": "CS3_G9", "name_ar": "CS3_G9"},
                    headers=_auth_header(1001),
                ).status_code,
                403,
            )


if __name__ == "__main__":
    unittest.main()
