-- ============================================================
-- Migration 004: phone column + staff LINE account linking RPC
-- Run in: Supabase Dashboard > SQL Editor
-- ============================================================

-- Add phone column to staff (from migration 003, if not already done)
ALTER TABLE staff ADD COLUMN IF NOT EXISTS phone TEXT;

-- RPC: staff links their LINE account by entering phone number
CREATE OR REPLACE FUNCTION link_staff_line_account(p_phone TEXT, p_line_user_id TEXT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_staff staff%ROWTYPE;
BEGIN
  SELECT * INTO v_staff FROM staff WHERE phone = trim(p_phone) AND is_active = true LIMIT 1;

  IF NOT FOUND THEN
    RETURN json_build_object('ok', false, 'reason', 'ไม่พบเบอร์โทรในระบบ กรุณาติดต่อผู้จัดการ');
  END IF;

  -- Block if already linked to a different LINE account
  IF v_staff.line_user_id IS NOT NULL AND v_staff.line_user_id != p_line_user_id THEN
    RETURN json_build_object('ok', false, 'reason', 'เบอร์นี้ถูกเชื่อมกับ LINE อื่นแล้ว กรุณาติดต่อผู้จัดการ');
  END IF;

  UPDATE staff SET line_user_id = p_line_user_id WHERE id = v_staff.id;

  RETURN json_build_object(
    'ok',           true,
    'staff_id',     v_staff.id,
    'display_name', v_staff.display_name,
    'picture_url',  v_staff.picture_url,
    'role',         v_staff.role,
    'line_user_id', p_line_user_id
  );
END;
$$;

-- RPC: manager updates staff phone number
CREATE OR REPLACE FUNCTION update_staff_phone(p_line_user_id TEXT, p_staff_id BIGINT, p_phone TEXT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_caller staff%ROWTYPE;
BEGIN
  SELECT * INTO v_caller FROM staff WHERE line_user_id = p_line_user_id AND is_active = true;
  IF NOT FOUND OR v_caller.role != 'manager' THEN
    RETURN json_build_object('ok', false, 'reason', 'ไม่มีสิทธิ์');
  END IF;

  UPDATE staff SET phone = trim(p_phone) WHERE id = p_staff_id;
  RETURN json_build_object('ok', true);
END;
$$;
