---
status: accepted (not implemented)
door: one-way
---

# Scoped Role Grants Inheriting Down the Scope Tree

Administrative and academic roles will be modeled as **Scoped Role Grants** of the form `(telegram_id, role, scope_node)`. Powers inherit downward through the **Scope Tree** (a **College Admin** sees all majors; a **Cohort Admin** sees only their cohort and its groups; a **Group Rep** sees only their group), and a single **User** may hold multiple grants across different nodes.

## Considered Options

- **Fixed two-tier admins (college + cohort only)**: cannot delegate practical/theory group responsibilities cleanly.
- **Keep flat global roles and filter in the UI**: insecure and breaks tenant isolation at the database layer.

## Consequences

- Permission checks in PostgreSQL (`require_perm` / `has_perm`) and `core/permissions.py` must evaluate scope ancestry, not just a single `theory_group_id`.
- Existing single-cohort `role_grants` rows will map cleanly onto cohort/theory-group scope nodes during the multi-tenant migration.
