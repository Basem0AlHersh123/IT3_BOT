"""Unit tests for core/scope.py — database-backed Scope Tree resolution (Ticket C4)."""
from __future__ import annotations

import asyncio
import unittest
from typing import Any

from core.scope import ScopeNode, ScopeResolver, build_cohort_context


def _sample_rows() -> list[dict[str, Any]]:
    return [
        {"id": 1, "kind": "college", "parent_id": None, "code": "csit", "name_ar": "كلية علوم الحاسوب وتقنية المعلومات", "path": [1], "meta": {}, "sort": 1, "is_active": True},
        {"id": 2, "kind": "major", "parent_id": 1, "code": "it", "name_ar": "تقنية المعلومات", "path": [1, 2], "meta": {}, "sort": 1, "is_active": True},
        {"id": 3, "kind": "major", "parent_id": 1, "code": "cs", "name_ar": "علوم الحاسوب", "path": [1, 3], "meta": {}, "sort": 2, "is_active": True},
        # Cohort IT3
        {"id": 10, "kind": "cohort", "parent_id": 2, "code": "it3", "name_ar": "الدفعة الثالثة", "path": [1, 2, 10], "meta": {"batch": "3", "level": "المستوى الثالث", "theory_prefix": "IT3_G"}, "sort": 1, "is_active": True},
        {"id": 100, "kind": "theory_group", "parent_id": 10, "code": "IT3_G1", "name_ar": "IT3_G1", "path": [1, 2, 10, 100], "meta": {}, "sort": 1, "is_active": True},
        {"id": 101, "kind": "theory_group", "parent_id": 10, "code": "IT3_G2", "name_ar": "IT3_G2", "path": [1, 2, 10, 101], "meta": {}, "sort": 2, "is_active": True},
        {"id": 1001, "kind": "practical_group", "parent_id": 100, "code": "G1", "name_ar": "G1", "path": [1, 2, 10, 100, 1001], "meta": {}, "sort": 1, "is_active": True},
        {"id": 1002, "kind": "practical_group", "parent_id": 100, "code": "G2", "name_ar": "G2", "path": [1, 2, 10, 100, 1002], "meta": {}, "sort": 2, "is_active": True},
        {"id": 1003, "kind": "practical_group", "parent_id": 101, "code": "G3", "name_ar": "G3", "path": [1, 2, 10, 101, 1003], "meta": {}, "sort": 3, "is_active": True},
        # Cohort CS3 (also has G1 practical code!)
        {"id": 20, "kind": "cohort", "parent_id": 3, "code": "cs3", "name_ar": "الدفعة الثالثة", "path": [1, 3, 20], "meta": {"batch": "26", "level": "المستوى الثالث", "theory_prefix": "CS3_G"}, "sort": 1, "is_active": True},
        {"id": 200, "kind": "theory_group", "parent_id": 20, "code": "CS3_G1", "name_ar": "CS3_G1", "path": [1, 3, 20, 200], "meta": {}, "sort": 1, "is_active": True},
        {"id": 2001, "kind": "practical_group", "parent_id": 200, "code": "G1", "name_ar": "G1", "path": [1, 3, 20, 200, 2001], "meta": {}, "sort": 1, "is_active": True},
    ]


class FakeScopeStore:
    def __init__(self, rows: list[dict[str, Any]], version: int = 1) -> None:
        self.rows = list(rows)
        self.version = version
        self.list_calls = 0
        self.version_calls = 0

    async def list_scope_nodes(self) -> list[dict[str, Any]]:
        self.list_calls += 1
        return list(self.rows)

    async def versions(self) -> dict[str, int]:
        self.version_calls += 1
        return {"scopes": self.version}


