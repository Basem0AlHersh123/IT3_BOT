"""استيراد الطلاب من Excel إلى القاعدة (للمطوّر / مشرف الدفعة).
يدعم الصيغة الكلاسيكية (4 أعمدة) وصيغة كشوفات الكلية متعددة الأوراق (مثل IT2_G1..IT2F_G4).
الاستخدام:
    python scripts/import_students.py students.xlsx --actor 123456789 [--cohort-id 3] [--dry-run]
"""
from __future__ import annotations

import argparse
import asyncio
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from core.scope import CohortContext, ScopeResolver  # noqa: E402
from core.student_import import parse_students_excel  # noqa: E402


def read_rows(path: str, *, cohort_ctx: CohortContext | None = None) -> tuple[list[dict], list[str]]:
    res = parse_students_excel(path, cohort_ctx=cohort_ctx, default_practical=True)
    return res.rows, res.problems


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--actor", type=int, required=True)
    ap.add_argument("--cohort-id", type=int, default=None)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    from core.config import load_settings
    from core.store import Store

    cohort_ctx: CohortContext | None = None
    store: Store | None = None
    if args.cohort_id or not args.dry_run:
        s = load_settings()
        store = Store(s.supabase_url, s.supabase_service_key, timeout=30)

    try:
        if store is not None and args.cohort_id:
            cohort_ctx = await ScopeResolver(store).get_cohort(args.cohort_id)

        parsed = parse_students_excel(args.file, cohort_ctx=cohort_ctx, default_practical=True)
        print(
            f"الأوراق: {parsed.sheets_read} | صالح: {len(parsed.rows)} | "
            f"عملي افتراضي: {parsed.defaulted_practical} | مرفوض: {len(parsed.problems)}"
        )
        for p in parsed.problems[:30]:
            print("  ", p)
        if args.dry_run or not parsed.rows or store is None:
            return

        ins = upd = 0
        for i in range(0, len(parsed.rows), 200):
            chunk = parsed.rows[i:i + 200]
            if args.cohort_id:
                res = await store.rpc("import_students_scoped", {
                    "p_actor": args.actor,
                    "p_cohort_node_id": args.cohort_id,
                    "p_rows": chunk,
                })
            else:
                res = await store.rpc("import_students", {"p_actor": args.actor, "p_rows": chunk})
            ins, upd = ins + int(res["inserted"]), upd + int(res["updated"])
            for e in res["errors"]:
                print("   خطأ من القاعدة:", e)
        print(f"تمت الإضافة: {ins} | التحديث: {upd}")
    finally:
        if store is not None:
            await store.aclose()


if __name__ == "__main__":
    asyncio.run(main())
