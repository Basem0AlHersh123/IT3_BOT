"""Static verification tests for Phase C multi-tenant SQL migrations."""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MIGRATIONS_DIR = ROOT / "supabase" / "migrations"
M0017 = MIGRATIONS_DIR / "0017_scope_tree.sql"
M0018 = MIGRATIONS_DIR / "0018_scope_feature_tables.sql"
M0019 = MIGRATIONS_DIR / "0019_scoped_role_grants.sql"
M0020 = MIGRATIONS_DIR / "0020_scoped_rpcs.sql"
M0021 = MIGRATIONS_DIR / "0021_major_admin.sql"


def _sql_lower(path: Path) -> str:
    return path.read_text("utf-8").lower()


class Migration0017ScopeTreeTests(unittest.TestCase):
    def test_migration_numbering_is_sequential(self) -> None:
        files = sorted(p.name for p in MIGRATIONS_DIR.glob("*.sql"))
        numbers = [int(name.split("_", 1)[0]) for name in files]
        self.assertEqual(numbers, list(range(1, len(numbers) + 1)))
        self.assertIn("0017_scope_tree.sql", files)

    def test_scope_nodes_table_and_five_canonical_levels(self) -> None:
        sql = _sql_lower(M0017)
        self.assertIn("create table if not exists scope_nodes", sql)
        for kind in ("'college'", "'major'", "'cohort'", "'theory_group'", "'practical_group'"):
            self.assertIn(kind, sql)
        self.assertIn("path       bigint[]", sql)
        self.assertIn("using gin (path)", sql)
        self.assertIn("create unique index if not exists scope_nodes_parent_code_uq", sql)

    def test_triggers_are_idempotent_and_enforce_hierarchy_and_versions(self) -> None:
        sql = _sql_lower(M0017)
        self.assertIn("drop trigger if exists trg_scope_nodes_path on scope_nodes;", sql)
        self.assertIn("create trigger trg_scope_nodes_path", sql)
        self.assertIn("drop trigger if exists bump_scope_nodes on scope_nodes;", sql)
        self.assertIn("execute function trg_bump('scopes')", sql)

    def test_required_ancestry_and_tree_helper_functions(self) -> None:
        sql = _sql_lower(M0017)
        for fn in (
            "create or replace function scope_is_ancestor(",
            "create or replace function scope_cohort_of(",
            "create or replace function scope_college_of(",
            "create or replace function scope_tree_for_cohort(",
        ):
            self.assertIn(fn, sql)

    def test_core_tables_receive_idempotent_scope_columns_and_indexes(self) -> None:
        sql = _sql_lower(M0017)
        expected_alters = {
            "theory_groups": ("scope_node_id", "cohort_node_id"),
            "practical_groups": ("scope_node_id", "cohort_node_id"),
            "students": ("cohort_node_id", "theory_node_id", "practical_node_id"),
            "subjects": ("cohort_node_id",),
            "teaching": ("cohort_node_id", "scope_node_id"),
            "tg_destinations": ("cohort_node_id", "scope_node_id"),
            "users": ("active_cohort_node_id",),
        }
        for table, cols in expected_alters.items():
            self.assertIn(f"alter table {table}", sql)
            for col in cols:
                self.assertIn(f"add column if not exists {col}", sql)

        # Every CREATE INDEX / CREATE TABLE in 0017 must be idempotent.
        for line in sql.splitlines():
            stripped = line.strip()
            if stripped.startswith("create table "):
                self.assertIn("if not exists", stripped)
            if re.match(r"^create\s+(unique\s+)?index\s+", stripped):
                self.assertIn("if not exists", stripped)

    def test_rls_and_service_role_grants_configured(self) -> None:
        sql = _sql_lower(M0017)
        self.assertIn("alter table public.scope_nodes enable row level security;", sql)
        self.assertIn("revoke all on table public.scope_nodes from anon, authenticated;", sql)
        for fn_sig in (
            "public.scope_is_ancestor(bigint, bigint)",
            "public.scope_cohort_of(bigint)",
            "public.scope_college_of(bigint)",
            "public.scope_tree_for_cohort(bigint)",
            "public.backup_tables()",
        ):
            self.assertIn(f"revoke execute on function {fn_sig} from public, anon, authenticated;", sql)
            self.assertIn(f"grant execute on function {fn_sig} to service_role;", sql)

    def test_backup_tables_includes_scope_nodes_before_theory_groups(self) -> None:
        sql = _sql_lower(M0017)
        self.assertIn("create or replace function backup_tables()", sql)
        self.assertLess(sql.index("'scope_nodes'"), sql.index("'theory_groups'"))


