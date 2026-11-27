"""منطق الواجبات: حالة الطالب، والتحقق من بيانات الإنشاء (الموعد بتوقيت صنعاء)."""
from __future__ import annotations

from datetime import datetime, timedelta
from typing import Any, Mapping

from core.scope import DEFAULT_COHORT_CONTEXT, CohortContext
from core.timeutil import UTC, parse_sanaa

STATUS_AR = {"open": "مفتوح", "submitted": "مسلَّم", "late": "متأخر", "missed": "فاته"}


def parse_ts(value: Any) -> datetime | None:
    if value in (None, ""):
        return None
    if isinstance(value, datetime):
        return value if value.tzinfo else value.replace(tzinfo=UTC)
    return datetime.fromisoformat(str(value).replace("Z", "+00:00"))


def student_status(now: datetime, a: Mapping[str, Any]) -> str:
    """حالة الواجب لدى الطالب: submitted | open | late | missed.
    «late» = بعد الموعد وقبل الإغلاق (ولا يظهر للطالب إلا «متأخر» دون أي ذكر للمهلة)."""
    if parse_ts(a.get("submitted_at")):
        return "submitted"
    due, closes = parse_ts(a["due_at"]), parse_ts(a["closes_at"])
    if a.get("status") == "closed" or now > closes:
        return "missed"
    return "open" if now <= due else "late"


def can_submit(now: datetime, a: Mapping[str, Any]) -> bool:
    return a.get("status") == "open" and now <= parse_ts(a["closes_at"])




def validate_assignment_meta(
    meta: Mapping[str, Any],
    now: datetime,
    *,
    cohort_ctx: CohortContext | None = None,
) -> tuple[dict[str, Any] | None, str | None]:
    try:
        subject_id = int(meta.get("subject_id"))
    except (TypeError, ValueError):
        return None, "invalid_subject"
    ctx = cohort_ctx if cohort_ctx is not None else DEFAULT_COHORT_CONTEXT
    part, group = meta.get("part"), str(meta.get("group") or "").strip().upper()
    if part == "theory":
        if not ctx.is_theory(group):
            return None, "invalid_group"
    elif part == "practical":
        if not ctx.is_practical(group):
            return None, "invalid_group"
    else:
        return None, "invalid_part"
    try:
        due = parse_sanaa(str(meta.get("due_local") or ""))
    except ValueError:
        return None, "invalid_due"
    if due < now + timedelta(minutes=5):
        return None, "due_in_past"
    if due > now + timedelta(days=365):
        return None, "due_too_far"
    desc = str(meta.get("description") or "").strip()
    if len(desc) > 800:
        return None, "description_too_long"
    clean = {"subject_id": subject_id, "part": part, "group": group, "due_at": due.isoformat()}
    if desc:
        clean["description"] = desc
    if meta.get("allow_text") is True:   # افتراضيًا false: الواجب يقبل الملفات فقط
        clean["allow_text"] = True
    return clean, None
