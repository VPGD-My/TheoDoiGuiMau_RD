-- Rollback cho 007_comment_mentions.sql
-- Quay về trao đổi không tag. Cột mention_user_ids, reply_to_comment_id được GIỮ LẠI (không mất dữ liệu).
begin;

drop function if exists public.fn_add_comment(bigint, text, varchar, smallint, bigint[]);
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
grant execute on function public.fn_add_comment(bigint, text, varchar, smallint) to authenticated;

drop function if exists public.fn_notify_mentions(bigint),
  public.fn_teams_card_chat(text, text, text, text, text, text, text, text, text),
  public.fn_teams_fact_row(text, text, int);

commit;
