-- =====================================================================
-- 005_pic_email_iform.sql — PIC lấy email làm căn cứ + lưu chi tiết phiếu iForm
-- Chạy SAU 004. Rollback: 005_pic_email_iform_rollback.sql
--
-- 1) projects thêm sale_pic_email / rd_pic_email / plan_pic_email (email tài khoản PIC).
--    Cột tên cũ (sale_pic…) giữ lại để hiển thị và lưu lịch sử; khi có email, tên được
--    đồng bộ theo tên hiển thị của tài khoản (trigger), nên không còn nhầm người trùng tên.
--    Ô 1, 3, 7 bắt buộc chọn PIC có email (chọn từ danh sách tài khoản).
-- 2) projects thêm iform_detail (jsonb): các mục đọc từ file Word xuất từ iForm.
-- 3) Hồ sơ cũ: gắn email khi tên PIC khớp ĐÚNG MỘT tài khoản cùng phòng; còn lại để trống.
-- 4) Thông báo Teams: gửi theo email PIC; chưa có email thì dò tên như cũ, rồi cả phòng.
-- Mọi thay đổi dữ liệu đi qua trigger audit sẵn có (audit_log).
-- =====================================================================
begin;

-- ---------- 1. Cột mới ----------
alter table public.projects
  add column if not exists sale_pic_email citext,
  add column if not exists rd_pic_email   citext,
  add column if not exists plan_pic_email citext,
  add column if not exists iform_detail   jsonb;

create index if not exists ix_projects_sale_pic_email on public.projects(sale_pic_email) where is_deleted = false;
create index if not exists ix_projects_rd_pic_email   on public.projects(rd_pic_email)   where is_deleted = false;
create index if not exists ix_projects_plan_pic_email on public.projects(plan_pic_email) where is_deleted = false;
create index if not exists ix_projects_iform          on public.projects(iform)          where is_deleted = false;

-- field_defs cho phép kiểu jsonb (dùng cho iform_detail)
alter table public.field_defs drop constraint if exists field_defs_pg_type_check;
alter table public.field_defs add constraint field_defs_pg_type_check
  check (pg_type in ('text','date','numeric','jsonb'));

insert into public.field_defs(field_key, label, pg_type, dept_code, is_extra) values
  ('sale_pic_email', 'PIC Sale (chọn từ danh sách tài khoản)',     'text',  'KD', true),
  ('rd_pic_email',   'PIC R&D (chọn từ danh sách tài khoản)',      'text',  'RD', true),
  ('plan_pic_email', 'PIC Kế hoạch (chọn từ danh sách tài khoản)', 'text',  'KH', true),
  ('iform_detail',   'Chi tiết phiếu iForm',                       'jsonb', 'KD', true)
on conflict (field_key) do update
  set label = excluded.label, pg_type = excluded.pg_type, dept_code = excluded.dept_code,
      is_deleted = false, deleted_at = null, deleted_by = null;

-- Ô 1, 3, 7: thêm trường email PIC vào danh sách bắt buộc (đồng thời là danh sách được phép ghi)
update public.task_defs set required_fields = array_append(required_fields, 'sale_pic_email')
 where task_no = 1 and not ('sale_pic_email' = any(required_fields));
update public.task_defs set required_fields = array_append(required_fields, 'rd_pic_email')
 where task_no = 3 and not ('rd_pic_email' = any(required_fields));
update public.task_defs set required_fields = array_append(required_fields, 'plan_pic_email')
 where task_no = 7 and not ('plan_pic_email' = any(required_fields));

-- ---------- 2. Trigger: email PIC phải là tài khoản thật; tên PIC đồng bộ theo tài khoản ----------
create or replace function public.tg_projects_pic_email() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_name varchar;
  v_email citext;
