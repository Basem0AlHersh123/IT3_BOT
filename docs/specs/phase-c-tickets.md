# Phase C Tickets — Single-Session Execution Plan

**Spec:** [phase-c-multi-tenant.md](./phase-c-multi-tenant.md)  
**Workflow Rule:** Execute **one ticket per fresh session**. Keep `py -m pytest -q` and `py -m ruff check .` green after every ticket. All SQL migrations are **one-way doors** and require human review before applying to production Supabase.

---

## Ticket Dependency Overview

```text
C1 (Scope Tree Schema & Backfill)
 └── C2 (Feature Tables Scoping Migration)
      └── C3 (Scoped Role Grants & Permission Engine)
           ├── C4 (core/scope.py & Scoped Bootstrap)
           │    └── C6 (api/ & core/ Caller Migration)
           │         └── C7 (bot/ & worker.py Migration)
           │              └── C8 (Mini App UI, IT3 Seed & Legacy Cleanup)
           └── C5 (Scoped Feature RPCs + Cross-Tenant Isolation Tests) ──► C6
```

---

## Ticket C1 — Scope Tree Schema & Core Backfill Migration

- **Door type:** `one-way` (database migration)
- **Blast radius:** `large`
- **Depends on:** None
- **Goal:** Introduce `scope_nodes` with materialized `path bigint[]`, parent-kind integrity enforcement, SQL ancestry helpers, and idempotent backfill of existing `theory_groups`, `practical_groups`, `students`, `subjects`, `teaching`, `tg_destinations`, and `users`.

### Deliverables
- `supabase/migrations/0017_scope_tree.sql`:
  - Create `scope_nodes` table, GIN index on `path`, unique index on `(coalesce(parent_id, 0), code) where deleted_at is null`, and `BEFORE INSERT OR UPDATE` trigger maintaining `path` and enforcing the 5-level `college → major → cohort → theory_group → practical_group` chain.
  - Add `bump_scope('scopes')` trigger on `scope_nodes`.
  - Add SQL helpers: `scope_is_ancestor(bigint, bigint)`, `scope_cohort_of(bigint)`, `scope_college_of(bigint)`, `scope_tree_for_cohort(bigint)`.
  - Idempotently seed default **College** → **Major** → **Cohort** #1 and backfill `scope_nodes` rows for existing `theory_groups` and `practical_groups`.
  - Add nullable-then-backfilled `scope_node_id` / `cohort_node_id` / `theory_node_id` / `practical_node_id` columns and indexes on `theory_groups`, `practical_groups`, `students`, `subjects`, `teaching`, `tg_destinations`, and `users.active_cohort_node_id`.
  - Enable RLS on `scope_nodes` and grant execute on new functions to `service_role` only.
- `tests/test_migrations_phase_c.py`: Static SQL verification tests (idempotency checks, RLS enabled, `service_role` grants, sequential numbering).

### Acceptance Criteria
- `0017_scope_tree.sql` can be executed twice in a row with zero errors (idempotent).
- Every existing row in `theory_groups`, `practical_groups`, `students`, `subjects`, `teaching`, and `tg_destinations` receives a valid `scope_node_id` / `cohort_node_id`.
- `py -m pytest -q` and `py -m ruff check .` pass.

---

## Ticket C2 — Tenant-Owned Feature Tables Scoping Migration

- **Door type:** `one-way` (database migration)
- **Blast radius:** `large`
- **Depends on:** C1
- **Goal:** Add and backfill `cohort_node_id` / `scope_node_id` across all remaining tenant-owned academic workflow tables and replace globally colliding unique constraints with scope-qualified ones.

### Deliverables
- `supabase/migrations/0018_scope_feature_tables.sql`:
  - Add and backfill `cohort_node_id` / `scope_node_id` / `theory_node_id` (plus indexes) on:
    - `files`, `drafts`, `mcq_exams`, `report_templates`, `support_tickets`, `assistant_logs`, `activity_log`
    - `assignments`, `attendance_sessions`, `grievance_cycles`, `daily_reports`, `weekly_reports`, `report_reminders_sent`, `sharek_campaigns`
  - Replace global uniqueness constraints that would collide across **Cohorts**:
    - `subjects`: `unique (cohort_node_id, name_ar) where deleted_at is null`
    - `teaching`: `unique (subject_id, scope_node_id)`
    - `tg_destinations`: add surrogate `id` + `unique (scope_node_id, key)` while keeping legacy `key` lookup safe during transition.
  - Update `backup_tables()` so `scope_nodes` is included in automated backups.