class Migration0018ScopeFeatureTablesTests(unittest.TestCase):
    def test_0018_exists_and_is_idempotent(self) -> None:
        self.assertTrue(M0018.is_file())
        sql = _sql_lower(M0018)
        for line in sql.splitlines():
            stripped = line.strip()
            if stripped.startswith("create table "):
                self.assertIn("if not exists", stripped)
            if re.match(r"^create\s+(unique\s+)?index\s+", stripped):
                self.assertIn("if not exists", stripped)
            if stripped.startswith("add column "):
                self.assertIn("if not exists", stripped)

    def test_all_tenant_owned_feature_tables_have_scope_columns_and_indexes(self) -> None:
        sql = _sql_lower(M0018)
        expected = {
            "files": ("cohort_node_id", "files_cohort_node_idx"),
            "drafts": ("cohort_node_id", "drafts_cohort_node_idx"),
            "mcq_exams": ("cohort_node_id", "mcq_exams_cohort_node_idx"),
            "support_tickets": ("cohort_node_id", "support_tickets_cohort_node_idx"),
            "assistant_logs": ("cohort_node_id", "assistant_logs_cohort_node_idx"),
            "activity_log": ("scope_node_id", "activity_log_scope_node_idx"),
            "assignments": ("scope_node_id", "assignments_cohort_node_idx"),
            "attendance_sessions": ("theory_node_id", "attendance_sessions_cohort_node_idx"),
            "scanner_devices": ("theory_node_id", "scanner_devices_theory_node_idx"),
            "grievance_cycles": ("theory_node_id", "grievance_cycles_cohort_node_idx"),
            "report_templates": ("theory_node_id", "report_templates_theory_node_uq"),
            "daily_reports": ("theory_node_id", "daily_reports_theory_node_date_uq"),
            "weekly_reports": ("theory_node_id", "weekly_reports_theory_node_week_uq"),
            "report_reminders_sent": ("theory_node_id", "report_reminders_theory_node_date_uq"),
            "sharek_campaigns": ("theory_node_id", "sharek_campaigns_cohort_node_idx"),
        }
        for table, (col, idx) in expected.items():
            self.assertIn(f"alter table {table}", sql)
            self.assertIn(f"add column if not exists {col}", sql)
            self.assertIn(idx, sql)

    def test_colliding_unique_constraints_replaced_with_scoped_uniques(self) -> None:
        sql = _sql_lower(M0018)
        self.assertIn("alter table subjects drop constraint if exists subjects_name_ar_key;", sql)
        self.assertIn("create unique index if not exists subjects_cohort_name_ar_uq", sql)
        self.assertIn("create unique index if not exists teaching_subject_scope_uq", sql)
        self.assertIn("create unique index if not exists tg_destinations_scope_key_uq", sql)
        self.assertIn("revoke all on all sequences in schema public from anon, authenticated;", sql)


class Migration0019ScopedRoleGrantsTests(unittest.TestCase):
    def test_0019_exists_and_is_idempotent(self) -> None:
        self.assertTrue(M0019.is_file())
        sql = _sql_lower(M0019)
        self.assertIn("add column if not exists scope_node_id", sql)
        self.assertIn("drop index if exists role_grants_active_uq;", sql)
        self.assertIn("create unique index if not exists role_grants_active_uq", sql)
        for line in sql.splitlines():
            stripped = line.strip()
            if re.match(r"^create\s+(unique\s+)?index\s+", stripped):
                self.assertIn("if not exists", stripped)

    def test_scoped_roles_and_permissions_seeded(self) -> None:
        sql = _sql_lower(M0019)
        for role in ("'college_admin'", "'cohort_admin'", "'group_rep'"):
            self.assertIn(role, sql)
        for perm in ("'scopes.view'", "'scopes.manage'", "'roles.manage'"):
            self.assertIn(perm, sql)

    def test_ancestry_permission_and_scope_management_functions(self) -> None:
        sql = _sql_lower(M0019)
        for fn in (
            "create or replace function role_rank(",
            "create or replace function role_allowed_on_kind(",
            "create or replace function actor_max_role_rank(",
            "create or replace function has_perm_scoped(",
            "create or replace function require_perm_scoped(",
            "create or replace function grant_role_scoped(",
            "create or replace function revoke_role(",
            "create or replace function create_scope_node(",
            "create or replace function update_scope_node(",
            "create or replace function list_scope_tree(",
        ):
            self.assertIn(fn, sql)
        self.assertIn("scope_is_ancestor(", sql)
        self.assertIn("last_developer", sql)

    def test_service_role_grants_and_revokes(self) -> None:
        sql = _sql_lower(M0019)
        for sig in (
            "public.has_perm_scoped(bigint, text, bigint, boolean)",
            "public.require_perm_scoped(bigint, text, bigint, boolean)",
            "public.grant_role_scoped(bigint, bigint, text, bigint)",
            "public.revoke_role(bigint, bigint)",
            "public.create_scope_node(bigint, bigint, text, text, text, jsonb, smallint)",
            "public.update_scope_node(bigint, bigint, text, jsonb, smallint, boolean)",
            "public.list_scope_tree(bigint, bigint)",
        ):
            self.assertIn(f"revoke execute on function {sig} from public, anon, authenticated;", sql)
            self.assertIn(f"grant execute on function {sig} to service_role;", sql)