begin
  -- Gắn email cho hồ sơ cũ trong migration: giữ nguyên tên đã nhập trước đây
  if coalesce(current_setting('app.pic_backfill', true), '') = 'on' then return new; end if;

  if new.sale_pic_email is not null then
    select u.display_name, u.email into v_name, v_email from public.app_users u
     where u.email = new.sale_pic_email and u.is_deleted = false and u.status <> 'removed';
    if not found then raise exception 'Email PIC Sale % không có trong danh sách tài khoản', new.sale_pic_email; end if;
    new.sale_pic := v_name; new.sale_pic_email := v_email;
  end if;
  if new.rd_pic_email is not null then
    select u.display_name, u.email into v_name, v_email from public.app_users u
     where u.email = new.rd_pic_email and u.is_deleted = false and u.status <> 'removed';
    if not found then raise exception 'Email PIC R&D % không có trong danh sách tài khoản', new.rd_pic_email; end if;
    new.rd_pic := v_name; new.rd_pic_email := v_email;
  end if;
  if new.plan_pic_email is not null then
    select u.display_name, u.email into v_name, v_email from public.app_users u
     where u.email = new.plan_pic_email and u.is_deleted = false and u.status <> 'removed';
    if not found then raise exception 'Email PIC Kế hoạch % không có trong danh sách tài khoản', new.plan_pic_email; end if;
    new.plan_pic := v_name; new.plan_pic_email := v_email;
  end if;
  return new;
end $$;

drop trigger if exists trg_projects_pic_email on public.projects;
create trigger trg_projects_pic_email
  before insert or update of sale_pic, rd_pic, plan_pic, sale_pic_email, rd_pic_email, plan_pic_email
  on public.projects for each row execute function public.tg_projects_pic_email();

-- ---------- 3. Tạo dự án: cho phép ghi thêm iform_detail ----------
create or replace function public.fn_create_project(p_fields jsonb)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  v_me bigint := public.fn_require_member();
  v_id bigint;
  v_allowed text[];
  v_missing text;
  v_start timestamptz;
begin
  if public.fn_me_dept() <> 'KD' then
    raise exception 'Chỉ Kinh doanh được tạo dự án mới' using errcode = '42501';
  end if;
  select array_agg(distinct f) into v_allowed
    from public.task_defs td, unnest(td.required_fields) f where td.block_no = 1 and td.is_deleted = false;
  v_allowed := v_allowed || array['iform', 'iform_detail'];
  if nullif(btrim(coalesce(p_fields ->> 'customer', '')), '') is null then
    raise exception 'Cần nhập: Đơn vị nhận mẫu';
  end if;
  if p_fields ? 'iform_detail' and jsonb_typeof(p_fields -> 'iform_detail') not in ('object', 'string', 'null') then
    raise exception 'Chi tiết phiếu iForm không hợp lệ';
  end if;

  perform public.fn_note(format('Đăng ký dự án %s – xác nhận bước 1', p_fields ->> 'customer'));
  insert into public.projects(customer) values (btrim(p_fields ->> 'customer')) returning id into v_id;
  perform public.fn_apply_fields(v_id, p_fields, v_allowed);

  select string_agg(m, ', ') into v_missing
    from (select public.fn_missing_fields(v_id, td.required_fields) m
            from public.task_defs td where td.block_no = 1 and td.is_deleted = false order by td.task_no) x
   where m is not null;
  if v_missing is not null then raise exception 'Cần nhập: %', v_missing; end if;

  v_start := least(now(), coalesce(public.fn_block_ready_at(v_id, 1::smallint, 1::smallint), now()));
  insert into public.project_tasks(project_id, task_no, round, status, started_at, started_by, done_at, done_by)
  select v_id, td.task_no, 1, 'done', v_start, v_me, now(), v_me
    from public.task_defs td where td.block_no = 1 and td.is_deleted = false;
  return v_id;
end $$;

-- fn_apply_fields: jsonb gửi dạng object → ghi nguyên object (bản 001 chỉ đọc dạng chữ)
create or replace function public.fn_apply_fields(p_project_id bigint, p_fields jsonb, p_allowed text[])
returns void language plpgsql security definer set search_path = public as $$
declare v_bad text; v_set text;
begin
  if p_fields is null or p_fields = '{}'::jsonb then return; end if;
  select k into v_bad from jsonb_object_keys(p_fields) k where not (k = any(p_allowed)) limit 1;
  if v_bad is not null then
    raise exception 'Trường "%" không thuộc quyền nhập của bạn ở ô này', v_bad using errcode = '42501';
  end if;
  select string_agg(
           case when f.pg_type = 'jsonb'
                then format('%I = case when jsonb_typeof($1 -> %L) = ''object'' then $1 -> %L else nullif(btrim($1 ->> %L), '''')::jsonb end',
                            f.field_key, f.field_key, f.field_key, f.field_key)
                else format('%I = nullif(btrim($1 ->> %L), '''')::%s', f.field_key, f.field_key, f.pg_type) end, ', ')
    into v_set
    from public.field_defs f
   where f.field_key in (select jsonb_object_keys(p_fields)) and f.is_deleted = false;
  execute format('update public.projects set %s where id = $2 and is_deleted = false', v_set)
    using p_fields, p_project_id;
