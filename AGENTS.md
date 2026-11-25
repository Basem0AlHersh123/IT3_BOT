# AGENTS.md — IT3_Bot (College Edition)

Telegram Bot + Mini App for university college academic management (files, assignments, attendance, MCQ, grievances, sharek).

## Layout
- `core/` — shared Python domain modules (config, cohort, permissions, store, auth, barcode, files, etc.)
- `api/` — FastAPI serverless adapter on Vercel (`/api/*`)
- `bot/` — `python-telegram-bot` polling adapter on Orihost + `worker.py`
- `public/` — Arabic SPA Mini App frontend (`HTML/CSS/Vanilla JS`)
- `supabase/migrations/` — append-only, idempotent Postgres migrations (`0001`–`0016`+)
- `tests/` — automated test suite (`pytest` / `unittest`)

## Key Docs (read before designing or coding)
- [GLOSSARY.md](./GLOSSARY.md) — canonical domain language (use exact terms)
- [docs/adr/](./docs/adr/) — architectural decisions (do not re-litigate without reason)
- [docs/coding-standards.md](./docs/coding-standards.md) — rules for code review and merges

## Checks
```bash
py -m pytest -q
py -m ruff check .
```

## Workflow
1. **Grill** (`grill-with-docs`) — align on requirements, glossary, and ADRs before coding.
2. **Spec & Tickets** — for multi-step work, write a spec and split into single-session tickets (stay in the smart zone).
3. **Implement** — one ticket per fresh session; keep `core/` deep and tested.
4. **Review** — check against the spec, `docs/coding-standards.md`, and merge danger (one-way vs two-way door).
5. **Retro** — turn any mistake into a deterministic check (test/lint/CI) before adding prose rules.
