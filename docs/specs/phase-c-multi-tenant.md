# Phase C Specification — Multi-Tenant Scope Tree & Scoped Role Grants

**Status:** Draft (ready for ticketed implementation)  
**Implements:** [ADR-0002](../adr/0002-multi-tenant-scope-tree.md), [ADR-0003](../adr/0003-scoped-role-grants.md)  
**Canonical Vocabulary:** [GLOSSARY.md](../../GLOSSARY.md)  
**Tickets:** [phase-c-tickets.md](./phase-c-tickets.md)

---

## 1. Goal & Non-Goals

### Goal
Transform IT3_Bot from a single-cohort deployment driven by a process-wide `core/cohort.py` singleton (`COHORT_CONFIG_JSON`) into a **multi-tenant College Edition** running on one Telegram bot, one Vercel API, and one Supabase Postgres database. Every tenant-owned record is isolated to a **Tenant Scope Node** in a five-level **Scope Tree**, and every administrative or academic capability is governed by **Scoped Role Grants** that inherit downward. Once Phase C ships, **IT3** launches as Tenant #1, and additional **Majors** and **Cohorts** can be onboarded without code changes or new deployments.

### Non-Goals
- Separate Telegram bots or separate Supabase projects per **Major** (rejected in ADR-0002).
- End-user client-side Supabase access (RLS remains locked with no anon/authenticated policies; all access stays through `service_role` RPCs and `core/`).
- Rewriting the Mini App frontend framework (stays Vanilla JS/HTML/CSS in `public/`).
- Changing Telegram authentication (`initData` HMAC validation in `core/tg_auth.py`).

---

## 2. Five-Level Scope Tree Data Model

### 2.1 Hierarchy & Invariants
The **Scope Tree** has five strict levels:

```text
College (root, parent_id IS NULL)
 └── Major
      └── Cohort
           └── Theory Group
                └── Practical Group (leaf)
```

- Every node is stored in `public.scope_nodes` with a surrogate `bigint` primary key (`id`).
- **Why surrogate `bigint` IDs?** In the single-cohort schema, `practical_groups.code` (`G1..G9`) is a global `text` primary key. Across multiple **Cohorts**, both IT3 and CS3 will have `G1`. Referencing `scope_nodes.id` eliminates cross-cohort code collisions while keeping human-readable `code` unique only within its parent (`(coalesce(parent_id, 0), code)`).
- **Materialized Ancestry (`path bigint[]`)**: Every row stores `path bigint[]` containing `[college_id, ..., self_id]`, maintained automatically by a `BEFORE INSERT OR UPDATE` trigger and indexed with a `GIN` index (`scope_nodes_path_gin_idx`).
  - Ancestor check: `target.path @> ARRAY[ancestor_id]` (O(1) array containment, zero recursive joins).
  - Subtree query: `WHERE path @> ARRAY[ancestor_id]` (uses GIN index).
  - Cohort lookup for any descendant node: `path[3]` (when `array_length(path, 1) >= 3`), wrapped in `scope_cohort_of(p_node bigint)`.
- **Level integrity trigger**: Rejects any insert/update that violates the parent-kind chain (`college` has `parent_id IS NULL`; `major` parent must be `college`; `cohort` parent must be `major`; `theory_group` parent must be `cohort`; `practical_group` parent must be `theory_group`).

### 2.2 `scope_nodes` Schema
```sql
create table if not exists scope_nodes (
  id         bigint generated always as identity primary key,
  kind       text not null check (kind in ('college','major','cohort','theory_group','practical_group')),
  parent_id  bigint references scope_nodes(id) on delete restrict,
  code       text not null,
  name_ar    text not null,
  path       bigint[] not null default '{}',
  meta       jsonb not null default '{}',
  sort       smallint not null default 0,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  check ((kind = 'college' and parent_id is null) or (kind <> 'college' and parent_id is not null))
);
```

- `meta` on a `cohort` node replaces `cohort.json`: `{ "batch": "3", "level": "المستوى الثالث", "theory_prefix": "IT3_G" }`.
- Soft-delete (`deleted_at`) preserves historical records (**Files**, **Attendance Sessions**, **Activity Log**) without breaking foreign keys.

