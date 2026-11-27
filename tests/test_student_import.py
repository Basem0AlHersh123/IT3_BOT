"""Unit tests for core/student_import.py (multi-sheet university rosters + classic format)."""
from __future__ import annotations

import io
import unittest

from openpyxl import Workbook

from core.scope import CohortContext, ScopeNode
from core.student_import import parse_students_excel


def _it3_context() -> CohortContext:
    college = ScopeNode(1, "college", None, "csit", "كلية الحاسوب", (1,), {})
    major = ScopeNode(2, "major", 1, "it", "تقنية المعلومات", (1, 2), {})
    cohort = ScopeNode(3, "cohort", 2, "it3", "المستوى الثالث", (1, 2, 3),
                       {"batch": "3", "level": "المستوى الثالث", "theory_prefix": "IT3_G"})
    theories: list[ScopeNode] = []
    practicals: list[ScopeNode] = []
    p_num = 0
    nid = 10
    for t_idx in range(1, 5):
        tid = nid
        nid += 1
        t_node = ScopeNode(tid, "theory_group", 3, f"IT3_G{t_idx}", f"IT3_G{t_idx}", (1, 2, 3, tid), {}, sort=t_idx)
        theories.append(t_node)
        for _ in range(3):
            p_num += 1
            pid = nid
            nid += 1
            practicals.append(
                ScopeNode(pid, "practical_group", tid, f"G{p_num}", f"G{p_num}", (1, 2, 3, tid, pid), {}, sort=p_num)
            )
    return CohortContext(
        node=cohort,
        major=major,
        college=college,
        theory_nodes=tuple(theories),
        practical_nodes=tuple(practicals),
    )


def _to_bytes(wb: Workbook) -> bytes:
    buf = io.BytesIO()
    wb.save(buf)
    return buf.getvalue()


class StudentImportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.ctx = _it3_context()

    def test_multi_sheet_university_roster_format(self) -> None:
        wb = Workbook()
        # Simulate college roster: Row 1 banner, Row 2 Arabic headers, Row 3+ students, no practical column
        for idx, name in enumerate(("IT2_G1", "IT2_G2", "IT2_G3", "IT2F_G4")):
            ws = wb.active if idx == 0 else wb.create_sheet(title=name)
            ws.title = name
            ws.append(["كشف طلاب تقنية المعلومات — المستوى الثالث"])
            ws.append(["م", "كود الطالب", "اسم الطالب", "م1", "م2", "ملاحظة"])
            ws.append([1, 20240001 + idx * 10, f"طالب تجريبي {idx + 1}", None, None, None])
            ws.append([2, 20240002 + idx * 10, f"طالب تجريبي {idx + 10}", None, None, None])

        res = parse_students_excel(_to_bytes(wb), cohort_ctx=self.ctx)
        self.assertEqual(res.sheets_read, 4)
        self.assertEqual(len(res.rows), 8)
        self.assertEqual(res.problems, [])
        self.assertEqual(res.defaulted_practical, 8)
        by_no = {r["academic_no"]: r for r in res.rows}
        self.assertEqual((by_no["20240001"]["theory"], by_no["20240001"]["practical"]), ("IT3_G1", "G1"))
        self.assertEqual((by_no["20240011"]["theory"], by_no["20240011"]["practical"]), ("IT3_G2", "G4"))
        self.assertEqual((by_no["20240021"]["theory"], by_no["20240021"]["practical"]), ("IT3_G3", "G7"))
        self.assertEqual((by_no["20240031"]["theory"], by_no["20240031"]["practical"]), ("IT3_G4", "G10"))

    def test_classic_four_column_format(self) -> None:
        wb = Workbook()
        ws = wb.active
        ws.append(["الرقم الأكاديمي", "اسم الطالب", "المجموعة النظرية", "المجموعة العملية"])
        ws.append(["20241001", "أحمد علي", "IT3_G2", "G5"])
        ws.append(["20241002", "سارة حسن", "IT3_G4", "G12"])
        res = parse_students_excel(_to_bytes(wb), cohort_ctx=self.ctx)
        self.assertEqual(len(res.rows), 2)
        self.assertEqual(res.defaulted_practical, 0)
        self.assertEqual((res.rows[0]["theory"], res.rows[0]["practical"]), ("IT3_G2", "G5"))
        self.assertEqual((res.rows[1]["theory"], res.rows[1]["practical"]), ("IT3_G4", "G12"))

    def test_practical_only_sheet_infers_parent_theory(self) -> None:
        wb = Workbook()
        ws = wb.active
        ws.title = "G11"
        ws.append(["م", "كود الطالب", "اسم الطالب"])
        ws.append([1, "20249999", "طالبة عملي"])
        res = parse_students_excel(_to_bytes(wb), cohort_ctx=self.ctx)
        self.assertEqual(len(res.rows), 1)
        self.assertEqual((res.rows[0]["theory"], res.rows[0]["practical"]), ("IT3_G4", "G11"))
        self.assertEqual(res.defaulted_practical, 0)

    def test_rejects_mismatched_theory_and_practical(self) -> None:
        wb = Workbook()
        ws = wb.active
        ws.append(["الرقم الأكاديمي", "اسم الطالب", "المجموعة النظرية", "المجموعة العملية"])
        ws.append(["20245555", "طالب خطأ", "IT3_G1", "G12"])
        res = parse_students_excel(_to_bytes(wb), cohort_ctx=self.ctx)
        self.assertEqual(res.rows, [])
        self.assertEqual(len(res.problems), 1)

    def test_scope_resolver_exposes_get_cohort(self) -> None:
        from core.scope import ScopeResolver

        self.assertTrue(callable(getattr(ScopeResolver, "get_cohort", None)))


if __name__ == "__main__":
    unittest.main()
