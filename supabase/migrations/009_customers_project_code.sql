-- =====================================================================
-- 009_customers_project_code.sql — Danh bạ khách hàng & mã dự án
-- Chạy SAU 008. Rollback: 009_customers_project_code_rollback.sql
--
-- 1) customers: mỗi khách một mã KH0001, KH0002… (cấp tự động, không đổi).
--    name_norm = tên bỏ dấu, bỏ ký tự đặc biệt → "Talopa/ Mida" và "talopa mida" là một khách.
-- 2) projects thêm customer_id, project_seq, project_code = <mã KH>.<số thứ tự 2 chữ số>, ví dụ KH0007.03.
-- 3) Trigger: tạo / đổi khách của hồ sơ → tự tìm khách theo tên (hoặc theo id đã chọn), chưa có thì
--    tạo mới, rồi cấp số thứ tự dự án tiếp theo của khách đó. Tên khách trên hồ sơ lấy theo danh bạ.
-- 4) Hồ sơ cũ: gom tên khách thành danh bạ, đánh số dự án theo ngày tạo.
-- 5) Owner: đổi tên khách (fn_rename_customer), gộp khách trùng (fn_merge_customers).
-- =====================================================================
begin;

create or replace function public.fn_vn_norm(p text) returns text
language sql immutable set search_path = public as $$
  select regexp_replace(translate(lower(coalesce(p, '')), 'àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđ', 'aaaaaaaaaaaaaaaaaeeeeeeeeeeeiiiiiooooooooooooooooouuuuuuuuuuuyyyyyd'), '[^a-z0-9]', '', 'g')
$$;

create sequence if not exists public.customer_code_seq;

create table if not exists public.customers (
  id              bigint generated always as identity primary key,
  code            varchar(10)  not null unique,
  name            varchar(255) not null check (btrim(name) <> ''),
  name_norm       varchar(255) not null,
  project_seq     integer      not null default 0,
  merged_into_id  bigint references public.customers(id),
  created_at      timestamptz  not null default now(),
  created_by      bigint references public.app_users(id),
  updated_at      timestamptz,
  updated_by      bigint references public.app_users(id),
  is_deleted      boolean      not null default false,
  deleted_at      timestamptz,
  deleted_by      bigint references public.app_users(id)
);
create unique index if not exists ux_customers_norm on public.customers(name_norm) where is_deleted = false;

alter table public.customers enable row level security;
drop policy if exists p_customers_read on public.customers;
create policy p_customers_read on public.customers for select to authenticated
  using (is_deleted = false and public.fn_me_id() is not null);
revoke insert, update, delete on public.customers from anon, authenticated;

drop trigger if exists trg_customers_touch on public.customers;
create trigger trg_customers_touch before insert or update on public.customers
  for each row execute function public.tg_touch();
drop trigger if exists trg_customers_no_delete on public.customers;
create trigger trg_customers_no_delete before delete on public.customers
  for each row execute function public.tg_no_hard_delete();
drop trigger if exists trg_customers_audit on public.customers;
create trigger trg_customers_audit after insert or update on public.customers
  for each row execute function public.tg_audit();

create or replace function public.tg_customers_norm() returns trigger
language plpgsql set search_path = public as $$
begin
  new.name := btrim(regexp_replace(new.name, '\s+', ' ', 'g'));
  new.name_norm := public.fn_vn_norm(new.name);
  if new.name_norm = '' then raise exception 'Tên khách hàng không hợp lệ'; end if;
  return new;
end $$;
drop trigger if exists trg_customers_norm on public.customers;
create trigger trg_customers_norm before insert or update of name on public.customers
  for each row execute function public.tg_customers_norm();

alter table public.projects
  add column if not exists customer_id  bigint references public.customers(id),
  add column if not exists project_seq  integer,
  add column if not exists project_code varchar(20);
create index if not exists ix_projects_customer on public.projects(customer_id) where is_deleted = false;
create unique index if not exists ux_projects_code on public.projects(project_code) where is_deleted = false and project_code is not null;

