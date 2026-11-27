"""Database-backed Scope Tree resolution (ADR-0002).

Deep module replacing the process-wide `core/cohort.py` singleton:
- `ScopeNode`: immutable representation of a Tenant Scope Node
  (`college` -> `major` -> `cohort` -> `theory_group` -> `practical_group`).
- `CohortContext`: cohort-level view built from a `cohort` node and its descendant
  Theory Groups and Practical Groups, exposing display labels, normalization, and
  public serialization with zero global mutable state.
- `ScopeResolver`: version-keyed cached resolver backed by `Store` (`data_versions['scopes']`).
"""
from __future__ import annotations

import re
import time
from dataclasses import dataclass
from typing import Any, Iterable, Mapping, Protocol

SCOPE_KINDS = ("college", "major", "cohort", "theory_group", "practical_group")


class ScopeStore(Protocol):
    async def list_scope_nodes(self) -> list[dict[str, Any]]: ...
    async def versions(self) -> dict[str, int]: ...


@dataclass(frozen=True)
class ScopeNode:
    id: int
    kind: str
    parent_id: int | None
    code: str
    name_ar: str
    path: tuple[int, ...]
    meta: Mapping[str, Any]
    sort: int = 0
    is_active: bool = True

    @classmethod
    def from_row(cls, row: Mapping[str, Any]) -> ScopeNode:
        raw_path = row.get("path") or ()
        path = tuple(int(x) for x in raw_path)
        parent = row.get("parent_id")
        return cls(
            id=int(row["id"]),
            kind=str(row["kind"]),
            parent_id=int(parent) if parent is not None else None,
            code=str(row["code"]),
            name_ar=str(row["name_ar"]),
            path=path,
            meta=dict(row.get("meta") or {}),
            sort=int(row.get("sort") or 0),
            is_active=bool(row.get("is_active", True)),
        )

    @property
    def cohort_node_id(self) -> int | None:
        return self.path[2] if len(self.path) >= 3 else None

    @property
    def college_node_id(self) -> int | None:
        return self.path[0] if len(self.path) >= 1 else None

    def to_public(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "kind": self.kind,
            "parent_id": self.parent_id,
            "code": self.code,
            "name_ar": self.name_ar,
            "path": list(self.path),
            "sort": self.sort,
        }


