-- =====================================================================
-- 003_teams_notify.sql — Tự gửi tin nhắn Teams riêng cho từng nhân sự
-- Chạy SAU 001 và 002. Rollback: 003_teams_notify_rollback.sql
--
-- Khi nào gửi:
--   1. Dự án chuyển sang bước mới  → người phụ trách bước đó
--   2. Kế hoạch chốt ngày có mẫu   → người phụ trách R&D và Kinh doanh
--   3. Dự án bị hủy / hoàn thành   → người phụ trách Kinh doanh và R&D
-- Gửi cho ai (mỗi người một tin nhắn riêng):
--   - PIC của phòng đó trong dự án (PIC Sale / PIC R&D / PIC Kế hoạch), nếu tên PIC
--     trùng tên hiển thị hoặc họ tên của một người dùng đang hoạt động thuộc phòng đó;
--   - nếu không tìm được PIC: gửi cho tất cả người dùng đang hoạt động của phòng.
-- Kênh gửi: một Workflow Power Automate nhận webhook rồi nhắn riêng qua Flow bot.
-- =====================================================================
begin;

create extension if not exists pg_net;

-- Cấu hình (client không đọc được: bật RLS, không có policy, không cấp quyền)
create table public.app_settings (
  id          smallint generated always as identity primary key,
  key         varchar(50)  not null unique,
  value       varchar(2000) not null default '',
  description varchar(300),
  created_at  timestamptz  not null default now(),
  created_by  bigint references public.app_users(id),
  updated_at  timestamptz,
  updated_by  bigint references public.app_users(id),
  is_deleted  boolean      not null default false,
  deleted_at  timestamptz,
  deleted_by  bigint references public.app_users(id)
);
alter table public.app_settings enable row level security;
revoke all on public.app_settings from anon, authenticated;
create trigger trg_app_settings_touch before insert or update on public.app_settings
  for each row execute function public.tg_touch();
create trigger trg_app_settings_no_delete before delete on public.app_settings
  for each row execute function public.tg_no_hard_delete();

insert into public.app_settings(key, value, description) values
  ('teams_webhook_url', '', 'Đường dẫn HTTP của Workflow Power Automate (trigger "When a Teams webhook request is received")'),
  ('app_url', '', 'Địa chỉ app trên GitHub Pages, dùng cho link "Mở app" trong tin nhắn'),
  ('teams_enabled', 'true', 'Đặt false để tạm ngưng gửi Teams');

-- Nhật ký gửi (chỉ ghi thêm)
create table public.notify_log (
  id          bigint generated always as identity primary key,
  project_id  bigint references public.projects(id),
  recipient   varchar(320) not null,
  reason      varchar(30)  not null,
  message     varchar(4000) not null,
  request_id  bigint,
  created_at  timestamptz  not null default now(),
  created_by  bigint,
  updated_at  timestamptz,
  updated_by  bigint
);
create index ix_notify_log_project on public.notify_log(project_id, created_at desc);
alter table public.notify_log enable row level security;
revoke all on public.notify_log from anon, authenticated;
create trigger trg_notify_log_readonly before update or delete on public.notify_log
  for each row execute function public.tg_audit_log_readonly();

alter table public.projects
  add column notified_block smallint,
  add column notified_round smallint;

create or replace function public.fn_setting(p_key varchar)
returns text language sql stable security definer set search_path = public as $$
  select s.value from public.app_settings s where s.key = p_key and s.is_deleted = false
$$;

-- Người nhận cho một phòng trong một dự án
create or replace function public.fn_notify_recipients(p_project_id bigint, p_dept varchar)
returns table(email text) language plpgsql stable security definer set search_path = public as $$
declare v_pic text;
begin
  select lower(btrim(case p_dept when 'KD' then p.sale_pic when 'RD' then p.rd_pic when 'KH' then p.plan_pic end))
    into v_pic from public.projects p where p.id = p_project_id;
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

