-- Rollback cho 004_teams_card_v2.sql: quay về card dạng chữ của 003/003b.
-- Không ảnh hưởng dữ liệu dự án; notify_log giữ nguyên.
begin;

-- Khôi phục 3 hàm gửi theo nội dung của 003
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

create or replace function public.tg_notify_notice() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.fn_teams_send_depts(new.project_id, new.to_dept_codes, 'notice',
    format('<b>Thông báo dự án %s</b><br>%s%s', public.fn_project_title(new.project_id), new.body, public.fn_app_link()));
  return null;
end $$;

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

drop function if exists
  public.fn_teams_send_card_depts(bigint, varchar[], varchar, text, jsonb),
  public.fn_teams_send_card(bigint, text, varchar, text, jsonb),
  public.fn_teams_card(varchar, text, text, text, jsonb, text),
  public.fn_project_url(bigint), public.fn_teams_block_count(), public.fn_teams_last_actor(bigint),
  public.fn_teams_actor(bigint, timestamptz), public.fn_teams_fmt_at(timestamptz);

revoke execute on function public.fn_notify_step(bigint), public.tg_notify_notice(), public.tg_notify_status()
from public, anon, authenticated;

commit;
