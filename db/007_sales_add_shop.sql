-- ============================================================
-- SCG Sales Tracking — RPC: sales_add_shop
-- Allows any active salesperson to add a new shop and
-- create an assignment for themselves today.
-- Run in: Supabase Dashboard > SQL Editor
-- ============================================================

CREATE OR REPLACE FUNCTION sales_add_shop(
  p_line_user_id  TEXT,
  p_name          TEXT,
  p_address       TEXT DEFAULT NULL,
  p_lat           NUMERIC,
  p_lng           NUMERIC,
  p_accuracy      NUMERIC DEFAULT NULL,
  p_contact_name  TEXT DEFAULT NULL,
  p_contact_phone TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_staff    staff%ROWTYPE;
  v_shop_id  BIGINT;
  v_asgn_id  BIGINT;
BEGIN
  SELECT * INTO v_staff FROM staff WHERE line_user_id = p_line_user_id AND is_active = true;
  IF v_staff.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'staff_not_found');
  END IF;

  IF p_name IS NULL OR trim(p_name) = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'name_required');
  END IF;

  INSERT INTO shops (name, address, lat, lng, contact_name, contact_phone, imported_by)
  VALUES (trim(p_name), p_address, p_lat, p_lng, p_contact_name, p_contact_phone, v_staff.id)
  RETURNING id INTO v_shop_id;

  INSERT INTO assignments (shop_id, staff_id, assigned_by, assigned_date)
  VALUES (v_shop_id, v_staff.id, v_staff.id, CURRENT_DATE)
  ON CONFLICT (shop_id, staff_id, assigned_date) DO UPDATE SET is_active = true
  RETURNING id INTO v_asgn_id;

  RETURN jsonb_build_object(
    'ok', true,
    'shop_id', v_shop_id,
    'assignment_id', v_asgn_id,
    'shop_name', trim(p_name)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sales_add_shop TO anon, authenticated;