- Extend `tests/test_migrations_phase_c.py` to assert every tenant-owned table has a scope column and index.

### Acceptance Criteria
- All 14 feature tables have non-null backfilled scope columns (except `activity_log.scope_node_id`, which is nullable for global `developer` events).
- Two **Cohorts** can hold **Subjects** with the same Arabic name and **Telegram Destinations** with the same logical key without constraint violations.
- `py -m pytest -q` and `py -m ruff check .` pass.

---

## Ticket C3 — Scoped Role Grants & Ancestry Permission Engine

- **Door type:** `one-way` (auth/permissions + database migration)
- **Blast radius:** `large`
- **Depends on:** C1
- **Goal:** Implement ADR-0003 in PostgreSQL and `core/permissions.py` so **Scoped Role Grants** inherit downward through the **Scope Tree** and prevent privilege escalation.

### Deliverables
- `supabase/migrations/0019_scoped_role_grants.sql`:
  - Add `scope_node_id bigint references scope_nodes(id)` to `role_grants`; backfill existing rows (`developer` → `NULL`; group roles → `theory_groups.scope_node_id`).
  - Extend `role_grants` and `role_permissions` role checks with `college_admin`, `cohort_admin`, `group_rep`, and seed their permission rows in `role_permissions`.
  - Add scope-management permissions (`scopes.manage`, `scopes.view`) for `developer`, `college_admin`, `cohort_admin`.
  - Replace `role_grants_active_uq` with `(telegram_id, role, coalesce(scope_node_id, 0)) where revoked_at is null`.
  - Rewrite `has_perm`, `require_perm`, `perm_scope`, `grant_role`, `revoke_role` to evaluate `scope_is_ancestor(gr.scope_node_id, p_scope_node_id)` and enforce anti-escalation rules.
  - Add `create_scope_node`, `update_scope_node`, `list_scope_tree` RPCs gated by `require_perm(..., 'scopes.manage', p_parent_id)`.
- `core/permissions.py`:
  - Upgrade `can()` and add `allowed_nodes()` to evaluate **Scoped Role Grants** via `scope_node_id` and `path` ancestry while keeping backward-compatible helpers during migration.
- `tests/test_permissions_scoped.py`:
  - Thorough unit tests for downward inheritance (`College Admin → Major → Cohort → Theory Group → Practical Group`), lateral isolation (Cohort A ≠ Cohort B), multi-grant users, `delegate_absent` condition, and banned users.

### Acceptance Criteria
- **College Admin** inherits permissions to all **Majors**, **Cohorts**, and groups under their **College**, but not to `developer`-only actions.
- **Cohort Admin** inherits permissions only within their **Cohort** subtree.
- **Group Rep** / **Delegate** / **Deputy** / **Committee** are restricted to their granted node and descendants.
- `py -m pytest -q` and `py -m ruff check .` pass.

---

## Ticket C4 — Database-Backed Scope Resolution Module (`core/scope.py`)

- **Door type:** `two-way` (new Python module; no destructive changes)
- **Blast radius:** `medium`
- **Depends on:** C1, C3
- **Goal:** Build `core/scope.py` as a deep module replacing the process-wide `core/cohort.py` singleton, and update `core/store.py` with scope-tree RPC wrappers.

### Deliverables
- `core/scope.py`:
  - `ScopeNode` and `CohortContext` immutable dataclasses.
  - `CohortContext` methods: `title`, `student_noun`, `students_noun`, `level_line`, `theory_nodes`, `practical_nodes`, `practical_of(theory_node_id)`, `normalize_theory(text)`, `normalize_practical(text)`, `public()`.
  - `ScopeResolver(store)` with version-keyed caching (`data_versions['scopes']`) and methods `get_cohort(cohort_node_id)`, `resolve_for_node(scope_node_id)`, `list_colleges()`, `list_majors(college_id)`, `list_cohorts(major_id)`.
