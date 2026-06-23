-- ============================================================
-- Migration 010: change GPS check-in/out radius 200m → 500m
-- Replaces checkin_visit and checkout_visit from 002 and 009
-- ============================================================

CREATE OR REPLACE FUNCTION checkin_visit(
  p_line_user_id  TEXT,
  p_shop_id       BIGINT,
  p_lat           NUMERIC,
  p_lng           NUMERIC,
  p_accuracy      NUMERIC DEFAULT NULL,
  p_notes         TEXT    DEFAULT NULL,
  p_photo_url     TEXT    DEFAULT NULL,
  p_assignment_id BIGINT  DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_staff    staff%ROWTYPE;
  v_shop     shops%ROWTYPE;
  v_distance NUMERIC;
  v_visit_id BIGINT;
BEGIN
  SELECT * INTO v_staff FROM staff WHERE line_user_id = p_line_user_id AND is_active = true;
  IF v_staff.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'staff_not_found');
  END IF;

  SELECT * INTO v_shop FROM shops WHERE id = p_shop_id AND is_active = true;
  IF v_shop.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'shop_not_found');
  END IF;

  v_distance := _haversine_meters(p_lat, p_lng, v_shop.lat, v_shop.lng);
  IF v_distance > 500 THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'outside_radius',
      'distance_m', round(v_distance),
      'max_radius_m', 500
    );
  END IF;

  IF EXISTS (
    SELECT 1 FROM visits
    WHERE staff_id = v_staff.id AND shop_id = p_shop_id
      AND checkin_at::DATE = CURRENT_DATE AND status = 'checked_in'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_checked_in_today');
  END IF;

  INSERT INTO visits (
    shop_id, staff_id, assignment_id,
    checkin_lat, checkin_lng, checkin_accuracy,
    checkin_notes, checkin_photo_url
  ) VALUES (
    p_shop_id, v_staff.id, p_assignment_id,
    p_lat, p_lng, p_accuracy,
    p_notes, p_photo_url
  ) RETURNING id INTO v_visit_id;

  PERFORM _send_line_push(
    '📍 Check-in' || chr(10) ||
    v_staff.display_name || ' เยี่ยมร้าน ' || v_shop.name || chr(10) ||
    'เวลา ' || to_char(now() AT TIME ZONE 'Asia/Bangkok', 'HH24:MI') || ' น.'
  );

  RETURN jsonb_build_object(
    'ok', true,
    'visit_id', v_visit_id,
    'distance_m', round(v_distance),
    'shop_name', v_shop.name
  );
END;
$$;

GRANT EXECUTE ON FUNCTION checkin_visit TO anon, authenticated;

-- ──────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION checkout_visit(
  p_line_user_id TEXT,
  p_visit_id     BIGINT,
  p_lat          NUMERIC,
  p_lng          NUMERIC,
  p_accuracy     NUMERIC DEFAULT NULL,
  p_notes        TEXT    DEFAULT NULL,
  p_photo_url    TEXT    DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_staff_id BIGINT;
  v_visit    visits%ROWTYPE;
  v_shop     shops%ROWTYPE;
  v_distance NUMERIC;
BEGIN
  SELECT id INTO v_staff_id FROM staff WHERE line_user_id = p_line_user_id AND is_active = true;
  IF v_staff_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'staff_not_found');
  END IF;

  SELECT * INTO v_visit FROM visits WHERE id = p_visit_id AND staff_id = v_staff_id;
  IF v_visit.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'visit_not_found');
  END IF;
  IF v_visit.status = 'checked_out' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_checked_out');
  END IF;

  SELECT * INTO v_shop FROM shops WHERE id = v_visit.shop_id;

  v_distance := _haversine_meters(p_lat, p_lng, v_shop.lat, v_shop.lng);
  IF v_distance > 500 THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'outside_radius',
      'distance_m', round(v_distance),
      'max_radius_m', 500
    );
  END IF;

  UPDATE visits SET
    checkout_at        = now(),
    checkout_lat       = p_lat,
    checkout_lng       = p_lng,
    checkout_accuracy  = p_accuracy,
    checkout_notes     = p_notes,
    checkout_photo_url = p_photo_url,
    status             = 'checked_out'
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
