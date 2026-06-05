-- ============================================================
-- SCG Sales Tracking — Initial Schema
-- Run this in: Supabase Dashboard > SQL Editor
-- ============================================================

-- Staff (LINE users with roles)
CREATE TABLE staff (
  id BIGSERIAL PRIMARY KEY,
  line_user_id TEXT UNIQUE NOT NULL,
  display_name TEXT NOT NULL,
  picture_url TEXT,
  role TEXT NOT NULL CHECK (role IN ('sales', 'manager')),
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Shops (prospect shops with GPS coordinates)
CREATE TABLE shops (
  id BIGSERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  address TEXT,
  lat NUMERIC(10,7) NOT NULL,
  lng NUMERIC(10,7) NOT NULL,
  contact_name TEXT,
  contact_phone TEXT,
  imported_by BIGINT REFERENCES staff(id) ON DELETE SET NULL,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Assignments (which salesperson visits which shop on which date)
CREATE TABLE assignments (
  id BIGSERIAL PRIMARY KEY,
  shop_id BIGINT NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  staff_id BIGINT NOT NULL REFERENCES staff(id) ON DELETE CASCADE,
  assigned_by BIGINT REFERENCES staff(id) ON DELETE SET NULL,
  assigned_date DATE NOT NULL,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (shop_id, staff_id, assigned_date)
);

-- Visits (check-in / check-out records with GPS + notes + photo)
CREATE TABLE visits (
  id BIGSERIAL PRIMARY KEY,
  shop_id BIGINT NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  staff_id BIGINT NOT NULL REFERENCES staff(id) ON DELETE CASCADE,
  assignment_id BIGINT REFERENCES assignments(id) ON DELETE SET NULL,
  checkin_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  checkin_lat NUMERIC(10,7) NOT NULL,
  checkin_lng NUMERIC(10,7) NOT NULL,
  checkin_accuracy NUMERIC,
  checkin_notes TEXT,
  checkin_photo_url TEXT,
  checkout_at TIMESTAMPTZ,
  checkout_lat NUMERIC(10,7),
  checkout_lng NUMERIC(10,7),
  checkout_accuracy NUMERIC,
  checkout_notes TEXT,
  checkout_photo_url TEXT,
  status TEXT NOT NULL CHECK (status IN ('checked_in', 'checked_out')) DEFAULT 'checked_in',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Indexes for performance
CREATE INDEX idx_assignments_staff_date ON assignments(staff_id, assigned_date);
CREATE INDEX idx_assignments_shop ON assignments(shop_id);
CREATE INDEX idx_visits_staff ON visits(staff_id);
CREATE INDEX idx_visits_shop ON visits(shop_id);
CREATE INDEX idx_visits_checkin_at ON visits(checkin_at DESC);
CREATE INDEX idx_staff_line_user_id ON staff(line_user_id);