- `core/store.py`:
  - Add thin RPC wrappers for `list_scope_tree`, `create_scope_node`, `update_scope_node`, `set_active_cohort`.
- `tests/test_scope.py`:
  - Unit tests using fakes/stubs verifying multi-cohort resolution, identical `G1` practical codes across two cohorts, input normalization, and cache invalidation when `versions['scopes']` increments.

### Acceptance Criteria
- Two distinct **Cohorts** (e.g., IT3 and CS3) resolve simultaneously in the same process with zero global mutable state.
- `py -m pytest -q` and `py -m ruff check .` pass.

---

## Ticket C5 — Scoped Academic RPCs & Bootstrap Migration

- **Door type:** `one-way` (database migration)
- **Blast radius:** `large`
- **Depends on:** C2, C3
- **Goal:** Update `app_bootstrap` and all academic workflow RPCs so every read and write is explicitly scoped to a **Tenant Scope Node** and enforced in PostgreSQL.

### Deliverables
- `supabase/migrations/0020_scoped_rpcs.sql`:
  - Update `app_bootstrap(p_tg, p_name, p_username, p_cohort_node_id default null)` to resolve the user's active **Cohort** (from `students`, `users.active_cohort_node_id`, or highest grant), return `active_cohort`, `scope_tree` (user's visible subtree), `roles` (with `scope_node_id` and `path`), `perms` (with `scope_node_id` and `path`), and **Cohort**-filtered `subjects` and `groups`.
  - Add `set_active_cohort(p_tg, p_cohort_node_id)` for **Guests** and multi-grant admins.
  - Scope all feature RPCs to `p_cohort_node_id` / `p_scope_node_id` with `require_perm`:
    - **Files**: `prepare_file`, `register_file`, `get_file`, `search_files_smart`, `delete_file`
    - **Assignments**: `publish_assignment`, `assignment_detail`, `add_submission_file`, `doctor_group_export`, `list_assignments`
    - **Attendance**: `open_attendance_session`, `scan_attendance`, `cancel_attendance_session`, `attendance_summary`
    - **Grievances**: `open_grievance_cycle`, `submit_grievance`, `list_grievances`
    - **Sharek**: `create_sharek_campaign`, `add_sharek_item`, `vote_sharek`
    - **MCQ**: `upload_mcq`, `list_mcq_exams`, `submit_mcq_attempt`
    - **Reports & Home**: `home_summary`, `create_daily_report`, `create_weekly_report`, `import_students`, `dev_upsert_teaching`, `dev_upsert_destination`
- Extend `tests/test_migrations_phase_c.py` to verify all updated RPC signatures, `require_perm` usage, and `service_role` grants.

### Acceptance Criteria
- Zero tenant-owned RPCs query `subjects`, `files`, `assignments`, `attendance_sessions`, `grievance_cycles`, `sharek_campaigns`, `mcq_exams`, or `students` without a `cohort_node_id` / `scope_node_id` predicate.
- `py -m pytest -q` and `py -m ruff check .` pass.

---

## Ticket C6 — Migrate `api/` and `core/` Callers to Scoped Resolution

- **Door type:** `two-way` (Python API & core refactor)
- **Blast radius:** `medium`
- **Depends on:** C4, C5
- **Goal:** Remove `cohort.get()` from `api/` and `core/` modules, pass explicit `cohort_node_id` / `scope_node_id` on every API route, and expose Scope Tree & Scoped Role Grant management endpoints.

### Deliverables
- Refactor `api/app.py`, `api/deps.py`, `api/phase2.py`, `api/phase3.py`, `api/phase4.py`:
  - `/api/bootstrap` accepts optional `?cohort_node_id=` and returns `active_cohort` from Postgres (drop `cohort.get().public()` injection).
  - `/api/public/catalog` requires or scopes by `cohort_node_id` and returns public **College → Major → Cohort** directory.
  - Add endpoints: `GET /api/scopes/tree`, `POST /api/scopes/nodes`, `PATCH /api/scopes/nodes/{id}`, `POST /api/user/active-cohort`, and scoped `POST /api/admin/roles/grant` / `revoke`.