end $$;

-- ---------- 4. Người nhận Teams: email PIC trước ----------
create or replace function public.fn_notify_recipients(p_project_id bigint, p_dept varchar)
returns table(email text) language plpgsql stable security definer set search_path = public as $$
declare v_pic text; v_email citext;
begin
  select lower(btrim(case p_dept when 'KD' then p.sale_pic when 'RD' then p.rd_pic when 'KH' then p.plan_pic end)),
         case p_dept when 'KD' then p.sale_pic_email when 'RD' then p.rd_pic_email when 'KH' then p.plan_pic_email end
    into v_pic, v_email from public.projects p where p.id = p_project_id;

  if v_email is not null then
    return query
      select u.email::text from public.app_users u
       where u.email = v_email and u.is_deleted = false and u.status <> 'removed';
    if found then return; end if;
  end if;
  if v_pic is not null and v_pic <> '' then
    return query
      select u.email::text from public.app_users u
       where u.status = 'active' and u.is_deleted = false and u.dept_code = p_dept
         and (lower(btrim(u.display_name)) = v_pic or lower(btrim(u.full_name)) = v_pic);
    if found then return; end if;
  end if;
  return query
    select u.email::text from public.app_users u
     where u.status = 'active' and u.is_deleted = false and u.dept_code = p_dept;
end $$;

-- ---------- 5. Gắn email cho hồ sơ cũ (chỉ khi khớp đúng một tài khoản cùng phòng) ----------
select set_config('app.pic_backfill', 'on', true);
select public.fn_note('Migration 005: gắn email PIC cho hồ sơ cũ theo tên khớp duy nhất');

with m as (
  select p.id,
         (select min(u.email::text) from public.app_users u
           where u.is_deleted = false and u.status <> 'removed' and u.dept_code = 'KD'
             and lower(btrim(p.sale_pic)) in (lower(btrim(u.display_name)), lower(btrim(u.full_name)))
          having count(*) = 1) as e
    from public.projects p
   where p.is_deleted = false and p.sale_pic_email is null and nullif(btrim(p.sale_pic), '') is not null
)
update public.projects p set sale_pic_email = m.e from m where m.id = p.id and m.e is not null;

with m as (
  select p.id,
         (select min(u.email::text) from public.app_users u
           where u.is_deleted = false and u.status <> 'removed' and u.dept_code = 'RD'
             and lower(btrim(p.rd_pic)) in (lower(btrim(u.display_name)), lower(btrim(u.full_name)))
          having count(*) = 1) as e
    from public.projects p
   where p.is_deleted = false and p.rd_pic_email is null and nullif(btrim(p.rd_pic), '') is not null
)
update public.projects p set rd_pic_email = m.e from m where m.id = p.id and m.e is not null;

with m as (
  select p.id,
         (select min(u.email::text) from public.app_users u
           where u.is_deleted = false and u.status <> 'removed' and u.dept_code = 'KH'
             and lower(btrim(p.plan_pic)) in (lower(btrim(u.display_name)), lower(btrim(u.full_name)))
          having count(*) = 1) as e
    from public.projects p
   where p.is_deleted = false and p.plan_pic_email is null and nullif(btrim(p.plan_pic), '') is not null
)
update public.projects p set plan_pic_email = m.e from m where m.id = p.id and m.e is not null;

select set_config('app.pic_backfill', '', true);

revoke execute on function public.tg_projects_pic_email() from public, anon, authenticated;

commit;

-- Kiểm tra sau khi chạy: hồ sơ còn PIC chưa gắn tài khoản
-- select id, customer, sale_pic, sale_pic_email, rd_pic, rd_pic_email, plan_pic, plan_pic_email
--   from public.projects where is_deleted = false
--    and ((sale_pic is not null and sale_pic_email is null) or (rd_pic is not null and rd_pic_email is null)
--         or (plan_pic is not null and plan_pic_email is null));