### 2.3 SQL Helper Functions
- `scope_is_ancestor(p_ancestor bigint, p_target bigint) returns boolean` — returns `true` iff `p_ancestor = ANY(target.path)`.
- `scope_cohort_of(p_node bigint) returns bigint` — returns the `cohort` node ID from `p_node`'s path (or `NULL` for `college`/`major`).
- `scope_college_of(p_node bigint) returns bigint` — returns `path[1]`.
- `scope_tree_for_cohort(p_cohort bigint) returns jsonb` — returns the **Cohort** metadata plus its ordered **Theory Groups** and **Practical Groups** (replacing `cohort.get().public()`).

---

## 3. Table Scoping Classification

Every existing table in `supabase/migrations/0001`–`0016` falls into one of four categories:

### 3.1 Global / Platform Tables (Not Tenant-Owned)
| Table | Multi-Tenant Notes |
|---|---|
| `users` | Global per Telegram account. Add `active_cohort_node_id bigint references scope_nodes(id)` for **Guests** and multi-grant admins selecting their active **Cohort**. |
| `doctors` | Global at the **College** level — a **Doctor** can teach **Subjects** across multiple **Cohorts** and **Majors** via `teaching`. |
| `role_permissions` | Global capability matrix; extended with `college_admin`, `cohort_admin`, `group_rep`. |
| `app_settings` | Platform defaults (timezone, reminder hours, grace period, quotas). |
| `data_versions` | Cache invalidation counters; add `scopes` version scope bumped by `scope_nodes` trigger. |
| `outbox`, `notifications`, `user_settings`, `link_attempts`, `ai_cache`, `backup_runs`, `barcode_logs` | Infrastructure or user-keyed tables (`backup_tables()` updated to include `scope_nodes`). |

### 3.2 Hierarchy & Access Tables
| Table | Multi-Tenant Changes |
|---|---|
| `scope_nodes` | New canonical **Scope Tree** table. |
| `theory_groups`, `practical_groups` | Add `scope_node_id bigint unique references scope_nodes(id)` and `cohort_node_id bigint references scope_nodes(id)` during transition so legacy FKs remain valid while code migrates to `scope_nodes.id`. |
| `role_grants` | Add `scope_node_id bigint references scope_nodes(id)` and extend `role` check constraint for **Scoped Role Grants** (see §4). |

### 3.3 Cohort-Owned Tables (Scoped by `cohort_node_id`)
| Table | Scope Column(s) & Constraint Changes |
|---|---|
| `subjects` | Add `cohort_node_id`. Replace global `unique(name_ar)` with `unique(cohort_node_id, name_ar) where deleted_at is null`. |
| `files` | Add `cohort_node_id` (and optional `group_node_id`). |
| `mcq_exams` | Add `cohort_node_id`. (`mcq_questions`, `mcq_attempts` inherit via `exam_id`.) |
| `drafts` | Add `cohort_node_id` (and optional `scope_node_id`). |
| `tg_destinations` | Add `scope_node_id` (defaults to `cohort_node_id` or `theory_node_id`). Replace single-column PK `key` with surrogate `id` + `unique(scope_node_id, key)`. |
| `report_templates` | Add `cohort_node_id`. |
| `support_tickets` | Add `cohort_node_id`. |
| `assistant_logs` | Add `cohort_node_id`. |
| `activity_log` | Add nullable `scope_node_id` (NULL for platform-wide `developer` actions; set to the affected **Tenant Scope Node** for all tenant actions). |

