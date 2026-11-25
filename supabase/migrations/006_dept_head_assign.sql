-- =====================================================================
-- 006_dept_head_assign.sql — Trưởng phòng & phân công PIC
-- Chạy SAU 005. Rollback: 006_dept_head_assign_rollback.sql
--
-- 1) app_users.is_dept_head: Owner đánh dấu trưởng phòng (Kinh doanh, R&D, Kế hoạch; mỗi phòng
--    có thể nhiều người). Đổi phòng ban thì tự bỏ đánh dấu.
-- 2) Người nhận thông báo của một phòng:
--      email PIC → tên PIC (hồ sơ cũ) → TRƯỞNG PHÒNG → cả phòng (khi phòng chưa có trưởng phòng)
-- 3) Đến lượt một phòng mà hồ sơ chưa có PIC của phòng đó → trưởng phòng nhận card
--    "Cần phân công PIC …" (lam) thay cho card "Đến lượt".
-- 4) fn_assign_pic: trưởng phòng (của đúng phòng) hoặc Owner phân công PIC bất cứ lúc nào.
-- 5) Khi PIC của một phòng được gán / đổi (qua phân công hoặc ô 3, ô 7) → người đó nhận card
--    "Bạn được phân công" (xanh lá). Tự chọn chính mình thì không gửi.
-- =====================================================================
begin;

-- ---------- 1. Cột trưởng phòng ----------
alter table public.app_users add column if not exists is_dept_head boolean not null default false;
create index if not exists ix_app_users_dept_head on public.app_users(dept_code)
  where is_dept_head and is_deleted = false;

create or replace function public.tg_app_users_head_reset() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.dept_code is distinct from old.dept_code then new.is_dept_head := false; end if;
  return new;
end $$;
drop trigger if exists trg_app_users_head_reset on public.app_users;
create trigger trg_app_users_head_reset before update of dept_code on public.app_users
  for each row execute function public.tg_app_users_head_reset();