-- Tìm khách theo tên (bỏ dấu); chưa có thì tạo mới với mã kế tiếp
create or replace function public.fn_customer_resolve(p_name text)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_norm text := public.fn_vn_norm(p_name);
begin
  if v_norm = '' then return null; end if;
  select c.id into v_id from public.customers c where c.name_norm = v_norm and c.is_deleted = false;
  if v_id is null then
    insert into public.customers(code, name, name_norm)
    values ('KH' || lpad(nextval('public.customer_code_seq')::text, 4, '0'), p_name, v_norm)
    returning id into v_id;
  end if;
  return v_id;
end $$;

create or replace function public.tg_projects_customer() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_id bigint; c record; v_changed boolean;
begin
  if coalesce(current_setting('app.cust_backfill', true), '') = 'on' then return new; end if;
  if nullif(btrim(coalesce(new.customer, '')), '') is null then return new; end if;

  if tg_op = 'INSERT' then
    v_id := coalesce(new.customer_id, public.fn_customer_resolve(new.customer));
  elsif new.customer_id is distinct from old.customer_id and new.customer_id is not null then
    v_id := new.customer_id;                                   -- chọn / gộp sang khách khác
  else
    v_id := old.customer_id;
    if v_id is null or public.fn_vn_norm(new.customer)
         <> (select cc.name_norm from public.customers cc where cc.id = v_id) then
      v_id := public.fn_customer_resolve(new.customer);         -- sửa tên khách trên hồ sơ
    end if;
  end if;

  select cc.id, cc.code, cc.name into c from public.customers cc where cc.id = v_id and cc.is_deleted = false;
  if not found then raise exception 'Không tìm thấy khách hàng'; end if;
  new.customer := c.name;
  v_changed := tg_op = 'INSERT' or old.customer_id is distinct from c.id or new.project_code is null;
  new.customer_id := c.id;
  if v_changed then
    update public.customers set project_seq = project_seq + 1 where id = c.id returning project_seq into new.project_seq;
    new.project_code := c.code || '.' || lpad(new.project_seq::text, 2, '0');
  end if;
  return new;
end $$;
drop trigger if exists trg_projects_customer on public.projects;
create trigger trg_projects_customer before insert or update of customer, customer_id on public.projects
  for each row execute function public.tg_projects_customer();

-- Tạo dự án: nhận thêm customer_id (khách chọn từ danh bạ)
create or replace function public.fn_create_project(p_fields jsonb)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  v_me bigint := public.fn_require_member();
  v_id bigint;
  v_allowed text[];
  v_missing text;
  v_start timestamptz;
  v_cust bigint;
  v_name text;
begin
  if public.fn_me_dept() <> 'KD' then
    raise exception 'Chỉ Kinh doanh được tạo dự án mới' using errcode = '42501';
  end if;
  select array_agg(distinct f) into v_allowed
    from public.task_defs td, unnest(td.required_fields) f where td.block_no = 1 and td.is_deleted = false;
  v_allowed := v_allowed || array['iform', 'iform_detail'];
  -- Chọn khách hàng có sẵn trong danh bạ
  if nullif(p_fields ->> 'customer_id', '') is not null then
    v_cust := (p_fields ->> 'customer_id')::bigint;
    select c.name into v_name from public.customers c where c.id = v_cust and c.is_deleted = false;
    if v_name is null then raise exception 'Không tìm thấy khách hàng đã chọn'; end if;
    p_fields := (p_fields - 'customer_id') || jsonb_build_object('customer', v_name);
  end if;
  if nullif(btrim(coalesce(p_fields ->> 'customer', '')), '') is null then
    raise exception 'Cần nhập: Đơn vị nhận mẫu';
  end if;
  if p_fields ? 'iform_detail' and jsonb_typeof(p_fields -> 'iform_detail') not in ('object', 'string', 'null') then
    raise exception 'Chi tiết phiếu iForm không hợp lệ';
  end if;

  perform public.fn_note(format('Đăng ký dự án %s – xác nhận bước 1', p_fields ->> 'customer'));
  insert into public.projects(customer, customer_id) values (btrim(p_fields ->> 'customer'), v_cust) returning id into v_id;
  p_fields := p_fields - 'customer';
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