### 3.4 Group-Owned Tables (Scoped by `theory_node_id` / `practical_node_id` / `scope_node_id`)
| Table | Scope Column(s) & Inheritance |
|---|---|
| `students` | Add `cohort_node_id`, `theory_node_id`, `practical_node_id`. Every student's `practical_node_id` must have `parent_id = theory_node_id`, and `theory_node_id` must have `parent_id = cohort_node_id`. |
| `teaching` | Add `scope_node_id` (`theory_group` or `practical_group` node). Unique index on `(subject_id, scope_node_id)`. |
| `assignments` | Add `cohort_node_id`, `scope_node_id` (`theory_group`, `practical_group`, or `cohort`). (`assignment_files`, `submissions`, `submission_files`, `submission_deliveries`, `reminders_sent` inherit via `assignment_id`.) |
| `attendance_sessions` | Add `cohort_node_id`, `theory_node_id`. (`scanner_devices`, `attendance_records`, `attendance_corrections` inherit via `session_id`.) |
| `grievance_cycles` | Add `cohort_node_id`, `theory_node_id`. (`grievances` inherit via `cycle_id`.) |
| `daily_reports`, `weekly_reports`, `report_reminders_sent` | Add `cohort_node_id`, `theory_node_id`. |
| `sharek_campaigns` | Add `cohort_node_id`, `theory_node_id`. (`sharek_votes`, `sharek_items`, `sharek_sessions` inherit via `campaign_id`.) |

---

## 4. Scoped Role Grants & Permission Model (ADR-0003)

### 4.1 Role Taxonomy
| Role | Allowed `scope_node.kind` | Authority |
|---|---|---|
| `developer` | `NULL` (platform root) | Full platform access across all **Colleges**, backups, global settings. |
| `college_admin` | `college` | **College Admin**: manages all **Majors**, **Cohorts**, **Theory Groups**, **Practical Groups**, **Students**, **Doctors**, **Subjects**, **Telegram Destinations**, and **Scoped Role Grants** inside their **College** (cannot grant/revoke `developer`). |
| `cohort_admin` | `cohort` | **Cohort Admin**: manages their **Cohort** and its descendant groups, **Students**, **Subjects**, **Files**, **MCQs**, **Telegram Destinations**, and group-level **Scoped Role Grants** (cannot grant `college_admin` or `developer`). |
| `delegate` | `theory_group` or `cohort` | Existing group delegate capabilities scoped to their assigned node and descendants. |
| `deputy` | `theory_group` or `practical_group` | Existing deputy capabilities (including `delegate_absent` conditional powers) scoped to their assigned node. |
| `committee` | `cohort` or `theory_group` | Scientific committee capabilities (**Files**, **MCQs**, **Assignments**, **Reports**, **Sharek**) scoped to their assigned node and descendants. |
| `group_rep` | `theory_group` or `practical_group` | **Group Rep**: canonical group-level management role for new multi-tenant deployments. |

### 4.2 Permission Evaluation Rules (SQL + Python Parity)
In PostgreSQL (`has_perm(p_tg, p_key, p_scope_node_id, p_delegate_absent)`) and `core/permissions.py`:

1. **Banned check**: If `users.is_banned = true`, return `false`.
2. **Base role (`student`, `guest`, `doctor`)**:
   - `own` permissions apply to the user's own records.
   - `cohort`-scoped read permissions (`files.view`, `mcq.take`) apply only when `p_scope_node_id` matches the user's active **Cohort** (the **Student**'s `cohort_node_id`, or the **Guest**'s `active_cohort_node_id`).
3. **Scoped Role Grants**:
   - A grant `(telegram_id, role, grant_scope_node_id)` satisfies `(p_key, p_scope_node_id)` when:
     - `role_permissions` grants `p_key` to `role`, AND
     - `condition` is `NULL` or satisfied (`delegate_absent`), AND
     - Either `role = 'developer'` (`grant_scope_node_id IS NULL`), OR `p_scope_node_id IS NULL` (UI visibility check), OR `scope_is_ancestor(grant_scope_node_id, p_scope_node_id)` is `true`.
4. **No privilege escalation**:
   - `grant_role(p_actor, p_target, p_role, p_scope_node_id)` requires `roles.manage` on `p_scope_node_id` **and** enforces rank hierarchy (`developer > college_admin > cohort_admin > group roles`).
   - `revoke_role(p_actor, p_grant_id)` requires `roles.manage` on the target grant's `scope_node_id` and preserves the `last_developer` guard.

