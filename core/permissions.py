"""فحص الصلاحيات مع دعم شجرة النطاق (Scope Tree) ومنح الأدوار بنطاق (Scoped Role Grants).

المصفوفة نفسها بيانات في جدول role_permissions (لا كود)، وهذا الملف يقيّم القائمة الفعلية
التي يعيدها app_bootstrap للمستخدم بصيغة متوافقة مع PostgreSQL (`has_perm_scoped`).

كل صلاحية فعلية:
  {
    "k": المفتاح (مثل "assignments.create"),
    "s": النطاق (own | group | cohort | college | any),
    "n": معرّف عقدة النطاق الممنوحة (int | None؛ None للمطوّر أو الصلاحيات العامة),
    "g": رمز المجموعة النظرية القديم للتوافق المرحلي (str | None),
    "c": شرط اختياري (مثل "delegate_absent" | None),
  }
"""
from __future__ import annotations

from typing import Any, Iterable, Mapping, Sequence

Perm = Mapping[str, object]

SCOPED_LEVELS = frozenset({"group", "cohort", "major", "college"})


def practical_to_theory(practical_code: str, practical_groups: Iterable[Mapping[str, str]]) -> str | None:
    for g in practical_groups:
        if g["id"] == practical_code:
            return g["theory"]
    return None


def _matches_scope_node(
    grant_node_id: object,
    scope_node_id: int | None,
    target_path: Sequence[int] | None,
) -> bool:
    """يرجع True إذا كانت عقدة المنحة سلفًا (أو مساوية) للعقدة المستهدفة."""
    if grant_node_id is None:
        return False
    try:
        grant_id = int(grant_node_id)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return False
    if target_path is not None:
        return grant_id in target_path
    if scope_node_id is not None:
        return grant_id == int(scope_node_id)
    return True


def can(
    perms: Iterable[Perm],
    key: str,
    *,
    theory_group: str | None = None,
    scope_node_id: int | None = None,
    target_path: Sequence[int] | None = None,
    delegate_absent: bool = False,
) -> bool:
    """هل يملك المستخدم الصلاحية key على الهدف المحدد؟

    - scope_node_id / target_path: تقييم وراثة الصلاحية نزولًا عبر شجرة النطاق (ADR-0003).
    - theory_group: فحص توافقي قديم برمز المجموعة النظرية (يُزال بعد ترحيل جميع المستدعين).
    - delegate_absent: يُمرَّر True عند غياب المندوب لتفعيل الصلاحيات المشروطة به.
    - إن لم يُمرَّر هدف (كلها None) نعيد True إن كان للمستخدم الصلاحية في أي نطاق (للإظهار في الواجهة).
    """
    checking_node = scope_node_id is not None or target_path is not None

    for p in perms:
        if p.get("k") != key:
            continue
        cond = p.get("c")
        if cond == "delegate_absent" and not delegate_absent:
            continue

        scope = p.get("s")
        grant_node = p.get("n")

        if scope == "own":
            return True

        if scope == "any" and grant_node is None:
            return True

        # UI visibility check: no target specified
        if not checking_node and theory_group is None:
            return True

        # Scoped Role Grant evaluation via Scope Tree ancestry
        if checking_node:
            if grant_node is not None and _matches_scope_node(grant_node, scope_node_id, target_path):
                return True
            continue

        # Legacy theory_group string check
        if theory_group is not None:
            if scope in ("any", "college", "major", "cohort"):
                return True
            if scope == "group" and p.get("g") == theory_group:
                return True

    return False


def allowed_groups(
    perms: Iterable[Perm],
    key: str,
    all_theory: Iterable[str],
    delegate_absent: bool = False,
) -> list[str]:
    """المجموعات النظرية التي يستطيع المستخدم العمل عليها بهذه الصلاحية (واجهة توافقية)."""
    result: list[str] = []
    for g in all_theory:
        if can(perms, key, theory_group=g, delegate_absent=delegate_absent):
            result.append(g)
    return result


def allowed_nodes(
    perms: Iterable[Perm],
    key: str,
    candidate_nodes: Iterable[Any],
    *,
    delegate_absent: bool = False,
) -> list[int]:
    """معرّفات عقد النطاق التي يملك المستخدم عليها الصلاحية key (يدعم dict أو كائنات ScopeNode)."""
    result: list[int] = []
    for node in candidate_nodes:
        if isinstance(node, Mapping):
            node_id = int(node["id"])
            path = node.get("path")
        else:
            node_id = int(node.id)
            path = getattr(node, "path", None)
        if can(perms, key, scope_node_id=node_id, target_path=path, delegate_absent=delegate_absent):
            result.append(node_id)
    return result