class CohortContextTests(unittest.TestCase):
    def test_two_cohorts_with_identical_g1_code_stay_strictly_isolated(self) -> None:
        nodes = [ScopeNode.from_row(r) for r in _sample_rows()]
        it3 = build_cohort_context(10, nodes)
        cs3 = build_cohort_context(20, nodes)
        assert it3 is not None and cs3 is not None

        self.assertEqual(it3.title, "دفعة تقنية المعلومات 3")
        self.assertEqual(cs3.title, "دفعة علوم الحاسوب 26")
        self.assertEqual(it3.theory_ids(), ["IT3_G1", "IT3_G2"])
        self.assertEqual(cs3.theory_ids(), ["CS3_G1"])

        it3_g1 = it3.practical_node_by_code("G1")
        cs3_g1 = cs3.practical_node_by_code("G1")
        assert it3_g1 is not None and cs3_g1 is not None
        self.assertEqual(it3_g1.id, 1001)
        self.assertEqual(cs3_g1.id, 2001)
        self.assertEqual(it3_g1.parent_id, 100)
        self.assertEqual(cs3_g1.parent_id, 200)
        self.assertEqual(it3.practical_of("IT3_G1"), ["G1", "G2"])
        self.assertEqual(cs3.practical_of("CS3_G1"), ["G1"])

    def test_normalization_matches_digits_prefix_and_case(self) -> None:
        nodes = [ScopeNode.from_row(r) for r in _sample_rows()]
        it3 = build_cohort_context(10, nodes)
        assert it3 is not None

        self.assertEqual(it3.normalize_theory("1"), "IT3_G1")
        self.assertEqual(it3.normalize_theory("g2"), "IT3_G2")
        self.assertEqual(it3.normalize_theory("it3_g1"), "IT3_G1")
        self.assertIsNone(it3.normalize_theory("9"))
        self.assertIsNone(it3.normalize_theory("CS3_G1"))

        self.assertEqual(it3.normalize_practical("1"), "G1")
        self.assertEqual(it3.normalize_practical("g3"), "G3")
        self.assertIsNone(it3.normalize_practical("9"))

        p_node = it3.normalize_practical_node("2")
        assert p_node is not None
        self.assertEqual(p_node.id, 1002)

    def test_public_payload_includes_legacy_and_node_fields(self) -> None:
        nodes = [ScopeNode.from_row(r) for r in _sample_rows()]
        it3 = build_cohort_context(10, nodes)
        assert it3 is not None
        pub = it3.public()
        self.assertEqual(pub["id"], 10)
        self.assertEqual(pub["specialization"], "تقنية المعلومات")
        self.assertEqual(pub["theory"], ["IT3_G1", "IT3_G2"])
        self.assertEqual(pub["practical"][0], {"id": "G1", "theory": "IT3_G1"})
        self.assertEqual(pub["theory_nodes"][0]["id"], 100)
        self.assertEqual(pub["practical_nodes"][0]["theory_node_id"], 100)


class ScopeResolverTests(unittest.TestCase):
    def test_resolve_for_node_and_directory_listing(self) -> None:
        async def run() -> None:
            store = FakeScopeStore(_sample_rows())
            resolver = ScopeResolver(store)

            # Resolve from practical group, theory group, and cohort
            ctx_from_p = await resolver.resolve_for_node(1001)
            ctx_from_t = await resolver.resolve_for_node(100)
            ctx_from_c = await resolver.resolve_for_node(10)
            assert ctx_from_p is not None and ctx_from_t is not None and ctx_from_c is not None
            self.assertEqual({ctx_from_p.id, ctx_from_t.id, ctx_from_c.id}, {10})

            # College and major have no owning cohort
            self.assertIsNone(await resolver.resolve_for_node(1))
            self.assertIsNone(await resolver.resolve_for_node(2))

            # Directory queries
            self.assertEqual([c.code for c in await resolver.list_colleges()], ["csit"])
            self.assertEqual([m.code for m in await resolver.list_majors(1)], ["it", "cs"])
            self.assertEqual([c.code for c in await resolver.list_cohorts(2)], ["it3"])
            self.assertEqual([c.code for c in await resolver.list_cohorts()], ["it3", "cs3"])
            self.assertEqual(store.list_calls, 1)

        asyncio.run(run())

    def test_version_bump_invalidates_cache_immediately(self) -> None:
        async def run() -> None:
            store = FakeScopeStore(_sample_rows(), version=1)
            resolver = ScopeResolver(store, ttl=60.0)

            it3_v1 = await resolver.get_cohort(10, version=1)
            assert it3_v1 is not None
            self.assertEqual(it3_v1.theory_ids(), ["IT3_G1", "IT3_G2"])
            self.assertEqual(store.list_calls, 1)

            # Same version hits cache
            await resolver.get_cohort(10, version=1)
            self.assertEqual(store.list_calls, 1)

            # New theory group added and scopes version bumped to 2
            store.rows.append(
                {"id": 102, "kind": "theory_group", "parent_id": 10, "code": "IT3_G3", "name_ar": "IT3_G3", "path": [1, 2, 10, 102], "meta": {}, "sort": 3, "is_active": True}
            )
            it3_v2 = await resolver.get_cohort(10, version=2)
            assert it3_v2 is not None
            self.assertEqual(it3_v2.theory_ids(), ["IT3_G1", "IT3_G2", "IT3_G3"])
            self.assertEqual(store.list_calls, 2)

        asyncio.run(run())


if __name__ == "__main__":
    unittest.main()