### 4.3 Migration of Existing Single-Cohort Grants
During migration `0019_scoped_role_grants.sql`:
- `developer` grants keep `scope_node_id = NULL`.
- Existing `delegate`, `deputy`, `committee` grants with `theory_group_id` map 1:1 to `theory_groups.scope_node_id`.
- `role_grants_active_uq` becomes `unique (telegram_id, role, coalesce(scope_node_id, 0)) where revoked_at is null`.

---

## 5. Deep Module Architecture (`core/`)

Per `docs/coding-standards.md`, all multi-tenant resolution and permission logic lives in `core/` as deep modules; `api/` and `bot/` remain thin adapters:

- **`core/scope.py`** (new deep module):
  - `ScopeNode`: immutable representation of a **Tenant Scope Node** (`id`, `kind`, `parent_id`, `code`, `name_ar`, `path`, `meta`, `sort`).
  - `CohortContext`: constructed from a `cohort` `ScopeNode` and its child **Theory Groups** and **Practical Groups**. Exposes `title`, `student_noun`, `students_noun`, `theory_nodes`, `practical_nodes`, `practical_of(theory_node_id)`, `normalize_theory(text)`, `normalize_practical(text)`, and `public()`.
  - `ScopeResolver`: fetches and caches the **Scope Tree** from `Store`, keyed by `data_versions['scopes']`, resolving any `cohort_node_id` or `scope_node_id` to its `CohortContext` without process-wide singletons.
- **`core/permissions.py`** (upgraded):
  - Evaluates **Scoped Role Grants** using `scope_node_id` and `path` arrays returned by `app_bootstrap`.
  - Exposes `can(perms, key, *, scope_node_id=None, target_path=None, delegate_absent=False)` and `allowed_nodes(perms, key, candidate_nodes, *, delegate_absent=False)`.
- **`core/cohort.py`** (deprecated & removed at Ticket C8):
  - Replaced everywhere by `core/scope.py`. A deterministic test in `tests/` will enforce that no runtime module in `core/`, `api/`, or `bot/` imports `core.cohort`.

---

## 6. User Journeys & Context Resolution

| User Kind | Active Scope Resolution | Cross-Cohort Behavior |
|---|---|---|
| **Student** | Bound to `students.cohort_node_id`, `theory_node_id`, `practical_node_id`. | Strictly isolated to their own **Cohort** and group; cannot read or submit to another **Cohort**. |
| **Guest** | Picks **Major** → **Cohort** during registration (`users.active_cohort_node_id`); can switch **Cohort** in Mini App/Bot settings. | Sees public **Files** and **MCQs** only for their currently selected **Cohort**. |
| **Doctor** | Global `doctors` record; sees all **Subjects** and **Assignments** linked via `teaching` across **Cohorts**. | Each item is labeled with its **Cohort** and group name; cannot view unrelated **Cohorts**. |
| **College Admin / Cohort Admin / Multi-Grant User** | Defaults to highest-priority grant's **Cohort** (or `users.active_cohort_node_id`); can switch active **Cohort** via Scope Switcher within their granted subtree. | All queries and admin mutations pass the explicit `cohort_node_id` / `scope_node_id`, verified in Postgres. |

---

## 7. Security, Isolation & Verification Strategy

1. **Database-layer enforcement**: Every tenant-owned RPC accepts or derives `p_cohort_node_id` / `p_scope_node_id` and calls `require_perm(p_actor, p_key, p_scope_node_id)` before reading or mutating rows.
2. **Negative cross-tenant tests**: Automated tests explicitly verify that:
   - A **Student** in Cohort A cannot access **Files**, **Assignments**, **Attendance Sessions**, **Grievances**, **Sharek**, or **MCQs** in Cohort B.
   - A **Cohort Admin** in Cohort A receives `403 forbidden` when mutating resources or granting roles in Cohort B.
   - A **College Admin** can manage both Cohort A and Cohort B under their **College**, but cannot grant `developer`.
   - Two **Cohorts** with identical **Practical Group** codes (`G1`) do not collide in student linking, **Teaching**, **Assignments**, or **Telegram Destinations**.
3. **One-way door discipline**: Every SQL migration (`0017`–`0020`) is append-only, idempotent, and flagged as a **one-way door** requiring human review before applying to Supabase.