create or replace function public.fn_set_dept_head(p_user_id bigint, p_value boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_me bigint := public.fn_require_owner(); u record;
begin
  select au.id, au.display_name, au.dept_code into u from public.app_users au
   where au.id = p_user_id and au.is_deleted = false and au.status <> 'removed' for update;
  if not found then raise exception 'Không tìm thấy người dùng'; end if;
  perform public.fn_note(format('%s trưởng phòng: %s', case when p_value then 'Đánh dấu' else 'Bỏ đánh dấu' end, u.display_name));
  update public.app_users set is_dept_head = coalesce(p_value, false) where id = p_user_id;
end $$;

-- ---------- 2. Người nhận theo phòng (kèm lý do nhận) ----------
create or replace function public.fn_notify_targets(p_project_id bigint, p_dept varchar)
returns table(email text, mode varchar) language plpgsql stable security definer set search_path = public as $$
declare v_pic text; v_email citext;
begin
  select lower(btrim(case p_dept when 'KD' then p.sale_pic when 'RD' then p.rd_pic when 'KH' then p.plan_pic end)),
         case p_dept when 'KD' then p.sale_pic_email when 'RD' then p.rd_pic_email when 'KH' then p.plan_pic_email end
    into v_pic, v_email from public.projects p where p.id = p_project_id;

  if v_email is not null then
    return query select u.email::text, 'pic'::varchar from public.app_users u
      where u.email = v_email and u.is_deleted = false and u.status <> 'removed';
    if found then return; end if;
  end if;
  if v_pic is not null and v_pic <> '' then
    return query select u.email::text, 'pic'::varchar from public.app_users u
      where u.status = 'active' and u.is_deleted = false and u.dept_code = p_dept
        and (lower(btrim(u.display_name)) = v_pic or lower(btrim(u.full_name)) = v_pic);
    if found then return; end if;
  end if;
  return query select u.email::text, 'head'::varchar from public.app_users u
    where u.is_dept_head and u.dept_code = p_dept and u.is_deleted = false and u.status in ('active', 'invited');
  if found then return; end if;
  return query select u.email::text, 'dept'::varchar from public.app_users u
    where u.status = 'active' and u.is_deleted = false and u.dept_code = p_dept;
end $$;

create or replace function public.fn_notify_recipients(p_project_id bigint, p_dept varchar)
returns table(email text) language sql stable security definer set search_path = public as $$
  select t.email from public.fn_notify_targets(p_project_id, p_dept) t
$$;

-- Việc còn lại của một bước: "Ô 3 … · Ô 4 …" và số việc
create or replace function public.fn_block_todo(p_project_id bigint, p_block smallint, out todo text, out cnt int)
language plpgsql stable security definer set search_path = public as $$
declare v_round smallint; v_gate varchar;
begin
  select pr.round into v_round from public.projects pr where pr.id = p_project_id;
  select tb.gate into v_gate from public.task_blocks tb where tb.block_no = p_block;
  select string_agg('Ô ' || td.task_no || ' ' || td.title, ' · ' order by td.task_no), count(*)
    into todo, cnt
    from public.task_defs td
   where td.block_no = p_block and td.is_deleted = false
     and not public.fn_task_done(p_project_id, td.task_no, v_round);
  if v_gate is not null and coalesce(public.fn_gate_result(p_project_id, v_gate, v_round), '') <> 'yes' then
    todo := concat_ws(' · ', 'Quyết định ' || case v_gate when 'feas' then 'khả thi' else 'đạt / không đạt' end, todo);
    cnt := cnt + 1;
  end if;
  cnt := greatest(coalesce(cnt, 0), 1);
end $$;

-- ---------- 3. Chuyển bước: chưa có PIC → card "cần phân công" cho trưởng phòng ----------
create or replace function public.fn_notify_step(p_project_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare
  p record; v_cur smallint; b record; v_dept_name text; t record;
  v_pic_label text; v_pic text; v_kicker text; v_summary text; v_lead text; v_card jsonb; r record;
  v_heads text[];
begin
  select pr.status, pr.round, pr.notified_block, pr.notified_round, pr.sale_pic, pr.rd_pic into p
    from public.projects pr where pr.id = p_project_id and pr.is_deleted = false;
  if not found or p.status <> 'active' then return; end if;
  v_cur := public.fn_current_block(p_project_id);
  if v_cur is null or (p.notified_block = v_cur and p.notified_round = p.round) then return; end if;

  select tb.block_no, tb.dept_code, tb.name into b from public.task_blocks tb where tb.block_no = v_cur;
  select d.name into v_dept_name from public.departments d where d.code = b.dept_code;
  select * into t from public.fn_block_todo(p_project_id, v_cur);

  if b.dept_code = 'KD' then v_pic_label := 'PIC R&D'; v_pic := p.rd_pic;
  else v_pic_label := 'PIC Sale'; v_pic := p.sale_pic; end if;

  select array_agg(x.email) into v_heads from public.fn_notify_targets(p_project_id, b.dept_code) x where x.mode = 'head';
  update public.projects set notified_block = v_cur, notified_round = p.round where id = p_project_id;

  if v_heads is not null then
    v_kicker := upper('Cần phân công PIC ' || v_dept_name) || ' · BƯỚC ' || v_cur || '/' || public.fn_teams_block_count()
                || case when p.round > 1 then ' · VÒNG ' || p.round else '' end;
    v_summary := 'Bạn có 01 hồ sơ cần phân công từ Theo dõi gửi mẫu';
    v_lead := 'Bạn có **01 hồ sơ cần phân công** từ Theo dõi gửi mẫu';
  else
    v_kicker := upper('Đến lượt ' || v_dept_name) || ' · BƯỚC ' || v_cur || '/' || public.fn_teams_block_count()
                || case when p.round > 1 then ' · VÒNG ' || p.round else '' end;
    v_summary := 'Bạn có ' || lpad(t.cnt::text, 2, '0') || ' công việc mới từ Theo dõi gửi mẫu';
    v_lead := 'Bạn có **' || lpad(t.cnt::text, 2, '0') || ' công việc mới** từ Theo dõi gửi mẫu';
  end if;

  v_card := public.fn_teams_card('accent', v_lead, v_kicker, b.name,
    jsonb_build_array(
      jsonb_build_object('l', 'Dự án', 'v', public.fn_project_title(p_project_id)),
      jsonb_build_object('l', 'Việc cần làm', 'v', t.todo),
      jsonb_build_object('l', v_pic_label, 'v', v_pic),
      jsonb_build_object('l', 'Giao bởi', 'v', public.fn_teams_last_actor(p_project_id))),
    public.fn_project_url(p_project_id));

  if v_heads is not null then
    if jsonb_array_length(v_card -> 'actions') > 0 then
      v_card := jsonb_set(v_card, '{actions,0,title}', to_jsonb('Mở hồ sơ để phân công'::text));
    end if;
    for r in select distinct unnest(v_heads) as email loop
      perform public.fn_teams_send_card(p_project_id, r.email, 'assign_needed', v_summary, v_card);
    end loop;
  else
    perform public.fn_teams_send_card_depts(p_project_id, array[b.dept_code], 'step', v_summary, v_card);
  end if;
end $$;

-- ---------- 4. Phân công PIC (trưởng phòng / Owner) ----------
create or replace function public.fn_assign_pic(p_project_id bigint, p_dept varchar, p_email text)
returns void language plpgsql security definer set search_path = public as $$
declare v_me bigint := public.fn_require_member(); u record; v_status varchar; v_dept_name text;
begin
  if p_dept not in ('KD', 'RD', 'KH') then raise exception 'Phòng ban không hợp lệ'; end if;
  select d.name into v_dept_name from public.departments d where d.code = p_dept;
  if not public.fn_is_owner() and not exists (
       select 1 from public.app_users au where au.id = v_me and au.is_dept_head and au.dept_code = p_dept) then
    raise exception 'Chỉ trưởng phòng % hoặc Owner được phân công PIC', v_dept_name using errcode = '42501';
  end if;
  select pr.status into v_status from public.projects pr where pr.id = p_project_id and pr.is_deleted = false for update;
  if not found then raise exception 'Không tìm thấy hồ sơ'; end if;
  if v_status <> 'active' then raise exception 'Hồ sơ không còn đang chạy, không phân công được'; end if;
  select au.id, au.display_name, au.email, au.dept_code into u from public.app_users au
   where au.email = btrim(p_email)::citext and au.is_deleted = false and au.status <> 'removed';
  if not found then raise exception 'Email % không có trong danh sách tài khoản', p_email; end if;
  if u.dept_code <> p_dept then raise exception '% không thuộc phòng %', u.display_name, v_dept_name; end if;

  perform public.fn_note(format('Phân công PIC %s: %s', v_dept_name, u.display_name));
  if p_dept = 'KD' then update public.projects set sale_pic_email = u.email where id = p_project_id;
  elsif p_dept = 'RD' then update public.projects set rd_pic_email = u.email where id = p_project_id;
  else update public.projects set plan_pic_email = u.email where id = p_project_id; end if;
end $$;

-- ---------- 5. Card "Bạn được phân công" ----------
create or replace function public.fn_notify_assigned(p_project_id bigint, p_dept varchar, p_email citext)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_actor bigint := public.fn_me_id(); v_actor_email citext; v_status varchar; v_cur smallint; b record;
  v_dept_name text; t record; v_todo text; v_step text;
begin
  select au.email into v_actor_email from public.app_users au where au.id = v_actor;
  if v_actor_email is not null and v_actor_email = p_email then return; end if;   -- tự nhận việc
  select pr.status into v_status from public.projects pr where pr.id = p_project_id and pr.is_deleted = false;
  if v_status is distinct from 'active' then return; end if;
  if not exists (select 1 from public.project_tasks pt where pt.project_id = p_project_id) then return; end if; -- đang tạo hồ sơ

  select d.name into v_dept_name from public.departments d where d.code = p_dept;
  v_cur := public.fn_current_block(p_project_id);
  select tb.dept_code, tb.name into b from public.task_blocks tb where tb.block_no = v_cur;
  if v_cur is not null then v_step := 'Bước ' || v_cur || '/' || public.fn_teams_block_count() || ' · ' || b.name; end if;
  if b.dept_code = p_dept then
    select * into t from public.fn_block_todo(p_project_id, v_cur); v_todo := t.todo;
  else
    v_todo := 'Chưa tới lượt ' || v_dept_name || ' – sẽ báo khi đến bước';
  end if;

  perform public.fn_teams_send_card(p_project_id, p_email::text, 'assign',
    'Bạn có 01 công việc được phân công từ Theo dõi gửi mẫu',
    public.fn_teams_card('good', 'Bạn có **01 công việc được phân công** từ Theo dõi gửi mẫu',
      upper('Bạn được phân công · PIC ' || v_dept_name), public.fn_project_title(p_project_id),
      jsonb_build_array(
        jsonb_build_object('l', 'Dự án', 'v', public.fn_project_title(p_project_id)),
        jsonb_build_object('l', 'Bước hiện tại', 'v', v_step),
        jsonb_build_object('l', 'Việc cần làm', 'v', v_todo),
        jsonb_build_object('l', 'Phân công bởi', 'v', public.fn_teams_actor(v_actor, now()))),
      public.fn_project_url(p_project_id)));
end $$;

create or replace function public.tg_projects_pic_assigned() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('app.pic_backfill', true), '') = 'on' then return null; end if;
  if new.sale_pic_email is not null and new.sale_pic_email is distinct from old.sale_pic_email then
    perform public.fn_notify_assigned(new.id, 'KD', new.sale_pic_email); end if;
  if new.rd_pic_email is not null and new.rd_pic_email is distinct from old.rd_pic_email then
    perform public.fn_notify_assigned(new.id, 'RD', new.rd_pic_email); end if;
  if new.plan_pic_email is not null and new.plan_pic_email is distinct from old.plan_pic_email then
    perform public.fn_notify_assigned(new.id, 'KH', new.plan_pic_email); end if;
  return null;
end $$;
drop trigger if exists trg_projects_pic_assigned on public.projects;
create trigger trg_projects_pic_assigned after update of sale_pic_email, rd_pic_email, plan_pic_email
  on public.projects for each row execute function public.tg_projects_pic_assigned();

-- ---------- Quyền ----------
revoke execute on function
  public.tg_app_users_head_reset(), public.fn_notify_targets(bigint, varchar), public.fn_notify_recipients(bigint, varchar),
  public.fn_block_todo(bigint, smallint), public.fn_notify_step(bigint),
  public.fn_notify_assigned(bigint, varchar, citext), public.tg_projects_pic_assigned()
from public, anon, authenticated;
revoke execute on function public.fn_set_dept_head(bigint, boolean), public.fn_assign_pic(bigint, varchar, text) from public, anon;
grant execute on function public.fn_set_dept_head(bigint, boolean), public.fn_assign_pic(bigint, varchar, text) to authenticated;

commit;