- Refactor `core/assistant.py`, `core/grievances.py`, `core/assignments.py`, `core/attendance.py`, `core/reports.py`, `core/sharek.py`, `core/files.py`, `core/text.py`, `core/backup.py` to accept `CohortContext` / `scope_node_id` explicitly instead of calling `cohort.get()`.
- Update `tests/stubs.py` and add `tests/test_api_multi_tenant.py` verifying cross-tenant `403 forbidden` isolation across API endpoints.

### Acceptance Criteria
- Zero calls to `cohort.get()` remain in `api/` or `core/`.
- Cross-tenant API tests confirm Cohort A users/admins cannot read or mutate Cohort B data.
- `py -m pytest -q` and `py -m ruff check .` pass.

---

## Ticket C7 — Migrate `bot/` Handlers & `worker.py` to Multi-Tenant Scope Resolution

- **Door type:** `two-way` (Telegram bot adapter refactor)
- **Blast radius:** `medium`
- **Depends on:** C4, C5, C6
- **Goal:** Make the Telegram bot and background `worker.py` fully multi-tenant so user flows, **File** uploads, **Assignment** submissions, and **Telegram Destination** routing resolve per **Tenant Scope Node**.

### Deliverables
- Refactor `bot/main.py`, `bot/files.py`, `bot/assignments.py`, `bot/phase3.py`, `bot/phase4.py`, `bot/texts.py`, `bot/worker.py`:
  - Resolve `CohortContext` per user/draft/entity via `ScopeResolver` instead of `cohort.get()`.
  - Add **Guest** **Major** → **Cohort** selection inline keyboard in `/start` onboarding.
  - Update **Telegram Destination** setup commands and `worker.py` delivery routing to key by `(scope_node_id, key)` so messages/files/notices never cross **Cohort** boundaries.
- Update `tests/test_bot_flows.py` with multi-cohort routing and onboarding tests (including two cohorts with `G1` routing to distinct Telegram chats/topics).

### Acceptance Criteria
- Zero calls to `cohort.get()` remain in `bot/`.
- `worker.py` delivers **Outbox** and **Assignment** packages to the exact `scope_node_id` destination with zero cross-cohort leakage.
- `py -m pytest -q` and `py -m ruff check .` pass.

---

## Ticket C8 — Mini App Multi-Tenant UI, IT3 Tenant #1 Seed & Legacy Cleanup

- **Door type:** `two-way` (frontend UI, seed script, docs, lint guard)
- **Blast radius:** `medium`
- **Depends on:** C6, C7
- **Goal:** Complete the Mini App multi-tenant experience, provide the IT3 Tenant #1 seed script, retire `core/cohort.py`, and close out ADR-0002 & ADR-0003.

### Deliverables
- `public/assets/app.js`, `public/assets/features.js`, `public/assets/phase4.js`:
  - Read active **Cohort** identity from `bootstrap.active_cohort`.
  - Add **Guest** **Major → Cohort** onboarding picker and Cohort switcher in settings.
  - Add Scope Switcher header control for **College Admin**, **Cohort Admin**, and multi-grant users.
  - Add admin UI views for managing the **Scope Tree** (add **Major**, **Cohort**, **Theory Group**, **Practical Group**) and **Scoped Role Grants**.
- `scripts/seed_scope_tree.py`: Idempotent CLI script to seed the **College**, **IT Major**, and **IT3 Cohort** (Tenant #1) with its **Theory Groups** and **Practical Groups**.
- Cleanup & deterministic guardrail:
  - Remove deprecated `core/cohort.py` (or restrict to migration-only if needed) and add a test in `tests/test_no_cohort_singleton.py` asserting no runtime module imports `core.cohort`.
  - Update `GLOSSARY.md` (remove `— planned` markers on implemented terms).
  - Update `docs/adr/0002-multi-tenant-scope-tree.md` and `docs/adr/0003-scoped-role-grants.md` status from `accepted (not implemented)` to `accepted (implemented)`.

### Acceptance Criteria
- IT3 can be seeded cleanly as Tenant #1 and a second test **Cohort** (e.g., CS3) can be created from the admin UI or seed script with full data isolation.
- Deterministic test prevents reintroduction of the single-cohort singleton.
- `py -m pytest -q` and `py -m ruff check .` pass.
