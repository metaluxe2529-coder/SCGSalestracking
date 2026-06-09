-- ============================================================
-- Migration 003: extend staff and shops tables
-- Run in: Supabase Dashboard > SQL Editor
-- ============================================================

-- Staff: split display_name into real name fields + contact info
ALTER TABLE staff
  ADD COLUMN IF NOT EXISTS first_name  TEXT,
  ADD COLUMN IF NOT EXISTS last_name   TEXT,
  ADD COLUMN IF NOT EXISTS nickname    TEXT,
  ADD COLUMN IF NOT EXISTS email       TEXT,
  ADD COLUMN IF NOT EXISTS phone       TEXT;

-- Shops: add shop phone + direct reference to primary responsible staff
ALTER TABLE shops
  ADD COLUMN IF NOT EXISTS shop_phone       TEXT,
  ADD COLUMN IF NOT EXISTS primary_staff_id BIGINT REFERENCES staff(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_shops_primary_staff ON shops(primary_staff_id);
