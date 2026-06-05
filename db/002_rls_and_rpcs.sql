-- ============================================================
-- SCG Sales Tracking — RLS Policies + RPCs
-- Run this AFTER 001_schema.sql
-- ============================================================

-- Enable RLS on all tables
ALTER TABLE staff ENABLE ROW LEVEL SECURITY;
ALTER TABLE shops ENABLE ROW LEVEL SECURITY;
ALTER TABLE assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE visits ENABLE ROW LEVEL SECURITY;

-- Allow anon to call RPCs (LIFF has no Supabase auth session)
-- All auth is handled inside SECURITY DEFINER RPCs via line_user_id

-- Staff: anyone can read (needed for manager dropdowns)
CREATE POLICY staff_public_read ON staff FOR SELECT USING (true);
CREATE POLICY staff_service_write ON staff FOR ALL USING (auth.uid() IS NULL);

-- Shops: anyone can read active shops
CREATE POLICY shops_public_read ON shops FOR SELECT USING (is_active = true);
CREATE POLICY shops_service_write ON shops FOR ALL USING (auth.uid() IS NULL);

-- Assignments: anyone can read
CREATE POLICY assignments_public_read ON assignments FOR SELECT USING (true);
CREATE POLICY assignments_service_write ON assignments FOR ALL USING (auth.uid() IS NULL);

-- Visits: anyone can read
CREATE POLICY visits_public_read ON visits FOR SELECT USING (true);
CREATE POLICY visits_service_write ON visits FOR ALL USING (auth.uid() IS NULL);

-- Storage bucket for visit photos
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('visit-photos', 'visit-photos', true, 10485760, ARRAY['image/jpeg','image/png','image/webp'])
ON CONFLICT (id) DO NOTHING;

CREATE POLICY visit_photos_public_read ON storage.objects FOR SELECT USING (bucket_id = 'visit-photos');
CREATE POLICY visit_photos_anon_upload ON storage.objects FOR INSERT WITH CHECK (bucket_id = 'visit-photos');

-- ============================================================
-- RPC: upsert_staff_from_liff
-- Called on every page load to register/fetch the LINE user
-- ============================================================
CREATE OR REPLACE FUNCTION upsert_staff_from_liff(
  p_line_user_id TEXT,
  p_display_name TEXT,
  p_picture_url TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_staff staff%ROWTYPE;
BEGIN
  IF p_line_user_id IS NULL OR trim(p_line_user_id) = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'line_user_id_required');
  END IF;

  -- Upsert staff row
  INSERT INTO staff (line_user_id, display_name, picture_url, role)
  VALUES (p_line_user_id, p_display_name, p_picture_url, 'sales')
  ON CONFLICT (line_user_id) DO UPDATE
    SET display_name = EXCLUDED.display_name,
        picture_url  = COALESCE(EXCLUDED.picture_url, staff.picture_url),
        updated_at   = now()
  RETURNING * INTO v_staff;

  RETURN jsonb_build_object(
    'ok', true,
    'staff_id', v_staff.id,
    'role', v_staff.role,
    'display_name', v_staff.display_name,
    'picture_url', v_staff.picture_url,
    'is_active', v_staff.is_active
  );
END;
$$;

GRANT EXECUTE ON FUNCTION upsert_staff_from_liff TO anon, authenticated;

-- ============================================================
-- RPC: get_sales_dashboard
-- Returns today's assigned shops + visit status for a salesperson
-- ============================================================
CREATE OR REPLACE FUNCTION get_sales_dashboard(
  p_line_user_id TEXT,
  p_date DATE DEFAULT CURRENT_DATE
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_staff_id BIGINT;
  v_result   JSONB;
BEGIN
  SELECT id INTO v_staff_id FROM staff WHERE line_user_id = p_line_user_id AND is_active = true;
  IF v_staff_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'staff_not_found');
  END IF;

  SELECT jsonb_build_object(
    'ok', true,
    'date', p_date,
    'shops', COALESCE(jsonb_agg(
      jsonb_build_object(
        'assignment_id', a.id,
        'shop_id', s.id,
        'shop_name', s.name,
        'shop_address', s.address,
        'shop_lat', s.lat,
        'shop_lng', s.lng,
        'contact_name', s.contact_name,
        'contact_phone', s.contact_phone,
        'visit_id', v.id,
        'visit_status', v.status,
        'checkin_at', v.checkin_at,
        'checkout_at', v.checkout_at
      ) ORDER BY a.id
    ), '[]'::jsonb)
  )
  INTO v_result
  FROM assignments a
  JOIN shops s ON s.id = a.shop_id AND s.is_active = true
  LEFT JOIN visits v ON v.shop_id = a.shop_id
    AND v.staff_id = v_staff_id
    AND v.checkin_at::DATE = p_date
  WHERE a.staff_id = v_staff_id
    AND a.assigned_date = p_date
    AND a.is_active = true;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION get_sales_dashboard TO anon, authenticated;