@dataclass(frozen=True)
class CohortContext:
    node: ScopeNode
    major: ScopeNode | None
    college: ScopeNode | None
    theory_nodes: tuple[ScopeNode, ...]
    practical_nodes: tuple[ScopeNode, ...]

    # ---- Identity & display ----
    @property
    def id(self) -> int:
        return self.node.id

    @property
    def code(self) -> str:
        return self.node.code

    @property
    def name_ar(self) -> str:
        return self.node.name_ar

    @property
    def specialization(self) -> str:
        if self.major is not None and self.major.name_ar:
            return self.major.name_ar
        return str(self.node.meta.get("specialization") or self.node.name_ar).strip()

    @property
    def batch(self) -> str:
        return str(self.node.meta.get("batch") or "").strip()

    @property
    def level(self) -> str:
        return str(self.node.meta.get("level") or "").strip()

    @property
    def theory_prefix(self) -> str:
        configured = str(self.node.meta.get("theory_prefix") or "").strip().upper()
        if configured:
            return configured
        if self.theory_nodes:
            return re.sub(r"\d+$", "", self.theory_nodes[0].code).upper()
        return ""

    @property
    def title(self) -> str:
        if self.batch:
            return f"دفعة {self.specialization} {self.batch}".strip()
        return self.node.name_ar or f"دفعة {self.specialization}".strip()

    @property
    def student_noun(self) -> str:
        if self.batch:
            return f"طالب {self.specialization} دفعة {self.batch}".strip()
        return f"طالب {self.specialization}".strip()

    @property
    def students_noun(self) -> str:
        if self.batch:
            return f"طلاب {self.specialization} دفعة {self.batch}".strip()
        return f"طلاب {self.specialization}".strip()

    @property
    def level_line(self) -> str:
        return self.level

    # ---- Group lookups ----
    def theory_ids(self) -> list[str]:
        return [t.code for t in self.theory_nodes]

    def practical_ids(self) -> list[str]:
        return [p.code for p in self.practical_nodes]

    def practical_map(self) -> list[tuple[str, str]]:
        theory_code_by_id = {t.id: t.code for t in self.theory_nodes}
        out: list[tuple[str, str]] = []
        for p in self.practical_nodes:
            t_code = theory_code_by_id.get(p.parent_id or -1)
            if t_code is not None:
                out.append((p.code, t_code))
        return out

    def theory_node_by_code(self, code: str) -> ScopeNode | None:
        target = str(code or "").strip().upper()
        for t in self.theory_nodes:
            if t.code.upper() == target:
                return t
        return None

    def practical_node_by_code(self, code: str) -> ScopeNode | None:
        target = str(code or "").strip().upper()
        for p in self.practical_nodes:
            if p.code.upper() == target:
                return p
        return None

    def node_by_id(self, node_id: int) -> ScopeNode | None:
        if self.node.id == node_id:
            return self.node
        for n in (*self.theory_nodes, *self.practical_nodes):
            if n.id == node_id:
                return n
        return None

    def practical_nodes_of(self, theory_node_id: int) -> list[ScopeNode]:
        return [p for p in self.practical_nodes if p.parent_id == theory_node_id]

    def practical_of(self, theory: str | int) -> list[str]:
        if isinstance(theory, int):
            return [p.code for p in self.practical_nodes if p.parent_id == theory]
        node = self.theory_node_by_code(theory)
        if node is None:
            return []
        return [p.code for p in self.practical_nodes if p.parent_id == node.id]

    def is_theory(self, value: object) -> bool:
        return self.theory_node_by_code(str(value or "")) is not None

    def is_practical(self, value: object) -> bool:
        return self.practical_node_by_code(str(value or "")) is not None

    # ---- Normalization ----
    def normalize_theory_node(self, digits_text: str) -> ScopeNode | None:
        cleaned = str(digits_text or "").strip().upper()
        if not cleaned:
            return None
        direct = self.theory_node_by_code(cleaned)
        if direct is not None:
            return direct
        prefix = self.theory_prefix
        base = prefix[:-1] if prefix.endswith("G") else prefix
        base = base.rstrip("_")
        pattern = rf"(?:{re.escape(base)}_?)?G?(\d{{1,2}})" if base else r"G?(\d{1,2})"
        m = re.fullmatch(pattern, cleaned)
        if not m:
            return None
        n = int(m.group(1))
        if prefix:
            by_prefix = self.theory_node_by_code(f"{prefix}{n}")
            if by_prefix is not None:
                return by_prefix
        if 1 <= n <= len(self.theory_nodes):
            return self.theory_nodes[n - 1]
        return None

    def normalize_theory(self, digits_text: str) -> str | None:
        node = self.normalize_theory_node(digits_text)
        return node.code if node is not None else None

    def normalize_practical_node(self, digits_text: str) -> ScopeNode | None:
        cleaned = str(digits_text or "").strip().upper()
        if not cleaned:
            return None
        direct = self.practical_node_by_code(cleaned)
        if direct is not None:
            return direct
        m = re.fullmatch(r"G?(\d{1,2})", cleaned)
        if not m:
            return None
        return self.practical_node_by_code(f"G{int(m.group(1))}")

    def normalize_practical(self, digits_text: str) -> str | None:
        node = self.normalize_practical_node(digits_text)
        return node.code if node is not None else None

    def public(self) -> dict[str, Any]:
        theory_code_by_id = {t.id: t.code for t in self.theory_nodes}
        return {
            "id": self.id,
            "code": self.code,
            "name_ar": self.name_ar,
            "path": list(self.node.path),
            "title": self.title,
            "student_noun": self.student_noun,
            "specialization": self.specialization,
            "batch": self.batch,
            "level": self.level,
            "major": self.major.to_public() if self.major else None,
            "college": self.college.to_public() if self.college else None,
            "theory": self.theory_ids(),
            "practical": [{"id": c, "theory": t} for c, t in self.practical_map()],
            "theory_nodes": [t.to_public() for t in self.theory_nodes],
            "practical_nodes": [
                {
                    **p.to_public(),
                    "theory_node_id": p.parent_id,
                    "theory_code": theory_code_by_id.get(p.parent_id or -1),
                }
                for p in self.practical_nodes
            ],
        }


def build_cohort_context(cohort_node_id: int, nodes: Iterable[ScopeNode]) -> CohortContext | None:
    """Pure synchronous builder constructing a CohortContext from a flat list of ScopeNodes."""
    by_id: dict[int, ScopeNode] = {n.id: n for n in nodes if n.is_active}
    cohort = by_id.get(cohort_node_id)
    if cohort is None or cohort.kind != "cohort":
        return None

    major = by_id.get(cohort.parent_id) if cohort.parent_id is not None else None
    college = by_id.get(major.parent_id) if major and major.parent_id is not None else None

    theory = tuple(
        sorted(
            (n for n in by_id.values() if n.kind == "theory_group" and n.parent_id == cohort.id),
            key=lambda n: (n.sort, n.id),
        )
    )
    theory_order = {t.id: idx for idx, t in enumerate(theory)}
    practical = tuple(
        sorted(
            (n for n in by_id.values() if n.kind == "practical_group" and n.parent_id in theory_order),
            key=lambda n: (theory_order[n.parent_id or -1], n.sort, n.id),
        )
    )
    return CohortContext(
        node=cohort,
        major=major,
        college=college,
        theory_nodes=theory,
        practical_nodes=practical,
    )


