"""Smart, flexible Excel student importer for any Cohort across the college.

Deep module used by both the Mini App API (`api/phase4.py`) and the CLI (`scripts/import_students.py`).

Supports:
1. Classic single-sheet 4-column format:
   `Academic No | Full Name | Theory Group | Practical Group` (row 1 header, row 2+ data).
2. Multi-sheet university rosters (e.g., sheets `IT2_G1`, `IT2_G2`, `IT2_G3`, `IT2F_G4`):
   - Auto-detects the header row within rows 1..6 (`كود الطالب` / `الرقم الأكاديمي` / `رقم القيد`,
     `اسم الطالب` / `الاسم`, optional `المجموعة النظرية`, optional `المجموعة العملية`).
   - Infers Theory Group from the sheet name when no Theory column exists (mapping trailing
     group index `1..N` onto the active Cohort's theory groups, even if the sheet still uses
     an older level prefix like `IT2_G1` or `IT2F_G4`).
   - Infers Practical Group + parent Theory Group from a sheet named `G1`..`G60` when practical
     reps upload practical-only rosters.
   - Falls back to the first Practical Group of the student's Theory Group when a theory-only
     sheet has no practical column yet (tracked in `ImportResult.defaulted_practical`).
"""
from __future__ import annotations

import io
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from openpyxl import load_workbook

from core.scope import CohortContext, DEFAULT_COHORT_CONTEXT
from core.text import clean_name, normalize_academic_no, normalize_practical, normalize_theory

_AR_DIGITS = str.maketrans("٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹", "01234567890123456789")

_ID_HEADERS = {
    "كود الطالب", "الرقم الأكاديمي", "الرقم الاكاديمي", "رقم القيد", "رقم الطالب",
    "الكود", "الرقم الجامعي", "academic_no", "academic no", "student_id", "student id", "code", "id",
}
_NAME_HEADERS = {
    "اسم الطالب", "الاسم", "الاسم الكامل", "اسم الطالب الكامل", "الاسم الرباعي",
    "full_name", "full name", "student_name", "student name", "name",
}
_THEORY_HEADERS = {
    "المجموعة النظرية", "مجموعة النظري", "النظري", "المجموعة", "الشعبة",
    "theory", "theory_group", "theory group", "group",
}
_PRACTICAL_HEADERS = {
    "المجموعة العملية", "مجموعة العملي", "العملي", "المعمل", "السكشن",
    "practical", "practical_group", "practical group", "lab",
}


@dataclass
class ImportResult:
    rows: list[dict[str, str]] = field(default_factory=list)
    problems: list[str] = field(default_factory=list)
    sheets_read: int = 0
    defaulted_practical: int = 0


def _norm_header(val: object) -> str:
    s = str(val or "").strip().lower().translate(_AR_DIGITS)
    s = re.sub(r"[\s_\-]+", " ", s)
    return s


def _detect_columns(preview_rows: list[tuple[Any, ...]]) -> tuple[int, dict[str, int]]:
    """Scan up to the first 6 rows to locate header row & column indices.

    Returns (data_start_row_1based, {'id': col, 'name': col, 'theory': col?, 'practical': col?}).
    Falls back to classic 4-column layout (row 2+, cols 0..3) if no headers are recognized.
    """
    for row_idx, row in enumerate(preview_rows, start=1):
        cols: dict[str, int] = {}
        for c_idx, cell in enumerate(row):
            h = _norm_header(cell)
            if not h:
                continue
            if "id" not in cols and h in _ID_HEADERS:
                cols["id"] = c_idx
            elif "name" not in cols and h in _NAME_HEADERS:
                cols["name"] = c_idx
            elif "theory" not in cols and h in _THEORY_HEADERS:
                cols["theory"] = c_idx
            elif "practical" not in cols and h in _PRACTICAL_HEADERS:
                cols["practical"] = c_idx
        if "id" in cols and "name" in cols:
            return row_idx + 1, cols
    return 2, {"id": 0, "name": 1, "theory": 2, "practical": 3}


