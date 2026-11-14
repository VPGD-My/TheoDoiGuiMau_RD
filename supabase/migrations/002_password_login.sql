-- =====================================================================
-- 002_password_login.sql — Đăng nhập bằng email + mật khẩu, kích hoạt bằng mã do Owner cấp
-- Không cần gửi email (không cần SMTP). Chạy SAU 001_init.sql.
-- Rollback: 002_password_login_rollback.sql
-- Yêu cầu cấu hình Supabase: Authentication → Sign In / Providers → Email:
--   bật "Enable Email provider", TẮT "Confirm email".
-- =====================================================================
begin;

create extension if not exists pgcrypto with schema extensions;

-- Hàm mới trong schema public không tự cấp quyền chạy cho client
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

alter table public.app_users
  add column activation_hash       varchar(100),
  add column activation_expires_at timestamptz,
  add column activation_attempts   smallint not null default 0 check (activation_attempts >= 0),
  add column activation_issued_at  timestamptz,
  add column activation_issued_by  bigint references public.app_users(id),
  add column activation_verified_at timestamptz;

-- ---------------------------------------------------------------------
-- Nội bộ: cấp mã kích hoạt (8 ký tự, hết hạn sau 7 ngày, tối đa 5 lần nhập sai)
-- Chỉ chạy được từ SQL Editor hoặc từ hàm của Owner; client không gọi trực tiếp.
-- ---------------------------------------------------------------------
create or replace function public.fn_issue_activation(p_user_id bigint)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare
  v_alpha constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  v_code text := '';
  i int;
begin
  for i in 1..8 loop
    v_code := v_code || substr(v_alpha, 1 + floor(random() * length(v_alpha))::int, 1);
  end loop;
  perform public.fn_note('Cấp mã kích hoạt / đặt lại mật khẩu');
  update public.app_users
     set activation_hash = extensions.crypt(v_code, extensions.gen_salt('bf')),
         activation_expires_at = now() + interval '7 days',
         activation_attempts = 0,
         activation_issued_at = now(),
         activation_issued_by = public.fn_me_id(),
         activation_verified_at = null
   where id = p_user_id and is_deleted = false and status <> 'removed';
  if not found then raise exception 'Không tìm thấy người dùng hoặc người dùng đã bị gỡ quyền'; end if;
  return substr(v_code, 1, 4) || '-' || substr(v_code, 5, 4);
end $$;

-- Owner thêm nhân sự: trả về mã kích hoạt để giao cho nhân sự
drop function if exists public.fn_add_member(text, text, text, varchar, varchar);
create or replace function public.fn_add_member(p_email text, p_display_name text, p_full_name text, p_dept varchar, p_role varchar)
returns text language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  perform public.fn_require_owner();
  if exists (select 1 from public.app_users u where u.email = lower(btrim(p_email)) and u.is_deleted = false) then
    raise exception 'Email này đã có trong danh sách người dùng';
  end if;
  perform public.fn_note(format('Thêm nhân sự %s (%s) – %s, quyền %s, chờ kích hoạt', p_full_name, p_email, p_dept, p_role));
  insert into public.app_users(email, display_name, full_name, dept_code, app_role, status)
  values (lower(btrim(p_email)), btrim(p_display_name), btrim(p_full_name), p_dept, p_role, 'invited')
  returning id into v_id;
  return public.fn_issue_activation(v_id);
end $$;

-- Owner cấp mã mới (nhân sự quên mật khẩu hoặc mã cũ hết hạn)
create or replace function public.fn_reissue_activation(p_user_id bigint)
returns text language plpgsql security definer set search_path = public as $$
declare v_me bigint := public.fn_require_owner();
begin
  if p_user_id = v_me then raise exception 'Không tự cấp mã cho chính mình; nhờ Owner khác hoặc dùng SQL Editor'; end if;
  return public.fn_issue_activation(p_user_id);
end $$;

-- Kích hoạt / đặt lại mật khẩu bằng mã (gọi được khi chưa đăng nhập)
-- Trả về 'login' (đã đặt mật khẩu, đăng nhập luôn) hoặc 'signup' (client tạo tài khoản đăng nhập).
create or replace function public.fn_activate(p_email text, p_code text, p_password text)
returns varchar language plpgsql security definer set search_path = public, extensions as $$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_code text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  u record;
  v_auth uuid;