class Migration0020ScopedRpcsTests(unittest.TestCase):
    def test_0020_exists_and_drops_ambiguous_overloads(self) -> None:
        self.assertTrue(M0020.is_file())
        sql = _sql_lower(M0020)
        self.assertIn("drop function if exists app_bootstrap(bigint, text, text);", sql)
        self.assertIn("drop function if exists search_files_smart(bigint, int, text, text, text, smallint[], int);", sql)

    def test_all_scoped_workflow_rpcs_defined_and_enforce_scope(self) -> None:
        sql = _sql_lower(M0020)
        for fn in (
            "create or replace function resolve_user_cohort(",
            "create or replace function set_active_cohort(",
            "create or replace function app_bootstrap(",
            "create or replace function search_files_smart(",
            "create or replace function get_file(",
            "create or replace function cycle_targets_student(",
            "create or replace function home_summary(",
            "create or replace function list_assignments_scoped(",
            "create or replace function list_mcq_exams_scoped(",
            "create or replace function list_sharek_campaigns_scoped(",
            "create or replace function list_grievance_cycles_scoped(",
            "create or replace function open_attendance_session_scoped(",
            "create or replace function import_students_scoped(",
            "create or replace function upsert_destination_scoped(",
            "create or replace function upsert_teaching_scoped(",
        ):
            self.assertIn(fn, sql)
        self.assertIn("require_perm_scoped(", sql)
        self.assertIn("'active_cohort'", sql)
        self.assertIn("'scope_tree'", sql)

    def test_service_role_grants_and_revokes(self) -> None:
        sql = _sql_lower(M0020)
        for sig in (
            "public.resolve_user_cohort(bigint, bigint)",
            "public.set_active_cohort(bigint, bigint)",
            "public.app_bootstrap(bigint, text, text, bigint)",
            "public.search_files_smart(bigint, int, text, text, text, smallint[], int, bigint)",
            "public.get_file(bigint, bigint)",
            "public.home_summary(bigint)",
            "public.list_assignments_scoped(bigint, bigint, bigint, text)",
            "public.list_mcq_exams_scoped(bigint, int, bigint)",
            "public.list_sharek_campaigns_scoped(bigint, bigint)",
            "public.list_grievance_cycles_scoped(bigint, bigint)",
            "public.open_attendance_session_scoped(bigint, smallint, bigint, smallint, boolean)",
            "public.import_students_scoped(bigint, bigint, jsonb)",
            "public.upsert_destination_scoped(bigint, bigint, text, bigint, int, text)",
            "public.upsert_teaching_scoped(bigint, smallint, bigint, smallint)",
        ):
            self.assertIn(f"revoke execute on function {sig} from public, anon, authenticated;", sql)
            self.assertIn(f"grant execute on function {sig} to service_role;", sql)


class Migration0021MajorAdminTests(unittest.TestCase):
    def test_0021_major_admin_role_rank_and_list_scoped_roles(self) -> None:
        self.assertTrue(M0021.is_file())
        sql = _sql_lower(M0021)
        self.assertIn("'major_admin'", sql)
        self.assertIn("when 'major_admin'   then 70", sql)
        self.assertIn("when 'major_admin'   then p_kind = 'major'", sql)
        self.assertIn("create or replace function list_scoped_roles(", sql)
        self.assertIn("revoke execute on function public.list_scoped_roles(bigint, bigint) from public, anon, authenticated;", sql)
        self.assertIn("grant execute on function public.list_scoped_roles(bigint, bigint) to service_role;", sql)


class Migration0022AssignmentNumberReuseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.path = MIGRATIONS_DIR / "0022_assignment_number_reuse.sql"
        self.sql = self.path.read_text("utf-8")

    def test_partial_unique_index_and_functions(self) -> None:
        self.assertIn("drop index if exists assignments_number_uq", self.sql)
        self.assertIn("where deleted_at is null;", self.sql)
        self.assertIn("create or replace function next_active_assignment_number(", self.sql)
        self.assertIn("create or replace function publish_assignment(", self.sql)
        self.assertIn("create or replace function restore_assignment(", self.sql)
        self.assertIn("require_perm_scoped(p_actor, 'assignments.create', v_scope_node)", self.sql)
        self.assertIn("require_perm_scoped(p_actor, 'assignments.manage', a.scope_node_id)", self.sql)
        self.assertIn("s.cohort_node_id = v_cohort_node", self.sql)
        self.assertIn("grant execute on function next_active_assignment_number(", self.sql)


if __name__ == "__main__":
    unittest.main()