-- Gửi một tin nhắn cho một người (bất đồng bộ qua pg_net).
-- Định dạng body theo chuẩn của trigger "When a Teams webhook request is received":
-- {"type":"message","attachments":[{adaptive card}]} + trường "recipient" (email người nhận).
create or replace function public.fn_teams_send(p_project_id bigint, p_email text, p_reason varchar, p_html text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_url text := public.fn_setting('teams_webhook_url');
  v_app text := public.fn_setting('app_url');
  v_text text;
  v_card jsonb;
  v_req bigint;
begin
  if coalesce(public.fn_setting('teams_enabled'), 'true') <> 'true' or coalesce(v_url, '') = '' then
    return;
  end if;
  -- HTML đơn giản -> Markdown của Adaptive Card; link "Mở app" chuyển thành nút
  v_text := regexp_replace(p_html, '<br><a [^>]*>[^<]*</a>', '', 'g');
  v_text := replace(replace(v_text, '<b>', '**'), '</b>', '**');
  v_text := replace(v_text, '<br>', E'\n\n');
  v_text := regexp_replace(v_text, '<[^>]+>', '', 'g');
  v_card := jsonb_build_object(
    '$schema', 'http://adaptivecards.io/schemas/adaptive-card.json',
    'type', 'AdaptiveCard', 'version', '1.4',
    'body', jsonb_build_array(jsonb_build_object('type', 'TextBlock', 'text', v_text, 'wrap', true)),
    'actions', case when coalesce(v_app, '') = '' then '[]'::jsonb
                    else jsonb_build_array(jsonb_build_object('type', 'Action.OpenUrl', 'title', 'Mở app', 'url', v_app)) end);
  v_req := net.http_post(
    url := v_url,
    body := jsonb_build_object(
      'type', 'message',
      'recipient', p_email,
      'attachments', jsonb_build_array(jsonb_build_object(
        'contentType', 'application/vnd.microsoft.card.adaptive', 'contentUrl', null, 'content', v_card))),
    headers := '{"Content-Type": "application/json"}'::jsonb);
  insert into public.notify_log(project_id, recipient, reason, message, request_id, created_by)
  values (p_project_id, p_email, p_reason, left(v_text, 4000), v_req, public.fn_me_id());
end $$;

create or replace function public.fn_teams_send_depts(p_project_id bigint, p_depts varchar[], p_reason varchar, p_html text)
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in select distinct x.email from unnest(p_depts) d, public.fn_notify_recipients(p_project_id, d) x loop
    perform public.fn_teams_send(p_project_id, r.email, p_reason, p_html);
  end loop;
end $$;

create or replace function public.fn_project_title(p_project_id bigint)
returns text language sql stable security definer set search_path = public as $$
  select p.customer || coalesce(' – ' || nullif(p.application, ''), '') from public.projects p where p.id = p_project_id
$$;

create or replace function public.fn_app_link()
returns text language sql stable security definer set search_path = public as $$
  select case when coalesce(public.fn_setting('app_url'), '') = '' then ''
              else '<br><a href="' || public.fn_setting('app_url') || '">Mở app Theo dõi gửi mẫu</a>' end
$$;

-- 1) Chuyển bước: gửi cho người phụ trách bước mới
create or replace function public.fn_notify_step(p_project_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare
  p record; v_cur smallint; b record; v_tasks text; v_dept_name text; v_html text;
begin
  select pr.status, pr.round, pr.notified_block, pr.notified_round into p
    from public.projects pr where pr.id = p_project_id and pr.is_deleted = false;
  if not found or p.status <> 'active' then return; end if;
  v_cur := public.fn_current_block(p_project_id);
  if v_cur is null or (p.notified_block = v_cur and p.notified_round = p.round) then return; end if;

  select tb.block_no, tb.dept_code, tb.name, tb.gate into b from public.task_blocks tb where tb.block_no = v_cur;
  select d.name into v_dept_name from public.departments d where d.code = b.dept_code;
  select string_agg('Ô ' || td.task_no || ': ' || td.title, '<br>' order by td.task_no) into v_tasks
    from public.task_defs td
   where td.block_no = v_cur and td.is_deleted = false
     and not public.fn_task_done(p_project_id, td.task_no, p.round);
  if b.gate is not null and coalesce(public.fn_gate_result(p_project_id, b.gate, p.round), '') <> 'yes' then
    v_tasks := 'Ra quyết định ' || case b.gate when 'feas' then 'khả thi' else 'đạt / không đạt' end
               || coalesce('<br>' || v_tasks, '');
  end if;
  v_html := format('<b>Đến lượt %s</b> – Bước %s/9: %s<br>Dự án: <b>%s</b>%s<br>Việc cần làm:<br>%s%s',
                   v_dept_name, v_cur, b.name, public.fn_project_title(p_project_id),
                   case when p.round > 1 then ' (vòng thử mẫu ' || p.round || ')' else '' end,
                   coalesce(v_tasks, ''), public.fn_app_link());

  update public.projects set notified_block = v_cur, notified_round = p.round where id = p_project_id;
  perform public.fn_teams_send_depts(p_project_id, array[b.dept_code], 'step', v_html);
end $$;

create or replace function public.tg_notify_step() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.fn_notify_step(new.project_id);
  return null;
end $$;
create trigger trg_project_tasks_notify after insert or update on public.project_tasks
  for each row execute function public.tg_notify_step();
create trigger trg_project_gates_notify after insert or update on public.project_gates
  for each row execute function public.tg_notify_step();

-- 2) Thông báo trong app (ví dụ: Kế hoạch chốt ngày có mẫu) → nhắn riêng các phòng nhận
create or replace function public.tg_notify_notice() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.fn_teams_send_depts(new.project_id, new.to_dept_codes, 'notice',
    format('<b>Thông báo dự án %s</b><br>%s%s', public.fn_project_title(new.project_id), new.body, public.fn_app_link()));
  return null;
end $$;
create trigger trg_project_notices_teams after insert on public.project_notices
  for each row execute function public.tg_notify_notice();

-- 3) Hủy / hoàn thành dự án
create or replace function public.tg_notify_status() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'cancelled' then
    perform public.fn_teams_send_depts(new.id, array['KD','RD','KH'], 'cancel',
      format('<b>Dự án đã hủy:</b> %s<br>Lý do: %s%s', public.fn_project_title(new.id), coalesce(new.cancel_reason, ''), public.fn_app_link()));
  elsif new.status = 'launched' then
    perform public.fn_teams_send_depts(new.id, array['KD','RD'], 'launch',
      format('<b>Dự án hoàn thành:</b> %s – đã sẵn sàng tung sản phẩm%s', public.fn_project_title(new.id), public.fn_app_link()));
  elsif new.status = 'active' and old.status <> 'active' then
    update public.projects set notified_block = null where id = new.id;
    perform public.fn_notify_step(new.id);
  end if;
  return null;
end $$;
create trigger trg_projects_notify_status after update of status on public.projects
  for each row when (old.status is distinct from new.status)
  execute function public.tg_notify_status();

-- Hàm nội bộ: không cho client gọi
revoke execute on function
  public.fn_setting(varchar), public.fn_notify_recipients(bigint, varchar),
  public.fn_teams_send(bigint, text, varchar, text), public.fn_teams_send_depts(bigint, varchar[], varchar, text),
  public.fn_project_title(bigint), public.fn_app_link(), public.fn_notify_step(bigint),
  public.tg_notify_step(), public.tg_notify_notice(), public.tg_notify_status()
from public, anon, authenticated;

commit;
