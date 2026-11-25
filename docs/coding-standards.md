# Coding Standards

Reviewers and agents check every change against these rules before merge.

## 1. Architecture & Deep Modules
- Put domain and business logic in `core/` as **deep modules** (small interface, hidden complexity).
- Keep `api/` (FastAPI routes) and `bot/` (Telegram handlers) as thin **adapters** that validate input, call `core/`, and format output.
- Avoid duplicating business rules across `api/` and `bot/`.

## 2. Dependencies & Packaging
- Every third-party import used by `core/` or `api/` **must** be listed in `requirements.txt`.
- Every third-party import used by `core/` or `bot/` **must** be listed in `requirements-bot.txt`.
- *Why:* Vercel and Orihost install strictly from those files; a missing `python-dotenv` entry previously crashed every Vercel `/api/*` route with HTTP 500.
- Enforced deterministically by `tests/test_requirements_cover_imports.py`.

## 3. Database Migrations (ONE-WAY DOOR)
- Migrations in `supabase/migrations/` are **append-only**, sequentially numbered (`NNNN_slug.sql`), and **idempotent** (`create table if not exists`, `create or replace function`, etc.).
- Never edit a migration that has already been applied to a shared or production database.
- Every migration is a **one-way door** and requires explicit human review before merging or pushing.

## 4. Configuration & Secrets
- Never commit secrets, tokens, or `.env` files to the repository.
- Read all configuration through environment variables in `core/config.py`.

## 5. Multi-Tenant Data Isolation (once ADR-0002 ships)
- Every query, RPC, and write touching tenant-owned data must be explicitly scoped to a **Tenant Scope Node**.
- Never rely on frontend filtering alone; enforce scope and permissions in the database / `core/` layer.

## 6. Testing
- Test modules through their public **interface**, not internal helpers or private state.
- Prefer fast, isolated unit tests in `tests/` using stubs/fakes over brittle mocks coupled to line-by-line implementation details.

## 7. Domain Language
- Use the exact terms defined in `GLOSSARY.md` in code identifiers, SQL tables/columns, API payloads, and UI strings.
- Avoid the listed `_Avoid_` synonyms so humans and agents share one vocabulary.

## 8. Merge Danger Classification
Every review/PR must declare:
- **Door type**: `two-way` (easy to revert) vs `one-way` (migrations, auth/permissions, destructive ops, production bot config).
- **Blast radius**: `small`, `medium`, or `large`.
- **Verification evidence**: test output, lint output, or live check proving the change works.
