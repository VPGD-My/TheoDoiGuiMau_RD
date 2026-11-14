-- =====================================================================
-- 001_init.sql — Theo dõi gửi mẫu (DTRG) — Supabase / PostgreSQL
-- Rollback: 001_init_rollback.sql
-- Nguyên tắc áp dụng: soft delete (#1), audit log qua trigger (#3, #4),
-- khóa chính surrogate (#6), ràng buộc ở DB (#7), thời gian UTC (#9),
-- ghi dữ liệu chỉ qua hàm RPC có kiểm tra quyền (#20), RLS chỉ cho đọc.
-- created_by = NULL nghĩa là "hệ thống" (dữ liệu seed / script).
-- =====================================================================
begin;

create extension if not exists citext;

-- ---------------------------------------------------------------------
-- 1. Bảng danh mục
-- ---------------------------------------------------------------------
create table public.departments (
  id          smallint generated always as identity primary key,
  code        varchar(10)  not null unique,
  name        varchar(100) not null,
  created_at  timestamptz  not null default now(),
  created_by  bigint,
  updated_at  timestamptz,
  updated_by  bigint,
  is_deleted  boolean      not null default false,
  deleted_at  timestamptz,
  deleted_by  bigint
);

create table public.app_users (
  id               bigint generated always as identity primary key,
  auth_user_id     uuid unique references auth.users(id) on delete set null,
  email            citext       not null check (email ~ '^[^\s@]+@[^\s@]+\.[^\s@]+$'),
  display_name     varchar(100) not null check (btrim(display_name) <> ''),
  full_name        varchar(200) not null check (btrim(full_name) <> ''),
  dept_code        varchar(10)  not null references public.departments(code),
  acting_dept_code varchar(10)  references public.departments(code),
  app_role         varchar(10)  not null default 'user'    check (app_role in ('owner','user')),
  status           varchar(10)  not null default 'invited' check (status in ('invited','active','removed')),
  linked_at        timestamptz,
  created_at       timestamptz  not null default now(),
  created_by       bigint references public.app_users(id),
  updated_at       timestamptz,
  updated_by       bigint references public.app_users(id),
  is_deleted       boolean      not null default false,
  deleted_at       timestamptz,
  deleted_by       bigint references public.app_users(id)
);
create unique index uq_app_users_email on public.app_users(email) where is_deleted = false;

alter table public.departments
  add constraint fk_departments_created_by foreign key (created_by) references public.app_users(id),
  add constraint fk_departments_updated_by foreign key (updated_by) references public.app_users(id),
  add constraint fk_departments_deleted_by foreign key (deleted_by) references public.app_users(id);

create table public.registration_requests (
  id            bigint generated always as identity primary key,
  auth_user_id  uuid         not null references auth.users(id),
  email         citext       not null,
  display_name  varchar(100) not null check (btrim(display_name) <> ''),
  full_name     varchar(200) not null check (btrim(full_name) <> ''),
  dept_code     varchar(10)  not null references public.departments(code),
  status        varchar(10)  not null default 'pending' check (status in ('pending','approved','rejected')),
  decided_at    timestamptz,
  decided_by    bigint references public.app_users(id),
  created_at    timestamptz  not null default now(),
  created_by    bigint references public.app_users(id),
  updated_at    timestamptz,
  updated_by    bigint references public.app_users(id),
  is_deleted    boolean      not null default false,
  deleted_at    timestamptz,
  deleted_by    bigint references public.app_users(id)
);
create unique index uq_registration_pending on public.registration_requests(auth_user_id)
  where status = 'pending' and is_deleted = false;

-- Định nghĩa quy trình (nguồn sự thật dùng để kiểm tra quyền phía server)
create table public.field_defs (
  id          smallint generated always as identity primary key,
  field_key   varchar(50)  not null unique,
  label       varchar(150) not null,
  pg_type     varchar(10)  not null check (pg_type in ('text','date','numeric')),
  dept_code   varchar(10)  not null references public.departments(code),
  is_extra    boolean      not null default false,
  created_at  timestamptz  not null default now(),
  created_by  bigint references public.app_users(id),
  updated_at  timestamptz,
  updated_by  bigint references public.app_users(id),
  is_deleted  boolean      not null default false,
  deleted_at  timestamptz,
  deleted_by  bigint references public.app_users(id)
);

create table public.task_blocks (
  id          smallint generated always as identity primary key,
  block_no    smallint     not null unique check (block_no > 0),
  dept_code   varchar(10)  not null references public.departments(code),
  name        varchar(150) not null,
  pct_label   varchar(20)  not null,
  gate        varchar(10)  unique check (gate in ('feas','pass')),
  gate_need   smallint[],
  created_at  timestamptz  not null default now(),
  created_by  bigint references public.app_users(id),
  updated_at  timestamptz,
  updated_by  bigint references public.app_users(id),
  is_deleted  boolean      not null default false,
  deleted_at  timestamptz,
  deleted_by  bigint references public.app_users(id),
  check ((gate is null) = (gate_need is null))
);

create table public.task_defs (
  id              smallint generated always as identity primary key,
  task_no         smallint     not null unique check (task_no > 0),
  block_no        smallint     not null references public.task_blocks(block_no),
  dept_code       varchar(10)  not null references public.departments(code),
  title           varchar(200) not null,
  required_fields varchar(50)[] not null,
  created_at      timestamptz  not null default now(),
  created_by      bigint references public.app_users(id),
  updated_at      timestamptz,
  updated_by      bigint references public.app_users(id),
  is_deleted      boolean      not null default false,
  deleted_at      timestamptz,
  deleted_by      bigint references public.app_users(id)
);

-- ---------------------------------------------------------------------
-- 2. Bảng nghiệp vụ
-- ---------------------------------------------------------------------
create table public.projects (
  id                  bigint generated always as identity primary key,
  -- Kinh doanh
  req_date            date,
  customer            varchar(200)  not null check (btrim(customer) <> ''),
  application         varchar(200),
  industry            varchar(100),
  requirement         varchar(2000),
  purpose             varchar(100),
  sale_pic            varchar(100),
  iform               varchar(100),
  qty_kg              numeric(14,2) check (qty_kg >= 0),
  feas_customer_note  varchar(2000),
  sent_date           date,
  received_date       date,
  trial_expected      date,
  result_expected     date,
  feedback_date       date,
  feedback            varchar(2000),
  commercial_note     varchar(2000),
  launch_date         date,
  -- R&D
  rd_pic              varchar(100),
  product_code        varchar(50),
  spec_note           varchar(2000),
  feas_doc            varchar(300),
  trial_request_date  date,
  sample_taken_date   date,
  tds_no              varchar(50),
  tds_date            date,
  handover_date       date,
  feedback_analysis   varchar(2000),
  final_spec          varchar(2000),
  rd_note             varchar(2000),
  -- Kế hoạch
  plan_pic            varchar(100),
  production_line     varchar(100),
  trial_date          date,
  expected_sample     date,
  lot                 varchar(50),
  trial_actual_date   date,
  plan_note           varchar(2000),
  -- Trạng thái
  status              varchar(12)   not null default 'active' check (status in ('active','launched','cancelled')),
  round               smallint      not null default 1 check (round >= 1),
  is_pending          boolean       not null default false,
  pending_reason      varchar(300),
  cancel_reason       varchar(500),
  cancel_type         varchar(10)   check (cancel_type in ('feas','owner')),
  cancelled_at        timestamptz,
  cancelled_by        bigint references public.app_users(id),
  -- Audit
  created_at          timestamptz   not null default now(),
  created_by          bigint references public.app_users(id),
  updated_at          timestamptz,
  updated_by          bigint references public.app_users(id),
  is_deleted          boolean       not null default false,
  deleted_at          timestamptz,
  deleted_by          bigint references public.app_users(id),
  constraint ck_projects_cancel  check (status <> 'cancelled' or (cancel_reason is not null and btrim(cancel_reason) <> '')),
  constraint ck_projects_pending check (not is_pending or (pending_reason is not null and btrim(pending_reason) <> ''))
);
create index ix_projects_status on public.projects(status) where is_deleted = false;

create table public.project_tasks (
  id          bigint generated always as identity primary key,
  project_id  bigint      not null references public.projects(id),
  task_no     smallint    not null references public.task_defs(task_no),
  round       smallint    not null check (round >= 1),
  status      varchar(12) not null check (status in ('in_progress','done','reopened')),
  started_at  timestamptz not null,
  started_by  bigint      references public.app_users(id),
  done_at     timestamptz,
  done_by     bigint      references public.app_users(id),
  created_at  timestamptz not null default now(),
  created_by  bigint references public.app_users(id),
  updated_at  timestamptz,
  updated_by  bigint references public.app_users(id),
  is_deleted  boolean     not null default false,
  deleted_at  timestamptz,
  deleted_by  bigint references public.app_users(id),
  check ((status = 'done') = (done_at is not null))
);
create unique index uq_project_tasks on public.project_tasks(project_id, task_no, round) where is_deleted = false;

create table public.project_gates (
  id          bigint generated always as identity primary key,
  project_id  bigint      not null references public.projects(id),
  gate        varchar(10) not null references public.task_blocks(gate),
  round       smallint    not null check (round >= 1),
  result      varchar(3)  not null check (result in ('yes','no')),
  reason      varchar(500),
  decided_at  timestamptz not null default now(),
  decided_by  bigint      references public.app_users(id),
  created_at  timestamptz not null default now(),
  created_by  bigint references public.app_users(id),
  updated_at  timestamptz,
  updated_by  bigint references public.app_users(id),
  is_deleted  boolean     not null default false,
  deleted_at  timestamptz,
  deleted_by  bigint references public.app_users(id)
);
create unique index uq_project_gates on public.project_gates(project_id, gate, round) where is_deleted = false;

create table public.project_comments (
  id           bigint generated always as identity primary key,
  project_id   bigint        not null references public.projects(id),
  to_dept_code varchar(10)   references public.departments(code),
  task_no      smallint      references public.task_defs(task_no),
  body         varchar(2000) not null check (btrim(body) <> ''),
  author_dept  varchar(10)   references public.departments(code),
  created_at   timestamptz   not null default now(),
  created_by   bigint references public.app_users(id),
  updated_at   timestamptz,
  updated_by   bigint references public.app_users(id),
  is_deleted   boolean       not null default false,
  deleted_at   timestamptz,
  deleted_by   bigint references public.app_users(id)
);
create index ix_project_comments_project on public.project_comments(project_id) where is_deleted = false;

create table public.project_notices (
  id            bigint generated always as identity primary key,
  project_id    bigint        not null references public.projects(id),
  to_dept_codes varchar(10)[] not null,
  body          varchar(1000) not null,
  author_dept   varchar(10)   references public.departments(code),
  created_at    timestamptz   not null default now(),
  created_by    bigint references public.app_users(id),
  updated_at    timestamptz,
  updated_by    bigint references public.app_users(id),
  is_deleted    boolean       not null default false,
  deleted_at    timestamptz,
  deleted_by    bigint references public.app_users(id)
);
create index ix_project_notices_project on public.project_notices(project_id) where is_deleted = false;

-- Nhật ký: chỉ ghi thêm, không sửa, không xóa.
create table public.audit_log (
  id            bigint generated always as identity primary key,
  table_name    varchar(63)  not null,
  record_id     bigint,
  project_id    bigint,
  action        varchar(12)  not null check (action in ('INSERT','UPDATE','SOFT_DELETE','NOTE')),
  note          varchar(1000),
  old_data      jsonb,
  new_data      jsonb,
  changed_dept  varchar(10),
  created_at    timestamptz  not null default now(),
  created_by    bigint,
  updated_at    timestamptz,
  updated_by    bigint
);
create index ix_audit_log_project on public.audit_log(project_id, created_at desc);
create index ix_audit_log_created on public.audit_log(created_at desc);

-- ---------------------------------------------------------------------
-- 3. Seed danh mục & quy trình (9 bước, 18 ô)
-- ---------------------------------------------------------------------
insert into public.departments(code, name) values
  ('KD','Kinh doanh'), ('RD','R&D'), ('KH','Kế hoạch');

insert into public.field_defs(field_key, label, pg_type, dept_code, is_extra) values
  ('req_date','Ngày nhận yêu cầu KH','date','KD',false),
  ('customer','Đơn vị nhận mẫu','text','KD',false),
  ('application','Ứng dụng sản phẩm','text','KD',false),
  ('industry','Ngành','text','KD',false),
  ('requirement','Yêu cầu đặc biệt','text','KD',false),
  ('purpose','Mục đích','text','KD',false),
  ('sale_pic','PIC Sale','text','KD',false),
  ('iform','Iform','text','KD',true),
  ('qty_kg','Số lượng (kg)','numeric','KD',false),
  ('feas_customer_note','Ý kiến KH về đánh giá tiền khả thi','text','KD',false),
  ('sent_date','Ngày gửi mẫu','date','KD',false),
  ('received_date','Ngày KH nhận mẫu','date','KD',false),
  ('trial_expected','Ngày dự kiến KH thử mẫu','date','KD',false),
  ('result_expected','Ngày dự kiến có kết quả','date','KD',false),
  ('feedback_date','Ngày nhận phản hồi','date','KD',false),
  ('feedback','Chi tiết phản hồi','text','KD',false),
  ('commercial_note','Chốt thương mại (giá, sản lượng)','text','KD',false),
  ('launch_date','Ngày dự kiến tung SP','date','KD',false),
  ('rd_pic','PIC R&D','text','RD',false),
  ('product_code','Mã sản phẩm','text','RD',false),
  ('spec_note','Spec thống nhất','text','RD',false),
  ('feas_doc','Số / link tài liệu đánh giá tiền khả thi','text','RD',false),
  ('trial_request_date','Ngày gửi yêu cầu trial','date','RD',false),
  ('sample_taken_date','Ngày lấy mẫu','date','RD',false),
  ('tds_no','Số TDS','text','RD',false),
  ('tds_date','Ngày release TDS','date','RD',false),
  ('handover_date','Ngày bàn giao mẫu cho KD','date','RD',false),
  ('feedback_analysis','Phân tích phản hồi','text','RD',false),
  ('final_spec','Spec cuối đề xuất','text','RD',false),
  ('rd_note','Note R&D','text','RD',true),
  ('plan_pic','PIC Kế hoạch','text','KH',false),
  ('production_line','Line / nhà máy','text','KH',false),
  ('trial_date','Ngày chạy trial dự kiến','date','KH',false),
  ('expected_sample','Ngày dự kiến có mẫu','date','KH',false),
  ('lot','LOT','text','KH',false),
  ('trial_actual_date','Ngày chạy trial thực tế','date','KH',false),
  ('plan_note','Ghi chú Kế hoạch','text','KH',true);

insert into public.task_blocks(block_no, dept_code, name, pct_label, gate, gate_need) values
  (1,'KD','Tiếp nhận & thống nhất yêu cầu','10–20%',null,null),
  (2,'RD','Chốt spec, đánh giá tiền khả thi','20–30%',null,null),
  (3,'KD','Gửi tài liệu tiền khả thi cho KH','30%',null,null),
  (4,'RD','Chốt khả thi, gửi yêu cầu trial','30–35%','feas','{4,5}'),
  (5,'KH','Lập kế hoạch & follow chạy trial','35–40%',null,null),
  (6,'RD','Lấy mẫu, release TDS, bàn giao','40–60%',null,null),
  (7,'KD','Gửi mẫu, theo dõi & thu phản hồi','60–80%',null,null),
  (8,'RD','Phân tích phản hồi, spec cuối','80–90%',null,null),
  (9,'KD','Chốt đạt, thương mại, tung SP','90–100%','pass','{14,15}');

insert into public.task_defs(task_no, block_no, dept_code, title, required_fields) values
  (1,1,'KD','Tiếp nhận nhu cầu KH, mở dòng theo dõi','{req_date,customer,application,industry,requirement,purpose,sale_pic}'),
  (2,1,'KD','Chốt yêu cầu, số lượng với KH','{qty_kg}'),
  (3,2,'RD','Chốt spec, mã SP, PIC','{rd_pic,product_code,spec_note}'),
  (4,2,'RD','Lập đánh giá tiền khả thi','{feas_doc}'),
  (5,3,'KD','Gửi tài liệu cho KH, nhận ý kiến','{feas_customer_note}'),
  (6,4,'RD','Gửi yêu cầu trial','{trial_request_date}'),
  (7,5,'KH','Xếp lịch line, nguyên liệu, chốt ngày & LOT','{plan_pic,production_line,trial_date,expected_sample,lot}'),
  (8,5,'KH','Follow chạy trial','{trial_actual_date}'),
  (9,6,'RD','Giám sát, lấy mẫu','{sample_taken_date}'),
  (10,6,'RD','Kiểm nghiệm, release TDS','{tds_no,tds_date}'),
  (11,6,'RD','Bàn giao mẫu cho KD','{handover_date}'),
  (12,7,'KD','Gửi mẫu cho KH','{sent_date}'),
  (13,7,'KD','Xác nhận KH nhận, hẹn ngày thử','{received_date,trial_expected,result_expected}'),
  (14,7,'KD','Thu thập, ghi chi tiết phản hồi','{feedback_date,feedback}'),
  (15,8,'RD','Phân tích phản hồi','{feedback_analysis}'),
  (16,8,'RD','Đề xuất spec cuối','{final_spec}'),
  (17,9,'KD','Chốt thương mại với KH','{commercial_note}'),
  (18,9,'KD','Chuẩn bị tung SP','{launch_date}');

-- ---------------------------------------------------------------------
-- 4. Hàm nhận diện người dùng hiện tại
-- ---------------------------------------------------------------------
create or replace function public.fn_me_id() returns bigint
language sql stable security definer set search_path = public as $$
  select u.id from public.app_users u
  where u.auth_user_id = auth.uid() and u.status = 'active' and u.is_deleted = false
  limit 1
$$;

create or replace function public.fn_is_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select u.app_role = 'owner' from public.app_users u
                   where u.id = public.fn_me_id()), false)
$$;

-- Phòng ban đang thao tác: Owner có thể chọn "thao tác với vai trò" để test.
create or replace function public.fn_me_dept() returns varchar
language sql stable security definer set search_path = public as $$
  select case when u.app_role = 'owner' then coalesce(u.acting_dept_code, u.dept_code) else u.dept_code end
  from public.app_users u where u.id = public.fn_me_id()
$$;

create or replace function public.fn_require_member() returns bigint
language plpgsql stable security definer set search_path = public as $$
declare v_id bigint := public.fn_me_id();
begin
  if v_id is null then
    raise exception 'Tài khoản chưa được cấp quyền sử dụng app' using errcode = '42501';
  end if;
  return v_id;
end $$;

create or replace function public.fn_require_owner() returns bigint
language plpgsql stable security definer set search_path = public as $$
declare v_id bigint := public.fn_require_member();
begin
  if not public.fn_is_owner() then
    raise exception 'Chỉ Owner được thực hiện thao tác này' using errcode = '42501';
  end if;
  return v_id;
end $$;

create or replace function public.fn_note(p_note text) returns void
language sql volatile set search_path = public as $$
  select set_config('app.note', coalesce(left(p_note, 1000), ''), true)
$$;

-- ---------------------------------------------------------------------
-- 5. Trigger: audit cột, chặn xóa cứng, ghi audit_log
-- ---------------------------------------------------------------------
create or replace function public.tg_touch() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.created_at := coalesce(new.created_at, now());
    new.created_by := coalesce(new.created_by, public.fn_me_id());
  else
    new.created_at := old.created_at;
    new.created_by := old.created_by;
    new.updated_at := now();
    new.updated_by := public.fn_me_id();
    if new.is_deleted and not old.is_deleted then
      new.deleted_at := coalesce(new.deleted_at, now());
      new.deleted_by := coalesce(new.deleted_by, public.fn_me_id());
    end if;
  end if;
  return new;
end $$;

create or replace function public.tg_no_hard_delete() returns trigger
language plpgsql as $$
begin
  raise exception 'Không xóa cứng bản ghi ở bảng %; hãy dùng soft delete (is_deleted)', tg_table_name
    using errcode = '42501';
end $$;

create or replace function public.tg_audit() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_new jsonb := to_jsonb(new);
  v_old jsonb;
  v_old_diff jsonb;
  v_new_diff jsonb;
  v_action varchar(12) := tg_op;
  v_note text := nullif(current_setting('app.note', true), '');
  v_pid bigint;
begin
  if tg_op = 'UPDATE' then
    v_old := to_jsonb(old);
    select jsonb_object_agg(e.key, v_old -> e.key), jsonb_object_agg(e.key, e.value)
      into v_old_diff, v_new_diff
      from jsonb_each(v_new) e
     where e.value is distinct from v_old -> e.key
       and e.key not in ('updated_at','updated_by');
    if v_new_diff is null then
      return new;
    end if;
    if (v_new ->> 'is_deleted') = 'true' and (v_old ->> 'is_deleted') = 'false' then
      v_action := 'SOFT_DELETE';
    end if;
  else
    v_new_diff := v_new;
  end if;

  v_pid := case when tg_table_name = 'projects' then (v_new ->> 'id')::bigint
                else (v_new ->> 'project_id')::bigint end;

  insert into public.audit_log(table_name, record_id, project_id, action, note, old_data, new_data, changed_dept, created_by)
  values (tg_table_name, (v_new ->> 'id')::bigint, v_pid, v_action, v_note, v_old_diff, v_new_diff,
          public.fn_me_dept(), public.fn_me_id());

  -- Ghi chú chỉ gắn vào dòng log đầu tiên của thao tác
  if v_note is not null then
    perform set_config('app.note', '', true);
  end if;
  return new;
end $$;

create or replace function public.tg_audit_log_readonly() returns trigger
language plpgsql as $$
begin
  raise exception 'audit_log chỉ cho phép ghi thêm' using errcode = '42501';
end $$;

do $$
declare t text;
begin
  foreach t in array array['departments','app_users','registration_requests','field_defs','task_blocks',
                           'task_defs','projects','project_tasks','project_gates','project_comments','project_notices']
  loop
    execute format('create trigger trg_%1$s_touch before insert or update on public.%1$I
                    for each row execute function public.tg_touch()', t);
    execute format('create trigger trg_%1$s_no_delete before delete on public.%1$I
                    for each row execute function public.tg_no_hard_delete()', t);
  end loop;
  foreach t in array array['app_users','registration_requests','projects','project_tasks','project_gates',
                           'project_comments','project_notices']
  loop
    execute format('create trigger trg_%1$s_audit after insert or update on public.%1$I
                    for each row execute function public.tg_audit()', t);
  end loop;
end $$;

create trigger trg_audit_log_readonly before update or delete on public.audit_log
  for each row execute function public.tg_audit_log_readonly();

-- ---------------------------------------------------------------------
-- 6. Hàm nghiệp vụ nội bộ
-- ---------------------------------------------------------------------
create or replace function public.fn_task_done(p_project_id bigint, p_task_no smallint, p_round smallint)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.project_tasks t
                  where t.project_id = p_project_id and t.task_no = p_task_no and t.round = p_round
                    and t.status = 'done' and t.is_deleted = false)
$$;

create or replace function public.fn_gate_result(p_project_id bigint, p_gate varchar, p_round smallint)
returns varchar language sql stable security definer set search_path = public as $$
  select g.result from public.project_gates g
   where g.project_id = p_project_id and g.gate = p_gate and g.round = p_round and g.is_deleted = false
$$;

-- Bước hiện tại (block_no); NULL = đã xong toàn bộ quy trình.
create or replace function public.fn_current_block(p_project_id bigint)
returns smallint language plpgsql stable security definer set search_path = public as $$
declare v_round smallint; b record;
begin
  select p.round into v_round from public.projects p where p.id = p_project_id and p.is_deleted = false;
  for b in select tb.block_no, tb.gate from public.task_blocks tb where tb.is_deleted = false order by tb.block_no loop
    if b.gate is not null and coalesce(public.fn_gate_result(p_project_id, b.gate, v_round), '') <> 'yes' then
      return b.block_no;
    end if;
    if exists (select 1 from public.task_defs td
                where td.block_no = b.block_no and td.is_deleted = false
                  and not public.fn_task_done(p_project_id, td.task_no, v_round)) then
      return b.block_no;
    end if;
  end loop;
  return null;
end $$;

-- Thời điểm bước được "đến lượt" (bước trước hoàn tất) — dùng đo thời gian.
create or replace function public.fn_block_ready_at(p_project_id bigint, p_block_no smallint, p_round smallint)
returns timestamptz language sql stable security definer set search_path = public as $$
  select case when p_block_no = 1 then
           (select ((p.req_date + time '08:00') at time zone 'Asia/Ho_Chi_Minh') from public.projects p where p.id = p_project_id)
         else
           (select greatest(
              (select max(t.done_at) from public.project_tasks t join public.task_defs d on d.task_no = t.task_no
                where t.project_id = p_project_id and t.round = p_round and t.status = 'done'
                  and t.is_deleted = false and d.block_no = p_block_no - 1),
              (select max(g.decided_at) from public.project_gates g join public.task_blocks tb on tb.gate = g.gate
                where g.project_id = p_project_id and g.round = p_round and g.is_deleted = false
                  and tb.block_no = p_block_no - 1)))
         end
$$;

-- Ghi các trường của dự án từ jsonb; chỉ cho phép khóa nằm trong p_allowed.
create or replace function public.fn_apply_fields(p_project_id bigint, p_fields jsonb, p_allowed text[])
returns void language plpgsql security definer set search_path = public as $$
declare v_bad text; v_set text;
begin
  if p_fields is null or p_fields = '{}'::jsonb then return; end if;
  select k into v_bad from jsonb_object_keys(p_fields) k where not (k = any(p_allowed)) limit 1;
  if v_bad is not null then
    raise exception 'Trường "%" không thuộc quyền nhập của bạn ở ô này', v_bad using errcode = '42501';
  end if;
  select string_agg(format('%I = nullif(btrim($1 ->> %L), '''')::%s', f.field_key, f.field_key, f.pg_type), ', ')
    into v_set
    from public.field_defs f
   where f.field_key in (select jsonb_object_keys(p_fields)) and f.is_deleted = false;
  execute format('update public.projects set %s where id = $2 and is_deleted = false', v_set)
    using p_fields, p_project_id;
end $$;

create or replace function public.fn_missing_fields(p_project_id bigint, p_fields varchar[])
returns text language plpgsql stable security definer set search_path = public as $$
declare v_row jsonb; v_missing text;
begin
  select to_jsonb(p) into v_row from public.projects p where p.id = p_project_id;
  select string_agg(fd.label, ', ' order by array_position(p_fields, fd.field_key))
    into v_missing
    from public.field_defs fd
   where fd.field_key = any(p_fields)
     and nullif(btrim(coalesce(v_row ->> fd.field_key, '')), '') is null;
  return v_missing;
end $$;

create or replace function public.fn_check_complete(p_project_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  if public.fn_current_block(p_project_id) is null then
    perform public.fn_note('Hoàn thành toàn bộ quy trình – đã tung sản phẩm');
    update public.projects set status = 'launched'
     where id = p_project_id and status = 'active' and is_deleted = false;
  end if;
end $$;

create or replace function public.fn_lock_active_project(p_project_id bigint)
returns smallint language plpgsql security definer set search_path = public as $$
declare v_status varchar; v_round smallint;
begin
  select p.status, p.round into v_status, v_round from public.projects p
   where p.id = p_project_id and p.is_deleted = false for update;
  if not found then raise exception 'Không tìm thấy dự án'; end if;
  if v_status <> 'active' then raise exception 'Dự án không còn ở trạng thái đang thực hiện'; end if;
  return v_round;
end $$;

-- ---------------------------------------------------------------------
-- 7. RPC cho app (mọi thao tác ghi đi qua đây)
-- ---------------------------------------------------------------------
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
  v_allowed := v_allowed || array['iform'];
  if nullif(btrim(coalesce(p_fields ->> 'customer', '')), '') is null then
    raise exception 'Cần nhập: Đơn vị nhận mẫu';
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

create or replace function public.fn_save_task(p_project_id bigint, p_task_no smallint, p_fields jsonb, p_confirm boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_me bigint := public.fn_require_member();
  v_dept varchar := public.fn_me_dept();
  v_round smallint;
  t record;
  b record;
  v_task record;
  v_missing text;
  v_cur smallint;
  v_start timestamptz;
  v_prow record;
begin
  select td.task_no, td.block_no, td.dept_code, td.title, td.required_fields into t
    from public.task_defs td where td.task_no = p_task_no and td.is_deleted = false;
  if not found then raise exception 'Ô % không tồn tại', p_task_no; end if;
  if t.dept_code <> v_dept then
    raise exception 'Ô % thuộc phòng %, bạn không có quyền nhập', t.task_no, t.dept_code using errcode = '42501';
  end if;

  v_round := public.fn_lock_active_project(p_project_id);
  v_cur := public.fn_current_block(p_project_id);
  if v_cur is distinct from t.block_no then
    raise exception 'Chưa đến lượt bước của ô % (bước hiện tại: %)', t.task_no, coalesce(v_cur::text, 'đã hoàn tất');
  end if;
  select tb.gate, tb.gate_need into b from public.task_blocks tb where tb.block_no = t.block_no;
  if b.gate is not null and not (t.task_no = any(b.gate_need))
     and coalesce(public.fn_gate_result(p_project_id, b.gate, v_round), '') <> 'yes' then
    raise exception 'Cần ra quyết định của bước trước khi nhập ô %', t.task_no;
  end if;

  select pt.id, pt.status into v_task from public.project_tasks pt
   where pt.project_id = p_project_id and pt.task_no = t.task_no and pt.round = v_round and pt.is_deleted = false;
  if found and v_task.status = 'done' then
    raise exception 'Ô % đã xác nhận; bỏ xác nhận trước khi sửa', t.task_no;
  end if;

  perform public.fn_note(format('%s ô %s: %s', case when p_confirm then 'Xác nhận xong' else 'Lưu nháp' end, t.task_no, t.title));
  perform public.fn_apply_fields(p_project_id, p_fields, t.required_fields::text[]);

  if p_confirm then
    v_missing := public.fn_missing_fields(p_project_id, t.required_fields);
    if v_missing is not null then raise exception 'Cần nhập: %', v_missing; end if;
  end if;

  v_start := least(now(), coalesce(public.fn_block_ready_at(p_project_id, t.block_no, v_round), now()));
  if v_task.id is null then
    insert into public.project_tasks(project_id, task_no, round, status, started_at, started_by, done_at, done_by)
    values (p_project_id, t.task_no, v_round,
            case when p_confirm then 'done' else 'in_progress' end,
            case when p_confirm then v_start else now() end, v_me,
            case when p_confirm then now() end, case when p_confirm then v_me end);
  elsif p_confirm then
    update public.project_tasks set status = 'done', done_at = now(), done_by = v_me
     where id = v_task.id;
  end if;

  if p_confirm and t.task_no = 7 then
    select p.expected_sample, p.lot, p.production_line into v_prow from public.projects p where p.id = p_project_id;
    perform public.fn_note('Gửi thông báo ngày dự kiến có mẫu tới R&D và Kinh doanh');
    insert into public.project_notices(project_id, to_dept_codes, body, author_dept)
    values (p_project_id, array['RD','KD'],
            format('Kế hoạch chốt ngày dự kiến có mẫu %s, LOT %s, line %s',
                   to_char(v_prow.expected_sample, 'DD/MM/YYYY'), coalesce(v_prow.lot, '–'), coalesce(v_prow.production_line, '–')),
            v_dept);
  end if;

  if p_confirm then perform public.fn_check_complete(p_project_id); end if;
end $$;

create or replace function public.fn_undo_task(p_project_id bigint, p_task_no smallint)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_me bigint := public.fn_require_member();
  v_round smallint;
  t record;
  v_task_id bigint;
begin
  select td.task_no, td.block_no, td.dept_code, td.title into t
    from public.task_defs td where td.task_no = p_task_no and td.is_deleted = false;
  if not found then raise exception 'Ô % không tồn tại', p_task_no; end if;
  if t.dept_code <> public.fn_me_dept() then
    raise exception 'Bạn không có quyền với ô %', t.task_no using errcode = '42501';
  end if;
  v_round := public.fn_lock_active_project(p_project_id);
  if exists (select 1 from public.project_tasks pt join public.task_defs d on d.task_no = pt.task_no
              where pt.project_id = p_project_id and pt.round = v_round and pt.status = 'done'
                and pt.is_deleted = false and d.block_no > t.block_no)
     or exists (select 1 from public.project_gates g join public.task_blocks tb on tb.gate = g.gate
              where g.project_id = p_project_id and g.round = v_round and g.is_deleted = false
                and tb.block_no > t.block_no) then
    raise exception 'Các bước sau đã thực hiện, không bỏ xác nhận ô % được', t.task_no;
  end if;
  select pt.id into v_task_id from public.project_tasks pt
   where pt.project_id = p_project_id and pt.task_no = t.task_no and pt.round = v_round
     and pt.status = 'done' and pt.is_deleted = false;
  if v_task_id is null then raise exception 'Ô % chưa được xác nhận', t.task_no; end if;
  perform public.fn_note(format('Bỏ xác nhận ô %s để sửa', t.task_no));
  update public.project_tasks set status = 'reopened', done_at = null, done_by = null where id = v_task_id;
end $$;

create or replace function public.fn_decide_gate(p_project_id bigint, p_gate varchar, p_result varchar, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_me bigint := public.fn_require_member();
  v_round smallint;
  b record;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if p_result not in ('yes','no') then raise exception 'Kết quả không hợp lệ'; end if;
  select tb.block_no, tb.dept_code, tb.gate_need into b from public.task_blocks tb
   where tb.gate = p_gate and tb.is_deleted = false;
  if not found then raise exception 'Điểm quyết định không tồn tại'; end if;
  if b.dept_code <> public.fn_me_dept() then
    raise exception 'Quyết định này thuộc phòng %', b.dept_code using errcode = '42501';
  end if;
  v_round := public.fn_lock_active_project(p_project_id);
  if public.fn_current_block(p_project_id) is distinct from b.block_no then
    raise exception 'Chưa đến lượt quyết định này';
  end if;
  if exists (select 1 from unnest(b.gate_need) n where not public.fn_task_done(p_project_id, n, v_round)) then
    raise exception 'Cần xong ô % trước khi quyết định', array_to_string(b.gate_need, ', ');
  end if;
  if p_gate = 'feas' and p_result = 'no' and v_reason is null then
    raise exception 'Cần nhập lý do hủy dự án';
  end if;

  perform public.fn_note(case
    when p_gate = 'feas' and p_result = 'yes' then 'Quyết định: khả thi'
    when p_gate = 'feas' then 'Quyết định: không khả thi – hủy dự án. Lý do: ' || v_reason
    when p_result = 'yes' then 'Quyết định: KH đánh giá mẫu đạt'
    else 'Quyết định: không đạt – làm lại từ ô 2' || coalesce('. Ghi chú: ' || v_reason, '') end);
  insert into public.project_gates(project_id, gate, round, result, reason, decided_by)
  values (p_project_id, p_gate, v_round, p_result, v_reason, v_me);

  if p_gate = 'feas' and p_result = 'no' then
    update public.projects
       set status = 'cancelled', cancel_reason = v_reason, cancel_type = 'feas', cancelled_at = now(), cancelled_by = v_me
     where id = p_project_id and is_deleted = false;
  elsif p_gate = 'pass' and p_result = 'no' then
    perform public.fn_note(format('Bắt đầu vòng thử mẫu %s', v_round + 1));
    update public.projects set round = v_round + 1, is_pending = false, pending_reason = null
     where id = p_project_id and is_deleted = false;
    insert into public.project_tasks(project_id, task_no, round, status, started_at, started_by, done_at, done_by)
    values (p_project_id, 1, v_round + 1, 'done', now(), v_me, now(), v_me);
    -- Giữ quyết định khả thi của vòng trước cho vòng mới
    insert into public.project_gates(project_id, gate, round, result, reason, decided_by)
    values (p_project_id, 'feas', v_round + 1, 'yes', 'Kế thừa từ vòng ' || v_round, v_me);
  else
    perform public.fn_check_complete(p_project_id);
  end if;
end $$;

create or replace function public.fn_set_pending(p_project_id bigint, p_on boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_reason text := nullif(btrim(coalesce(p_reason, '')), ''); v_block smallint;
begin
  perform public.fn_require_member();
  if public.fn_me_dept() <> 'KH' then
    raise exception 'Chỉ Kế hoạch được báo pending' using errcode = '42501';
  end if;
  perform public.fn_lock_active_project(p_project_id);
  v_block := public.fn_current_block(p_project_id);
  if not exists (select 1 from public.task_blocks tb where tb.block_no = v_block and tb.dept_code = 'KH') then
    raise exception 'Chỉ báo pending khi dự án đang ở bước của Kế hoạch';
  end if;
  if p_on and v_reason is null then raise exception 'Cần nhập lý do pending'; end if;
  perform public.fn_note(case when p_on then 'Báo pending: ' || v_reason else 'Bỏ pending' end);
  update public.projects set is_pending = p_on, pending_reason = case when p_on then v_reason end
   where id = p_project_id and is_deleted = false;
end $$;

create or replace function public.fn_save_extra(p_project_id bigint, p_fields jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare v_allowed text[];
begin
  perform public.fn_require_member();
  perform public.fn_lock_active_project(p_project_id);
  select array_agg(fd.field_key) into v_allowed from public.field_defs fd
   where fd.is_extra and fd.dept_code = public.fn_me_dept() and fd.is_deleted = false;
  perform public.fn_note('Cập nhật thông tin thêm');
  perform public.fn_apply_fields(p_project_id, p_fields, coalesce(v_allowed, '{}'));
end $$;

create or replace function public.fn_cancel_project(p_project_id bigint, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v_me bigint := public.fn_require_owner(); v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if v_reason is null then raise exception 'Cần nhập lý do hủy dự án'; end if;
  perform public.fn_lock_active_project(p_project_id);
  perform public.fn_note('Owner hủy dự án. Lý do: ' || v_reason);
  update public.projects
     set status = 'cancelled', cancel_reason = v_reason, cancel_type = 'owner', cancelled_at = now(), cancelled_by = v_me
   where id = p_project_id and is_deleted = false;
end $$;

create or replace function public.fn_reopen_project(p_project_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare v_me bigint := public.fn_require_owner(); p record;
begin
  select pr.status, pr.round, pr.cancel_type, pr.cancel_reason into p from public.projects pr
   where pr.id = p_project_id and pr.is_deleted = false for update;
  if not found then raise exception 'Không tìm thấy dự án'; end if;
  if p.status = 'active' then raise exception 'Dự án đang thực hiện'; end if;
  perform public.fn_note('Owner mở lại dự án (lý do hủy trước đó: ' || coalesce(p.cancel_reason, 'không ghi') || ')');
  update public.projects set status = 'active' where id = p_project_id and is_deleted = false;
  if p.cancel_type = 'feas' then
    update public.project_gates set is_deleted = true
     where project_id = p_project_id and gate = 'feas' and round = p.round and result = 'no' and is_deleted = false;
  end if;
end $$;

create or replace function public.fn_add_comment(p_project_id bigint, p_body text, p_to_dept varchar default null, p_task_no smallint default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.fn_require_member();
  if nullif(btrim(coalesce(p_body, '')), '') is null then raise exception 'Nhập nội dung trao đổi'; end if;
  if not exists (select 1 from public.projects p where p.id = p_project_id and p.is_deleted = false) then
    raise exception 'Không tìm thấy dự án';
  end if;
  insert into public.project_comments(project_id, to_dept_code, task_no, body, author_dept)
  values (p_project_id, nullif(p_to_dept, ''), p_task_no, btrim(p_body), public.fn_me_dept());
end $$;

-- Ghi nhật ký hoạt động không làm đổi dữ liệu (ví dụ: mở email/Teams gửi thông báo)
create or replace function public.fn_log_activity(p_project_id bigint, p_note text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.fn_require_member();
  insert into public.audit_log(table_name, record_id, project_id, action, note, changed_dept, created_by)
  values ('projects', p_project_id, p_project_id, 'NOTE', left(p_note, 1000), public.fn_me_dept(), public.fn_me_id());
end $$;

-- ----- Người dùng -----
create or replace function public.fn_claim_membership()
returns varchar language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_user record;
  v_req varchar;
begin
  if v_uid is null then return 'anonymous'; end if;
  select u.id, u.status into v_user from public.app_users u
   where u.auth_user_id = v_uid and u.is_deleted = false;
  if found then
    return case when v_user.status = 'active' then 'active' else 'removed' end;
  end if;
  select u.id, u.status into v_user from public.app_users u
   where u.email = v_email and u.is_deleted = false and u.auth_user_id is null;
  if found and v_user.status = 'invited' then
    perform public.fn_note('Đăng nhập lần đầu – liên kết tài khoản');
    update public.app_users set auth_user_id = v_uid, status = 'active', linked_at = now() where id = v_user.id;
    return 'active';
  elsif found then
    return 'removed';
  end if;
  select r.status into v_req from public.registration_requests r
   where r.auth_user_id = v_uid and r.is_deleted = false order by r.created_at desc limit 1;
  return coalesce(v_req, 'none');
end $$;

create or replace function public.fn_register_request(p_display_name text, p_full_name text, p_dept varchar)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if v_uid is null or v_email = '' then raise exception 'Chưa đăng nhập'; end if;
  if exists (select 1 from public.app_users u where (u.auth_user_id = v_uid or u.email = v_email) and u.is_deleted = false) then
    raise exception 'Email này đã có trong danh sách người dùng';
  end if;
  update public.registration_requests set is_deleted = true
   where auth_user_id = v_uid and status = 'pending' and is_deleted = false;
  insert into public.registration_requests(auth_user_id, email, display_name, full_name, dept_code)
  values (v_uid, v_email, btrim(p_display_name), btrim(p_full_name), p_dept);
end $$;

create or replace function public.fn_approve_request(p_request_id bigint, p_dept varchar, p_role varchar)
returns void language plpgsql security definer set search_path = public as $$
declare v_me bigint := public.fn_require_owner(); r record;
begin
  select rr.auth_user_id, rr.email, rr.display_name, rr.full_name into r from public.registration_requests rr
   where rr.id = p_request_id and rr.status = 'pending' and rr.is_deleted = false for update;
  if not found then raise exception 'Đăng ký không còn ở trạng thái chờ duyệt'; end if;
  perform public.fn_note(format('Duyệt đăng ký %s (%s) – %s, quyền %s', r.full_name, r.email, p_dept, p_role));
  insert into public.app_users(auth_user_id, email, display_name, full_name, dept_code, app_role, status, linked_at)
  values (r.auth_user_id, r.email, r.display_name, r.full_name, p_dept, p_role, 'active', now());
  update public.registration_requests set status = 'approved', decided_at = now(), decided_by = v_me
   where id = p_request_id;
end $$;

create or replace function public.fn_reject_request(p_request_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare v_me bigint := public.fn_require_owner();
begin
  perform public.fn_note('Từ chối đăng ký');
  update public.registration_requests set status = 'rejected', decided_at = now(), decided_by = v_me
   where id = p_request_id and status = 'pending' and is_deleted = false;
  if not found then raise exception 'Đăng ký không còn ở trạng thái chờ duyệt'; end if;
end $$;

create or replace function public.fn_add_member(p_email text, p_display_name text, p_full_name text, p_dept varchar, p_role varchar)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.fn_require_owner();
  if exists (select 1 from public.app_users u where u.email = lower(btrim(p_email)) and u.is_deleted = false) then
    raise exception 'Email này đã có trong danh sách người dùng';
  end if;
  perform public.fn_note(format('Thêm nhân sự %s (%s) – %s, quyền %s, chờ đăng nhập lần đầu', p_full_name, p_email, p_dept, p_role));
  insert into public.app_users(email, display_name, full_name, dept_code, app_role, status)
  values (lower(btrim(p_email)), btrim(p_display_name), btrim(p_full_name), p_dept, p_role, 'invited');
end $$;

create or replace function public.fn_update_member(p_user_id bigint, p_display_name text, p_full_name text, p_email text, p_dept varchar, p_role varchar)
returns void language plpgsql security definer set search_path = public as $$
declare v_me bigint := public.fn_require_owner(); u record;
begin
  select au.id, au.status, au.app_role into u from public.app_users au
   where au.id = p_user_id and au.is_deleted = false for update;
  if not found then raise exception 'Không tìm thấy người dùng'; end if;
  if p_user_id = v_me and p_role <> 'owner' then
    raise exception 'Không thể tự bỏ quyền Owner của chính mình';
  end if;
  perform public.fn_note('Cập nhật thông tin người dùng');
  update public.app_users
     set display_name = btrim(p_display_name), full_name = btrim(p_full_name),
         email = lower(btrim(p_email)), dept_code = p_dept, app_role = p_role
   where id = p_user_id and is_deleted = false;
end $$;

create or replace function public.fn_remove_member(p_user_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare v_me bigint := public.fn_require_owner();
begin
  if p_user_id = v_me then raise exception 'Không thể tự gỡ quyền của chính mình'; end if;
  perform public.fn_note('Gỡ quyền người dùng');
  update public.app_users set status = 'removed'
   where id = p_user_id and is_deleted = false and status <> 'removed';
  if not found then raise exception 'Không tìm thấy người dùng'; end if;
end $$;

create or replace function public.fn_set_acting_dept(p_dept varchar)
returns void language plpgsql security definer set search_path = public as $$
declare v_me bigint := public.fn_require_owner();
begin
  perform public.fn_note('Owner chuyển vai trò thao tác sang ' || p_dept);
  update public.app_users set acting_dept_code = p_dept where id = v_me;
end $$;

-- ---------------------------------------------------------------------
-- 8. Phân quyền: RLS chỉ cho đọc; ghi qua RPC
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['departments','app_users','registration_requests','field_defs','task_blocks','task_defs',
                           'projects','project_tasks','project_gates','project_comments','project_notices','audit_log']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end $$;

create policy p_departments_read on public.departments for select to authenticated using (is_deleted = false);
create policy p_field_defs_read  on public.field_defs  for select to authenticated using (is_deleted = false);
create policy p_task_blocks_read on public.task_blocks for select to authenticated using (is_deleted = false);
create policy p_task_defs_read   on public.task_defs   for select to authenticated using (is_deleted = false);

create policy p_app_users_read on public.app_users for select to authenticated
  using (is_deleted = false and (public.fn_me_id() is not null or auth_user_id = auth.uid()));
create policy p_requests_read on public.registration_requests for select to authenticated
  using (is_deleted = false and (public.fn_is_owner() or auth_user_id = auth.uid()));
create policy p_projects_read on public.projects for select to authenticated
  using (is_deleted = false and public.fn_me_id() is not null);
create policy p_tasks_read on public.project_tasks for select to authenticated
  using (is_deleted = false and public.fn_me_id() is not null);
create policy p_gates_read on public.project_gates for select to authenticated
  using (is_deleted = false and public.fn_me_id() is not null);
create policy p_comments_read on public.project_comments for select to authenticated
  using (is_deleted = false and public.fn_me_id() is not null);
create policy p_notices_read on public.project_notices for select to authenticated
  using (is_deleted = false and public.fn_me_id() is not null);
create policy p_audit_read on public.audit_log for select to authenticated
  using (public.fn_me_id() is not null);

-- Hàm: chỉ tài khoản đăng nhập được gọi; hàm nội bộ không mở cho client.
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  public.fn_me_id(), public.fn_is_owner(), public.fn_me_dept(), public.fn_current_block(bigint),
  public.fn_create_project(jsonb), public.fn_save_task(bigint, smallint, jsonb, boolean),
  public.fn_undo_task(bigint, smallint), public.fn_decide_gate(bigint, varchar, varchar, text),
  public.fn_set_pending(bigint, boolean, text), public.fn_save_extra(bigint, jsonb),
  public.fn_cancel_project(bigint, text), public.fn_reopen_project(bigint),
  public.fn_add_comment(bigint, text, varchar, smallint), public.fn_log_activity(bigint, text),
  public.fn_claim_membership(), public.fn_register_request(text, text, varchar),
  public.fn_approve_request(bigint, varchar, varchar), public.fn_reject_request(bigint),
  public.fn_add_member(text, text, text, varchar, varchar),
  public.fn_update_member(bigint, text, text, text, varchar, varchar),
  public.fn_remove_member(bigint), public.fn_set_acting_dept(varchar)
to authenticated;
alter default privileges in schema public revoke execute on functions from public, anon;

-- Realtime: client tự tải lại khi có thay đổi
alter publication supabase_realtime add table
  public.projects, public.project_tasks, public.project_gates, public.project_comments,
  public.project_notices, public.app_users, public.registration_requests;

commit;