begin
  if length(coalesce(p_password, '')) < 8 then raise exception 'Mật khẩu cần ít nhất 8 ký tự'; end if;
  select au.id, au.status, au.activation_hash, au.activation_expires_at, au.activation_attempts, au.auth_user_id
    into u from public.app_users au
   where au.email = v_email and au.is_deleted = false for update;
  if not found or u.status = 'removed' or u.activation_hash is null then
    raise exception 'Email hoặc mã kích hoạt không đúng';
  end if;
  if u.activation_attempts >= 5 then
    raise exception 'Nhập sai quá 5 lần. Liên hệ Owner để cấp mã mới';
  end if;
  if u.activation_expires_at < now() then
    raise exception 'Mã kích hoạt đã hết hạn. Liên hệ Owner để cấp mã mới';
  end if;
  if extensions.crypt(v_code, u.activation_hash) <> u.activation_hash then
    update public.app_users set activation_attempts = activation_attempts + 1 where id = u.id;
    -- trả lỗi nhưng vẫn ghi nhận số lần sai
    return 'wrong';
  end if;

  select a.id into v_auth from auth.users a where lower(a.email) = v_email limit 1;
  if v_auth is not null then
    -- Đã có tài khoản đăng nhập với email này: đặt mật khẩu mới và liên kết
    begin
      update auth.users
         set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')),
             email_confirmed_at = coalesce(email_confirmed_at, now()),
             updated_at = now()
       where id = v_auth;
    exception when insufficient_privilege then
      -- Supabase không cho đổi mật khẩu trực tiếp: Owner xóa tài khoản đăng nhập cũ
      -- (Authentication → Users) rồi nhân sự kích hoạt lại bằng cùng mã.
      return 'need_delete';
    end;
    perform public.fn_note('Kích hoạt / đặt lại mật khẩu bằng mã');
    update public.app_users
       set auth_user_id = v_auth, status = 'active', linked_at = coalesce(linked_at, now()),
           activation_hash = null, activation_expires_at = null, activation_attempts = 0, activation_verified_at = null
     where id = u.id;
    return 'login';
  end if;
  -- Chưa có tài khoản đăng nhập: cho phép client tạo trong 15 phút tới
  update public.app_users set activation_verified_at = now() where id = u.id;
  return 'signup';
end $$;

-- Liên kết tài khoản vừa tạo với nhân sự (sau khi đã xác minh mã ở fn_activate)
create or replace function public.fn_claim_membership()
returns varchar language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_user record;
begin
  if v_uid is null then return 'anonymous'; end if;
  select u.id, u.status into v_user from public.app_users u
   where u.auth_user_id = v_uid and u.is_deleted = false;
  if found then
    return case when v_user.status = 'active' then 'active' else 'removed' end;
  end if;
  select u.id, u.status into v_user from public.app_users u
   where u.email = v_email and u.is_deleted = false and u.auth_user_id is null
     and u.activation_verified_at > now() - interval '15 minutes';
  if found and v_user.status <> 'removed' then
    perform public.fn_note('Kích hoạt tài khoản lần đầu');
    update public.app_users
       set auth_user_id = v_uid, status = 'active', linked_at = now(),
           activation_hash = null, activation_expires_at = null, activation_attempts = 0, activation_verified_at = null
     where id = v_user.id;
    return 'active';
  end if;
  return 'none';
end $$;

-- Quyền chạy hàm
revoke execute on function public.fn_issue_activation(bigint) from public, anon, authenticated;
revoke execute on function public.fn_add_member(text, text, text, varchar, varchar) from public, anon;
revoke execute on function public.fn_reissue_activation(bigint) from public, anon;
revoke execute on function public.fn_activate(text, text, text) from public;
revoke execute on function public.fn_claim_membership() from public, anon;
grant execute on function public.fn_add_member(text, text, text, varchar, varchar) to authenticated;
grant execute on function public.fn_reissue_activation(bigint) to authenticated;
grant execute on function public.fn_activate(text, text, text) to anon, authenticated;
grant execute on function public.fn_claim_membership() to authenticated;

-- 001 đã thu hồi quyền chạy mọi hàm trong schema public, kể cả hàm của extension citext.
-- Trả lại quyền cho các hàm/toán tử của citext để so sánh email hoạt động bình thường.
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig
             from pg_proc p
             join pg_depend d on d.objid = p.oid and d.deptype = 'e'
             join pg_extension e on e.oid = d.refobjid and e.extname = 'citext'
  loop
    execute format('grant execute on function %s to anon, authenticated', f.sig);
  end loop;
end $$;

commit;
