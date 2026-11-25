---
status: accepted (not implemented)
door: one-way
---

# Multi-Tenant Scope Tree for the College Edition

To serve all 6–7 majors in the college (IT, CS, Graphics, Cybersecurity, AI, IS, etc.) under limited hosting resources, we will run one Telegram bot and one Supabase database organized around a five-level **Scope Tree**: `College → Major → Cohort → Theory Group → Practical Group`. Every tenant-owned record will reference a **Tenant Scope Node** so data is strictly isolated per tenant without duplicating deployments.

## Considered Options

- **Separate bot + Vercel + Supabase per major**: zero refactor, but 7× the operational overhead and no college-wide management view.
- **Launch IT3 on single-cohort schema and migrate live users later**: painful, error-prone data migration once real students are onboarded.

## Consequences

- Current `core/cohort.py` (process-wide singleton from `COHORT_CONFIG_JSON`) must be replaced by database-backed scope resolution.
- IT3 may be deployed on the current single-cohort code as a learning baseline only; real students will not be onboarded until this schema refactor ships.
- IT3 will launch as tenant #1 once the scope tree is in place.
