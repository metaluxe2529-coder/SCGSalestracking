# SCG Sales Tracking — Claude Instructions

## Permissions
- All tools run without prompting (bypassPermissions is set in .claude/settings.json)
- Run bash, read/write files, call Supabase REST API freely
- Write and run SQL (migrations, ALTER TABLE, INSERT, UPDATE, DELETE) without asking for permission

## Project Stack
- Frontend: Vanilla HTML/CSS/JS (no framework), files in `webhtml/`
- Backend: Supabase (PostgreSQL + REST API + RLS)
- Auth: LINE LIFF
- Deploy: Vercel (static)

## Supabase
- URL: `https://vuqcoadeexyqmaoldkzt.supabase.co`
- Anon key is in each HTML file — reuse it, do not hardcode elsewhere
- Schema is in `db/001_schema.sql`, RLS/RPCs in `db/002_rls_and_rpcs.sql`
- Run SQL via REST API (`/rest/v1/`) or Dashboard SQL Editor

## Coding Rules

### Low blast radius
- One file = one concern. Never mix auth, data-fetch, and UI logic in one block
- Edit the smallest possible scope — don't rewrite a whole file to fix one function
- Keep each `<script>` section under ~150 lines; split into functions if longer
- Never modify shared helpers without checking all callers first

### Clean code
- No comments unless the WHY is non-obvious
- Name functions and variables so they read like sentences (`loadStaffList`, `markVisitCheckedOut`)
- Prefer `async/await` over `.then()` chains
- Validate inputs at the boundary (user action / API response), not deep inside logic

### Error handling
- Every Supabase call must check `if (error)` and surface a user-visible message
- Never silently swallow errors with empty `catch {}`
- Show errors in the UI — not just `console.error`

### HTML/CSS
- Keep styles scoped in `<style>` inside each file — no global stylesheet changes
- Use semantic HTML (`<button>`, `<form>`, `<table>`) not `<div>` for everything
- **Mobile only design** — every page is designed exclusively for mobile devices (max-width 480px), no desktop layout needed
- Mobile-first: test at 390px width

### SQL / Migrations
- New column: `ALTER TABLE <table> ADD COLUMN <name> <type>;`
- New rows: INSERT with explicit column list, never `INSERT INTO table VALUES (...)`
- Always add `WHERE` clause on UPDATE/DELETE — never bare updates
- New migration files go in `db/` with incremented prefix, e.g. `db/003_add_phone.sql`
