---
status: accepted
door: one-way
---

# Runtime Topology: Vercel FastAPI + Orihost Polling Bot + Supabase

We run the Mini App and HTTP API (`api/` + `public/`) on Vercel serverless functions, the Telegram bot (`bot/`) as a long-running polling process on Orihost, and all relational state in Supabase Postgres. Uploaded study files and submissions are stored on Telegram via `tg_file_id` rather than in our own object storage, keeping our hosting costs near zero while comfortably serving ~1,500 students.

## Considered Options

- **Single VPS hosting API, bot, and file storage**: higher ops burden and storage costs for our student-budget deployment.
- **Webhook-only bot on Vercel**: complicates stateful upload flows, polling workers (`outbox`), and long-running Telegram interactions.

## Consequences

- File bytes do not consume Supabase or Vercel storage; Telegram hosts them.
- The real scaling limits to monitor are Vercel function invocations, Telegram rate limits (~30 msg/s, mitigated by `outbox`), and the single Orihost polling process.
- Both `requirements.txt` (Vercel) and `requirements-bot.txt` (Orihost) must stay in sync with every third-party import used in `core/`.
