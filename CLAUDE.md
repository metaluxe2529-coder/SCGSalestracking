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
- Live URL: `https://scg-salestracking.vercel.app/`
- GitHub: `https://github.com/metaluxe2529-coder/SCGSalestracking`

## Supabase
- URL: `https://vuqcoadeexyqmaoldkzt.supabase.co`
- Anon key is in each HTML file — reuse it, do not hardcode elsewhere
- Schema is in `db/001_schema.sql`, RLS/RPCs in `db/002_rls_and_rpcs.sql`
- Run SQL via REST API (`/rest/v1/`) or Dashboard SQL Editor

## Database Tables
- `staff` — LINE users, role `'sales' | 'manager'`, is_active
- `shops` — prospect shops with GPS (lat/lng), imported_by → staff.id
- `assignments` — shop_id + staff_id + assigned_date (UNIQUE together)
- `visits` — check-in/out records; status `'checked_in' | 'checked_out'`; has `checkin_photo_url`, `checkout_photo_url`
- `sale_records` — visit result `'purchased' | 'not_purchased' | 'appointment'`
- `sale_record_items` — line items per sale_record
- `app_config` — key/value config (`line_channel_token` stored here)

## Key RPCs (POST `/rest/v1/rpc/<name>`)
- `checkin_visit` — GPS-validates 500m radius, notifies managers via LINE, saves photo URL
- `checkout_visit` — GPS-validates 500m radius, marks visit checked_out
- `save_sale_record` — saves visit result + items atomically
- `get_sales_dashboard` — today's assigned shops + visit status for a salesperson
- `get_visit_history` — manager view of all visits with photos
- `sales_add_shop` — sales creates new shop, triggers LINE notify
- `link_line_id` — links LINE user to staff record

## Pages
| File | Role | Purpose |
|------|------|---------|
| `webhtml/index.html` | all | LIFF login + redirect by role |
| `webhtml/register.html` | all | First-time registration |
| `webhtml/sales.html` | sales | My shops, check-in/out, sale records |
| `webhtml/manager.html` | manager | Dashboard, staff management, assignments, visit history |
| `webhtml/customer_list.html` | manager | Shop/customer list, add shops |
| `tools/migrate_customers.html` | admin | One-time CSV import tool |

## LINE LIFF
- LIFF ID: `2010342819-X8uSIn0R` (same for all pages)
- Auth flow: `liff.init()` → `liff.getProfile()` → lookup staff by `line_user_id`
- LINE channel token stored in `app_config` table (key: `line_channel_token`)
- LINE IDs starting with `U` = real; `sp_*` = placeholder (not linked yet)

## Business Rules
- **GPS radius: 500m** — both check-in and check-out; all RPCs must use 500 and return `max_radius_m: 500`
- Sales can only see/visit their own assigned shops
- Managers see all data regardless of staff_id filter
- LINE push notifications sent to all active managers on check-in and new shop added
- Timezone: `Asia/Bangkok` (UTC+7) used in all `to_char` calls

## Photo Capture (visits)
- Use `<input type="file" accept="image/*" capture="environment">` — rear camera, no gallery picker
- Compress before upload: resize max-side ≤ 1200px, JPEG quality 0.8 via Canvas API (`canvas.toBlob('image/jpeg', 0.8)`)
- Never send the raw `File` object — always compress first
- Storage bucket: `visit-photos` (public read, anon upload, 10MB limit) — created in `db/002_rls_and_rpcs.sql`
- Upload path: `visits/{staff_id}/{Date.now()}.jpg`
- Public URL: `${SUPABASE_URL}/storage/v1/object/public/visit-photos/{path}`
- Pass the URL as `p_photo_url` to `checkin_visit` / `checkout_visit`

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
- Latest migration: `db/009_line_notify.sql` — next is `db/010_...sql`
