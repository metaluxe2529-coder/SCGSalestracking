-- ============================================================
-- Migration 008: fix link_staff_line_account to allow re-linking
-- when line_user_id is a placeholder (starts with "sp_")
-- Run in: Supabase Dashboard > SQL Editor
-- ============================================================

CREATE OR REPLACE FUNCTION link_staff_line_account(p_phone TEXT, p_line_user_id TEXT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_staff staff%ROWTYPE;
BEGIN
  SELECT * INTO v_staff FROM staff WHERE phone = trim(p_phone) AND is_active = true LIMIT 1;

  IF NOT FOUND THEN
    RETURN json_build_object('ok', false, 'reason', 'ไม่พบเบอร์โทรในระบบ กรุณาติดต่อผู้จัดการ');
  END IF;

  -- Block only if already linked to a real LINE account (not a placeholder)
  IF v_staff.line_user_id IS NOT NULL
     AND v_staff.line_user_id NOT LIKE 'sp_%'
     AND v_staff.line_user_id != p_line_user_id THEN
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

GRANT EXECUTE ON FUNCTION link_staff_line_account TO anon, authenticated;