-- ============================================================
-- Helper: haversine distance in meters
-- ============================================================
CREATE OR REPLACE FUNCTION _haversine_meters(
  lat1 NUMERIC, lng1 NUMERIC,
  lat2 NUMERIC, lng2 NUMERIC
) RETURNS NUMERIC
LANGUAGE sql IMMUTABLE AS $$
  SELECT 6371000 * 2 * asin(sqrt(
    sin(radians((lat2 - lat1) / 2)) ^ 2 +
    cos(radians(lat1)) * cos(radians(lat2)) *
    sin(radians((lng2 - lng1) / 2)) ^ 2
  ))
$$;

-- ============================================================
-- RPC: checkin_visit
-- GPS-validated check-in within 200m of shop
-- ============================================================
CREATE OR REPLACE FUNCTION checkin_visit(
  p_line_user_id TEXT,
  p_shop_id BIGINT,
  p_lat NUMERIC,
  p_lng NUMERIC,
  p_accuracy NUMERIC DEFAULT NULL,
  p_notes TEXT DEFAULT NULL,
  p_photo_url TEXT DEFAULT NULL,
  p_assignment_id BIGINT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_staff_id  BIGINT;
  v_shop      shops%ROWTYPE;
  v_distance  NUMERIC;
  v_visit_id  BIGINT;
BEGIN
  -- Resolve staff
  SELECT id INTO v_staff_id FROM staff WHERE line_user_id = p_line_user_id AND is_active = true;
  IF v_staff_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'staff_not_found');
  END IF;

  -- Resolve shop
  SELECT * INTO v_shop FROM shops WHERE id = p_shop_id AND is_active = true;
  IF v_shop.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'shop_not_found');
  END IF;

  -- GPS validation: must be within 200m
  v_distance := _haversine_meters(p_lat, p_lng, v_shop.lat, v_shop.lng);
  IF v_distance > 200 THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'outside_radius',
      'distance_m', round(v_distance),
      'max_radius_m', 200
    );
  END IF;

  -- Block double check-in on the same day at the same shop
  IF EXISTS (
    SELECT 1 FROM visits
    WHERE staff_id = v_staff_id
      AND shop_id = p_shop_id
      AND checkin_at::DATE = CURRENT_DATE
      AND status = 'checked_in'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_checked_in_today');
  END IF;

  -- Insert visit
  INSERT INTO visits (
    shop_id, staff_id, assignment_id,
    checkin_lat, checkin_lng, checkin_accuracy,
    checkin_notes, checkin_photo_url
  ) VALUES (
    p_shop_id, v_staff_id, p_assignment_id,
    p_lat, p_lng, p_accuracy,
    p_notes, p_photo_url
  ) RETURNING id INTO v_visit_id;

  RETURN jsonb_build_object(
    'ok', true,
    'visit_id', v_visit_id,
    'distance_m', round(v_distance),
    'shop_name', v_shop.name
  );
END;
$$;

GRANT EXECUTE ON FUNCTION checkin_visit TO anon, authenticated;

-- ============================================================
-- RPC: checkout_visit
-- GPS-validated check-out within 200m of shop
-- ============================================================
CREATE OR REPLACE FUNCTION checkout_visit(
  p_line_user_id TEXT,
  p_visit_id BIGINT,
  p_lat NUMERIC,
  p_lng NUMERIC,
  p_accuracy NUMERIC DEFAULT NULL,
  p_notes TEXT DEFAULT NULL,
  p_photo_url TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_staff_id BIGINT;
  v_visit    visits%ROWTYPE;
  v_shop     shops%ROWTYPE;
  v_distance NUMERIC;
BEGIN
  -- Resolve staff
  SELECT id INTO v_staff_id FROM staff WHERE line_user_id = p_line_user_id AND is_active = true;
  IF v_staff_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'staff_not_found');
  END IF;

  -- Resolve visit (must belong to this staff and be checked_in)
  SELECT * INTO v_visit FROM visits WHERE id = p_visit_id AND staff_id = v_staff_id;
  IF v_visit.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'visit_not_found');
  END IF;
  IF v_visit.status = 'checked_out' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_checked_out');
  END IF;

  -- Resolve shop
  SELECT * INTO v_shop FROM shops WHERE id = v_visit.shop_id;

  -- GPS validation: must be within 200m
  v_distance := _haversine_meters(p_lat, p_lng, v_shop.lat, v_shop.lng);
  IF v_distance > 200 THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'outside_radius',
      'distance_m', round(v_distance),
      'max_radius_m', 200
    );
  END IF;

  -- Update visit
  UPDATE visits SET
    checkout_at       = now(),
    checkout_lat      = p_lat,
    checkout_lng      = p_lng,
    checkout_accuracy = p_accuracy,
    checkout_notes    = p_notes,
    checkout_photo_url = p_photo_url,
    status            = 'checked_out'
  WHERE id = p_visit_id;

  RETURN jsonb_build_object(
    'ok', true,
    'visit_id', p_visit_id,
    'distance_m', round(v_distance),
    'shop_name', v_shop.name,
    'duration_minutes', round(extract(epoch FROM (now() - v_visit.checkin_at)) / 60)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION checkout_visit TO anon, authenticated;

-- ============================================================
-- RPC: get_visit_history (manager view)
-- ============================================================
CREATE OR REPLACE FUNCTION get_visit_history(
  p_from DATE DEFAULT CURRENT_DATE - 7,
  p_to DATE DEFAULT CURRENT_DATE,
  p_staff_id BIGINT DEFAULT NULL,
  p_shop_id BIGINT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_result JSONB;
BEGIN
  SELECT jsonb_build_object(
    'ok', true,
    'visits', COALESCE(jsonb_agg(
      jsonb_build_object(
        'visit_id', v.id,
        'staff_name', st.display_name,
        'staff_picture', st.picture_url,
        'shop_name', sh.name,
        'shop_address', sh.address,
        'checkin_at', v.checkin_at,
        'checkout_at', v.checkout_at,
        'checkin_notes', v.checkin_notes,
        'checkout_notes', v.checkout_notes,
        'checkin_photo_url', v.checkin_photo_url,
        'checkout_photo_url', v.checkout_photo_url,
        'status', v.status,
        'checkin_lat', v.checkin_lat,
        'checkin_lng', v.checkin_lng,
        'duration_minutes', CASE
          WHEN v.checkout_at IS NOT NULL
          THEN round(extract(epoch FROM (v.checkout_at - v.checkin_at)) / 60)
          ELSE NULL
        END
      ) ORDER BY v.checkin_at DESC
    ), '[]'::jsonb)
  )
  INTO v_result
  FROM visits v
  JOIN staff st ON st.id = v.staff_id
  JOIN shops sh ON sh.id = v.shop_id
  WHERE v.checkin_at::DATE BETWEEN p_from AND p_to
    AND (p_staff_id IS NULL OR v.staff_id = p_staff_id)
    AND (p_shop_id IS NULL OR v.shop_id = p_shop_id);

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION get_visit_history TO anon, authenticated;

-- ============================================================
-- RPC: import_shops (manager imports CSV rows)
-- ============================================================
CREATE OR REPLACE FUNCTION import_shops(
  p_line_user_id TEXT,
  p_shops JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_staff     staff%ROWTYPE;
  v_shop      JSONB;
  v_inserted  INT := 0;
  v_skipped   INT := 0;
BEGIN
  -- Only managers can import
  SELECT * INTO v_staff FROM staff WHERE line_user_id = p_line_user_id AND is_active = true;
  IF v_staff.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'staff_not_found');
  END IF;
  IF v_staff.role <> 'manager' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'manager_only');
  END IF;

  FOR v_shop IN SELECT * FROM jsonb_array_elements(p_shops)
  LOOP
    BEGIN
      INSERT INTO shops (name, address, lat, lng, contact_name, contact_phone, imported_by)
      VALUES (
        v_shop->>'name',
        v_shop->>'address',
        (v_shop->>'lat')::NUMERIC,
        (v_shop->>'lng')::NUMERIC,
        v_shop->>'contact_name',
        v_shop->>'contact_phone',
        v_staff.id
      );
      v_inserted := v_inserted + 1;
    EXCEPTION WHEN OTHERS THEN
      v_skipped := v_skipped + 1;
    END;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'inserted', v_inserted, 'skipped', v_skipped);