def _build_default_cohort_context() -> CohortContext:
    """Immutable fallback CohortContext (CS2_G1..CS2_G3, G1..G9) for callers/tests without DB context."""
    college = ScopeNode(1, "college", None, "csit", "كلية علوم الحاسوب وتقنية المعلومات", (1,), {}, 1)
    major = ScopeNode(2, "major", 1, "cs", "علوم الحاسوب", (1, 2), {}, 1)
    cohort = ScopeNode(3, "cohort", 2, "cs26", "الدفعة 26", (1, 2, 3), {"batch": "26", "level": "", "theory_prefix": "CS2_G"}, 1)
    theory = tuple(
        ScopeNode(10 + i, "theory_group", 3, f"CS2_G{i}", f"CS2_G{i}", (1, 2, 3, 10 + i), {}, i)
        for i in range(1, 4)
    )
    practical = tuple(
        ScopeNode(
            100 + ((i - 1) * 3 + j),
            "practical_group",
            10 + i,
            f"G{(i - 1) * 3 + j}",
            f"G{(i - 1) * 3 + j}",
            (1, 2, 3, 10 + i, 100 + ((i - 1) * 3 + j)),
            {},
            (i - 1) * 3 + j,
        )
        for i in range(1, 4)
        for j in range(1, 4)
    )
    return CohortContext(node=cohort, major=major, college=college, theory_nodes=theory, practical_nodes=practical)


DEFAULT_COHORT_CONTEXT: CohortContext = _build_default_cohort_context()


class ScopeResolver:
    """Version-keyed cached Scope Tree resolver backed by Store."""

    def __init__(self, store: ScopeStore, *, ttl: float = 30.0) -> None:
        self._store = store
        self._ttl = ttl
        self._nodes: tuple[ScopeNode, ...] = ()
        self._by_id: dict[int, ScopeNode] = {}
        self._cohorts: dict[int, CohortContext] = {}
        self._version: int | None = None
        self._loaded_at: float = 0.0

    def invalidate(self) -> None:
        self._version = None
        self._loaded_at = 0.0
        self._cohorts.clear()

    async def _ensure_loaded(self, *, version: int | None = None) -> None:
        now = time.monotonic()
        if version is not None:
            if self._nodes and self._version == version:
                return
        elif self._nodes and (now - self._loaded_at) < self._ttl:
            return

        current_version = version
        if current_version is None:
            versions = await self._store.versions()
            current_version = int(versions.get("scopes", 0))
            if self._nodes and self._version == current_version:
                self._loaded_at = now
                return

        rows = await self._store.list_scope_nodes()
        nodes = tuple(
            sorted(
                (ScopeNode.from_row(r) for r in rows),
                key=lambda n: (len(n.path), n.sort, n.id),
            )
        )
        self._nodes = nodes
        self._by_id = {n.id: n for n in nodes}
        self._cohorts.clear()
        self._version = current_version
        self._loaded_at = now

    async def load_tree(self, *, version: int | None = None) -> tuple[ScopeNode, ...]:
        await self._ensure_loaded(version=version)
        return self._nodes

    async def get_node(self, node_id: int, *, version: int | None = None) -> ScopeNode | None:
        await self._ensure_loaded(version=version)
        return self._by_id.get(int(node_id))

    async def get_cohort(self, cohort_node_id: int, *, version: int | None = None) -> CohortContext | None:
        await self._ensure_loaded(version=version)
        cid = int(cohort_node_id)
        if cid in self._cohorts:
            return self._cohorts[cid]
        ctx = build_cohort_context(cid, self._nodes)
        if ctx is not None:
            self._cohorts[cid] = ctx
        return ctx

    async def resolve_for_node(self, scope_node_id: int, *, version: int | None = None) -> CohortContext | None:
        node = await self.get_node(scope_node_id, version=version)
        if node is None or node.cohort_node_id is None:
            return None
        return await self.get_cohort(node.cohort_node_id, version=version)

    async def list_colleges(self, *, version: int | None = None) -> list[ScopeNode]:
        await self._ensure_loaded(version=version)
        return [n for n in self._nodes if n.kind == "college" and n.is_active]

    async def list_majors(self, college_id: int | None = None, *, version: int | None = None) -> list[ScopeNode]:
        await self._ensure_loaded(version=version)
        return [
            n for n in self._nodes
            if n.kind == "major" and n.is_active and (college_id is None or n.parent_id == college_id)
        ]

    async def list_cohorts(self, major_id: int | None = None, *, version: int | None = None) -> list[CohortContext]:
        await self._ensure_loaded(version=version)
        result: list[CohortContext] = []
        for n in self._nodes:
            if n.kind == "cohort" and n.is_active and (major_id is None or n.parent_id == major_id):
                ctx = await self.get_cohort(n.id, version=self._version)
                if ctx is not None:
                    result.append(ctx)
        return result