-- Owner: đổi tên khách (hồ sơ của khách đổi tên theo, giữ nguyên mã)
create or replace function public.fn_rename_customer(p_customer_id bigint, p_name text)
returns void language plpgsql security definer set search_path = public as $$
declare v_me bigint := public.fn_require_owner(); v_old text;
begin
  select c.name into v_old from public.customers c where c.id = p_customer_id and c.is_deleted = false for update;
  if v_old is null then raise exception 'Không tìm thấy khách hàng'; end if;
  if nullif(btrim(coalesce(p_name, '')), '') is null then raise exception 'Nhập tên khách hàng'; end if;
  if exists (select 1 from public.customers c where c.name_norm = public.fn_vn_norm(p_name) and c.id <> p_customer_id and c.is_deleted = false) then
    raise exception 'Đã có khách hàng trùng tên – hãy dùng Gộp khách hàng';
  end if;
  perform public.fn_note(format('Đổi tên khách hàng “%s” → “%s”', v_old, btrim(p_name)));
  update public.customers set name = p_name where id = p_customer_id;
  update public.projects p set customer = c.name from public.customers c
   where c.id = p_customer_id and p.customer_id = p_customer_id and p.is_deleted = false;
end $$;

-- Owner: gộp khách p_drop vào p_keep; dự án chuyển sang và được đánh số tiếp theo mã của p_keep
create or replace function public.fn_merge_customers(p_keep bigint, p_drop bigint)
returns integer language plpgsql security definer set search_path = public as $$
declare v_me bigint := public.fn_require_owner(); k record; d record; r record; n int := 0;
begin
  if p_keep = p_drop then raise exception 'Chọn hai khách hàng khác nhau'; end if;
  select * into k from public.customers where id = p_keep and is_deleted = false for update;
  select * into d from public.customers where id = p_drop and is_deleted = false for update;
  if k.id is null or d.id is null then raise exception 'Không tìm thấy khách hàng'; end if;
  perform public.fn_note(format('Gộp khách hàng %s “%s” vào %s “%s”', d.code, d.name, k.code, k.name));
  for r in select p.id from public.projects p where p.customer_id = p_drop and p.is_deleted = false order by p.created_at, p.id loop
    update public.projects set customer_id = p_keep where id = r.id;
    n := n + 1;
  end loop;
  update public.customers set is_deleted = true, merged_into_id = p_keep where id = p_drop;
  return n;
end $$;

-- ---------- Hồ sơ cũ ----------
select set_config('app.cust_backfill', 'on', true);
select public.fn_note('Migration 009: tạo danh bạ khách hàng và mã dự án từ hồ sơ cũ');
with g as (
  select public.fn_vn_norm(p.customer) as k,
         min(p.created_at) as first_at,
         (array_agg(btrim(regexp_replace(p.customer, '\s+', ' ', 'g')) order by p.created_at desc))[1] as nm
    from public.projects p
   where p.is_deleted = false and public.fn_vn_norm(p.customer) <> ''
     and not exists (select 1 from public.customers c where c.name_norm = public.fn_vn_norm(p.customer) and c.is_deleted = false)
   group by 1
)
insert into public.customers(code, name, name_norm)
select 'KH' || lpad(nextval('public.customer_code_seq')::text, 4, '0'), x.nm, x.k
  from (select * from g order by first_at, k) x;

with m as (
  select p.id, c.id as cid, c.code,
         row_number() over (partition by c.id order by p.created_at, p.id) + coalesce(c.project_seq, 0) as seq
    from public.projects p join public.customers c on c.name_norm = public.fn_vn_norm(p.customer) and c.is_deleted = false
   where p.is_deleted = false and p.customer_id is null
)
update public.projects p set customer_id = m.cid, project_seq = m.seq,
       project_code = m.code || '.' || lpad(m.seq::text, 2, '0')
  from m where m.id = p.id;

update public.projects p set customer = c.name from public.customers c
 where c.id = p.customer_id and p.is_deleted = false and p.customer is distinct from c.name;

update public.customers c set project_seq = x.mx
  from (select customer_id, max(project_seq) mx from public.projects where is_deleted = false and customer_id is not null group by 1) x
 where x.customer_id = c.id and c.project_seq < x.mx;
select set_config('app.cust_backfill', '', true);

revoke execute on function public.fn_customer_resolve(text), public.tg_projects_customer(), public.tg_customers_norm()
  from public, anon, authenticated;
revoke execute on function public.fn_rename_customer(bigint, text), public.fn_merge_customers(bigint, bigint) from public, anon;
grant execute on function public.fn_rename_customer(bigint, text), public.fn_merge_customers(bigint, bigint), public.fn_vn_norm(text)
  to authenticated;

commit;