def _infer_groups_from_sheet_name(
    sheet_name: str,
    cohort_ctx: CohortContext,
) -> tuple[str | None, str | None]:
    """Infer (theory_id, practical_id) from a sheet name like `IT2_G1`, `IT2F_G4`, `IT3_G2`, or `G5`."""
    raw = str(sheet_name or "").strip().translate(_AR_DIGITS)
    if not raw:
        return None, None

    # 1) Exact match against practical group (e.g. "G1".."G12", "عملي 2")
    m_pr = re.fullmatch(r"(?:G|عملي\s*G?|LAB\s*G?|P)\s*(\d{1,2})", raw, flags=re.IGNORECASE)
    if m_pr:
        pr = normalize_practical(f"G{int(m_pr.group(1))}", cohort_ctx=cohort_ctx)
        if pr:
            th = next((t for p, t in cohort_ctx.practical_map() if p == pr), None)
            return th, pr

    # 2) Direct theory match (e.g. "IT3_G1", "CS2_G2")
    direct_th = normalize_theory(raw, cohort_ctx=cohort_ctx)
    if direct_th:
        return direct_th, None

    # 3) Legacy/other-level sheet name with trailing G<n> or group number (e.g. "IT2_G1", "IT2F_G4", "مجموعة 3")
    m_th = re.search(r"(?:_?G|مجموعة\s*)(\d{1,2})\s*$", raw, flags=re.IGNORECASE)
    if m_th:
        idx = int(m_th.group(1))
        t_ids = cohort_ctx.theory_ids()
        if 1 <= idx <= len(t_ids):
            return t_ids[idx - 1], None

    return None, None


def _clean_id_cell(val: object) -> str:
    if isinstance(val, float) and val.is_integer():
        return str(int(val))
    return str(val or "")


def parse_students_excel(
    source: bytes | str | Path,
    *,
    cohort_ctx: CohortContext | None = None,
    default_practical: bool = True,
) -> ImportResult:
    """Parse an `.xlsx` workbook (single-sheet or multi-sheet) into validated student rows."""
    ctx = cohort_ctx or DEFAULT_COHORT_CONTEXT
    stream = io.BytesIO(source) if isinstance(source, (bytes, bytearray)) else source
    wb = load_workbook(stream, read_only=True, data_only=True)
    result = ImportResult()
    seen_nos: dict[str, int] = {}
    practical_by_theory = {t: ctx.practical_of(t) for t in ctx.theory_ids()}
    theory_by_practical = {p: t for p, t in ctx.practical_map()}

    try:
        for sheet_name in wb.sheetnames:
            ws = wb[sheet_name]
            all_rows = list(ws.iter_rows(values_only=True))
            if not all_rows:
                continue
            result.sheets_read += 1
            data_start, cols = _detect_columns(all_rows[:6])
            sheet_th, sheet_pr = _infer_groups_from_sheet_name(sheet_name, ctx)

            for row_num, cells in enumerate(all_rows[data_start - 1:], start=data_start):
                if not cells or not any(cells):
                    continue

                def _cell(key: str) -> Any:
                    idx = cols.get(key)
                    if idx is None or idx >= len(cells):
                        return None
                    return cells[idx]

                no = normalize_academic_no(_clean_id_cell(_cell("id")))
                name = clean_name(str(_cell("name") or ""), max_len=80)
                if not no and not name:
                    continue

                raw_th = _cell("theory")
                raw_pr = _cell("practical")
                pr = normalize_practical(raw_pr, cohort_ctx=ctx) if raw_pr is not None else sheet_pr
                th = normalize_theory(raw_th, cohort_ctx=ctx) if raw_th is not None else None
                if not th and pr:
                    th = theory_by_practical.get(pr)
                if not th:
                    th = sheet_th

                if th and not pr and default_practical:
                    opts = practical_by_theory.get(th) or []
                    if opts:
                        pr = opts[0]
                        result.defaulted_practical += 1

                # Ensure practical belongs to theory (if cell had mismatched pair, reject cleanly)
                valid_pair = bool(th and pr and theory_by_practical.get(pr) == th)
                why = [
                    msg for msg, ok in (
                        ("رقم أكاديمي غير صالح", no),
                        ("اسم غير صالح", name),
                        ("مجموعة نظرية غير صالحة", th),
                        ("مجموعة عملية غير صالحة", pr),
                        ("المجموعة العملية لا تتبع النظرية", valid_pair if (th and pr) else True),
                    ) if not ok
                ]
                if why:
                    result.problems.append(f"[{sheet_name} سطر {row_num}]: " + "، ".join(why))
                    continue

                row_obj = {"academic_no": no, "full_name": name, "theory": th, "practical": pr}
                if no in seen_nos:
                    result.rows[seen_nos[no]] = row_obj
                else:
                    seen_nos[no] = len(result.rows)
                    result.rows.append(row_obj)
    finally:
        wb.close()

    return result
