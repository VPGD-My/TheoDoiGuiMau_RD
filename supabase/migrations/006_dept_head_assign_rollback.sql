-- Rollback cho 006_dept_head_assign.sql
-- Quay về: chưa có PIC thì gửi cả phòng; không có card phân công.
-- Cột app_users.is_dept_head được GIỮ LẠI (không mất dữ liệu đánh dấu); chạy lại 006 vẫn an toàn.
begin;

drop trigger if exists trg_projects_pic_assigned on public.projects;
drop trigger if exists trg_app_users_head_reset on public.app_users;

-- Khôi phục theo 005 / 004
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

create or replace function public.fn_notify_step(p_project_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare
  p record; v_cur smallint; b record; v_dept_name text; v_tasks text; v_cnt int;
  v_pic_label text; v_pic text; v_kicker text; v_summary text;
begin
  select pr.status, pr.round, pr.notified_block, pr.notified_round, pr.sale_pic, pr.rd_pic into p
    from public.projects pr where pr.id = p_project_id and pr.is_deleted = false;
  if not found or p.status <> 'active' then return; end if;
  v_cur := public.fn_current_block(p_project_id);
  if v_cur is null or (p.notified_block = v_cur and p.notified_round = p.round) then return; end if;

  select tb.block_no, tb.dept_code, tb.name, tb.gate into b from public.task_blocks tb where tb.block_no = v_cur;
  select d.name into v_dept_name from public.departments d where d.code = b.dept_code;

  select string_agg('Ô ' || td.task_no || ' ' || td.title, ' · ' order by td.task_no), count(*)
    into v_tasks, v_cnt
    from public.task_defs td
   where td.block_no = v_cur and td.is_deleted = false
     and not public.fn_task_done(p_project_id, td.task_no, p.round);
  if b.gate is not null and coalesce(public.fn_gate_result(p_project_id, b.gate, p.round), '') <> 'yes' then
    v_tasks := concat_ws(' · ', 'Quyết định ' || case b.gate when 'feas' then 'khả thi' else 'đạt / không đạt' end, v_tasks);
    v_cnt := v_cnt + 1;
  end if;
  v_cnt := greatest(v_cnt, 1);

  -- Phòng Kinh doanh xem PIC R&D; R&D và Kế hoạch xem PIC Sale
  if b.dept_code = 'KD' then v_pic_label := 'PIC R&D'; v_pic := p.rd_pic;
  else v_pic_label := 'PIC Sale'; v_pic := p.sale_pic; end if;

  v_kicker := upper('Đến lượt ' || v_dept_name) || ' · BƯỚC ' || v_cur || '/' || public.fn_teams_block_count()
              || case when p.round > 1 then ' · VÒNG ' || p.round else '' end;
  v_summary := 'Bạn có ' || lpad(v_cnt::text, 2, '0') || ' công việc mới từ Theo dõi gửi mẫu';

  update public.projects set notified_block = v_cur, notified_round = p.round where id = p_project_id;
  perform public.fn_teams_send_card_depts(p_project_id, array[b.dept_code], 'step', v_summary,
    public.fn_teams_card('accent',
      'Bạn có **' || lpad(v_cnt::text, 2, '0') || ' công việc mới** từ Theo dõi gửi mẫu',
      v_kicker, b.name,
      jsonb_build_array(
        jsonb_build_object('l', 'Dự án', 'v', public.fn_project_title(p_project_id)),
        jsonb_build_object('l', 'Việc cần làm', 'v', v_tasks),
        jsonb_build_object('l', v_pic_label, 'v', v_pic),
        jsonb_build_object('l', 'Giao bởi', 'v', public.fn_teams_last_actor(p_project_id))),
      public.fn_project_url(p_project_id)));
end $$;

drop function if exists
  public.tg_projects_pic_assigned(), public.fn_notify_assigned(bigint, varchar, citext),
  public.fn_assign_pic(bigint, varchar, text), public.fn_block_todo(bigint, smallint),
  public.fn_notify_targets(bigint, varchar), public.fn_set_dept_head(bigint, boolean),
  public.tg_app_users_head_reset();

revoke execute on function public.fn_notify_recipients(bigint, varchar), public.fn_notify_step(bigint)
from public, anon, authenticated;

commit;