END;
$$;

GRANT EXECUTE ON FUNCTION import_shops TO anon, authenticated;

-- ============================================================
-- RPC: create_assignment (manager assigns shop to salesperson)
-- ============================================================
CREATE OR REPLACE FUNCTION create_assignment(
  p_line_user_id TEXT,
  p_shop_id BIGINT,
  p_staff_id BIGINT,
  p_assigned_date DATE
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_manager staff%ROWTYPE;
  v_asgn_id BIGINT;
BEGIN
  SELECT * INTO v_manager FROM staff WHERE line_user_id = p_line_user_id AND is_active = true;
  IF v_manager.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'staff_not_found');
  END IF;
  IF v_manager.role <> 'manager' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'manager_only');
  END IF;

  INSERT INTO assignments (shop_id, staff_id, assigned_by, assigned_date)
  VALUES (p_shop_id, p_staff_id, v_manager.id, p_assigned_date)
  ON CONFLICT (shop_id, staff_id, assigned_date) DO UPDATE SET is_active = true
  RETURNING id INTO v_asgn_id;

  RETURN jsonb_build_object('ok', true, 'assignment_id', v_asgn_id);
END;
$$;

GRANT EXECUTE ON FUNCTION create_assignment TO anon, authenticated;

-- ============================================================
-- RPC: delete_assignment
-- ============================================================
CREATE OR REPLACE FUNCTION delete_assignment(
  p_line_user_id TEXT,
  p_assignment_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_manager staff%ROWTYPE;
BEGIN
  SELECT * INTO v_manager FROM staff WHERE line_user_id = p_line_user_id AND is_active = true;
  IF v_manager.id IS NULL OR v_manager.role <> 'manager' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'manager_only');
  END IF;

  UPDATE assignments SET is_active = false WHERE id = p_assignment_id;
  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION delete_assignment TO anon, authenticated;
