-- =====================================================================
-- 007_comment_mentions.sql — Tag @ trong trao đổi + card Teams
-- Chạy SAU 006. Rollback: 007_comment_mentions_rollback.sql
--
-- 1) project_comments thêm mention_user_ids (người được tag) và reply_to_comment_id
--    (tin này là phản hồi cho tin nào – tự xác định khi tag ngược lại người đã tag mình).
-- 2) fn_add_comment nhận thêm p_mentions (danh sách id người dùng).
-- 3) Mỗi người được tag (trừ chính người viết) nhận một card Teams:
--      "Bạn được … nhắc tên"  hoặc  "Bạn có 01 phản hồi từ …" (khi là phản hồi)
--    Dòng "Nội dung" được tô nền xám (emphasis). Nút "Mở hồ sơ để trả lời" → <app_url>#p-<id>-c
-- =====================================================================
begin;

alter table public.project_comments
  add column if not exists mention_user_ids    bigint[] not null default '{}',
  add column if not exists reply_to_comment_id bigint references public.project_comments(id);
create index if not exists ix_project_comments_mentions on public.project_comments using gin (mention_user_ids)
  where is_deleted = false;

-- Card trao đổi: tiêu đề không tô nền, dòng "Nội dung" tô nền xám
create or replace function public.fn_teams_card_chat(p_lead text, p_kicker text, p_title text, p_from text,
                                                    p_body text, p_ref_label text, p_ref text, p_at text, p_url text)
returns jsonb language plpgsql stable set search_path = public as $$
begin
  return jsonb_build_object(
    '$schema', 'http://adaptivecards.io/schemas/adaptive-card.json',
    'type', 'AdaptiveCard', 'version', '1.4',
    'msteams', jsonb_build_object('width', 'Full'),
    'fallbackText', regexp_replace(p_lead, '\*', '', 'g'),
    'body', jsonb_build_array(
      jsonb_build_object('type', 'TextBlock', 'text', '💬 ' || p_lead, 'wrap', true),
      jsonb_build_object('type', 'Container', 'spacing', 'Small', 'items', jsonb_build_array(
        jsonb_build_object('type', 'TextBlock', 'text', p_kicker, 'size', 'Small', 'weight', 'Bolder',
                           'isSubtle', true, 'wrap', true, 'maxLines', 1),
        jsonb_build_object('type', 'TextBlock', 'text', p_title, 'size', 'Medium', 'weight', 'Bolder',
                           'wrap', true, 'maxLines', 1, 'spacing', 'None'))),
      jsonb_build_object('type', 'Container', 'spacing', 'Medium', 'items', jsonb_build_array(
        public.fn_teams_fact_row('Từ', p_from, 1),
        jsonb_build_object('type', 'Container', 'style', 'emphasis', 'spacing', 'Small', 'items',
          jsonb_build_array(public.fn_teams_fact_row('Nội dung', p_body, 4))),
        public.fn_teams_fact_row(p_ref_label, p_ref, 1),
        public.fn_teams_fact_row('Lúc', p_at, 1))),
      jsonb_build_object('type', 'TextBlock', 'text', 'Theo dõi gửi mẫu · Duy Tân Recycling',
                         'size', 'Small', 'isSubtle', true, 'wrap', true, 'spacing', 'Medium')),
    'actions', case when coalesce(p_url, '') = '' then '[]'::jsonb
                    else jsonb_build_array(jsonb_build_object('type', 'Action.OpenUrl', 'title', 'Mở hồ sơ để trả lời', 'url', p_url)) end);
end $$;

-- Một dòng "nhãn – giá trị" (giống card 004)
create or replace function public.fn_teams_fact_row(p_label text, p_value text, p_max_lines int)
returns jsonb language sql immutable set search_path = public as $$
  select jsonb_build_object('type', 'ColumnSet', 'spacing', 'Small', 'columns', jsonb_build_array(
    jsonb_build_object('type', 'Column', 'width', '100px', 'items', jsonb_build_array(
      jsonb_build_object('type', 'TextBlock', 'text', p_label, 'isSubtle', true, 'wrap', true, 'maxLines', 1))),
    jsonb_build_object('type', 'Column', 'width', 'stretch', 'items', jsonb_build_array(
      jsonb_build_object('type', 'TextBlock', 'text', coalesce(nullif(btrim(p_value), ''), '–'),
                         'wrap', true, 'maxLines', p_max_lines)))))
$$;

-- Gửi card cho người được tag
create or replace function public.fn_notify_mentions(p_comment_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare
  c record; u record; rc_id bigint; rc_body text; rc_by bigint; v_author text; v_dept text; v_cur smallint; v_step text; v_task text;
  v_url text; v_reply boolean; v_lead text; v_sum text;
begin
  select pc.* into c from public.project_comments pc where pc.id = p_comment_id;
  if not found or cardinality(c.mention_user_ids) = 0 then return; end if;
  select au.display_name into v_author from public.app_users au where au.id = c.created_by;
  select d.name into v_dept from public.departments d where d.code = c.author_dept;
  v_cur := public.fn_current_block(c.project_id);
  if v_cur is not null and exists (select 1 from public.projects p where p.id = c.project_id and p.status = 'active') then
    v_step := ' · BƯỚC ' || v_cur || '/' || public.fn_teams_block_count();
  end if;
  if c.task_no is not null then
    select 'Ô ' || td.task_no || ' · ' || td.title into v_task from public.task_defs td where td.task_no = c.task_no;
  end if;
  if c.reply_to_comment_id is not null then
    select pc.id, pc.body, pc.created_by into rc_id, rc_body, rc_by from public.project_comments pc where pc.id = c.reply_to_comment_id;
  end if;
  v_url := public.fn_project_url(c.project_id);
  if v_url <> '' then v_url := v_url || '-c'; end if;

  for u in
    select distinct au.id, au.email::text as email from public.app_users au
     where au.id = any(c.mention_user_ids) and au.id is distinct from c.created_by
       and au.is_deleted = false and au.status <> 'removed'
  loop
    v_reply := rc_id is not null and rc_by = u.id;
    if v_reply then
      v_lead := 'Bạn có **01 phản hồi từ ' || coalesce(v_author, 'đồng nghiệp') || '** trong Theo dõi gửi mẫu';
      v_sum  := 'Bạn có 01 phản hồi từ ' || coalesce(v_author, 'đồng nghiệp') || ' trong Theo dõi gửi mẫu';
    else
      v_lead := 'Bạn được **' || coalesce(v_author, 'đồng nghiệp') || ' nhắc tên** trong Theo dõi gửi mẫu';
      v_sum  := 'Bạn được ' || coalesce(v_author, 'đồng nghiệp') || ' nhắc tên trong Theo dõi gửi mẫu';
    end if;
    perform public.fn_teams_send_card(c.project_id, u.email, case when v_reply then 'mention_reply' else 'mention' end, v_sum,
      public.fn_teams_card_chat(v_lead,
        case when v_reply then 'PHẢN HỒI TRAO ĐỔI' else 'TRAO ĐỔI' end || coalesce(v_step, ''),
        public.fn_project_title(c.project_id),
        concat_ws(' · ', v_author, v_dept),
        c.body,
        case when v_reply then 'Trả lời cho' else 'Liên quan' end,
        case when v_reply then left(rc_body, 120) else v_task end,
        public.fn_teams_fmt_at(c.created_at),
        v_url));
  end loop;
end $$;

-- fn_add_comment: thêm p_mentions (bản cũ 4 tham số được thay thế)
drop function if exists public.fn_add_comment(bigint, text, varchar, smallint);
create or replace function public.fn_add_comment(p_project_id bigint, p_body text, p_to_dept varchar default null,
                                                p_task_no smallint default null, p_mentions bigint[] default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_me bigint := public.fn_require_member(); v_ids bigint[]; v_reply bigint; v_id bigint;
begin
  if nullif(btrim(coalesce(p_body, '')), '') is null then raise exception 'Nhập nội dung trao đổi'; end if;
  if not exists (select 1 from public.projects p where p.id = p_project_id and p.is_deleted = false) then
    raise exception 'Không tìm thấy dự án';
  end if;
  select coalesce(array_agg(distinct au.id), '{}') into v_ids from public.app_users au
   where au.id = any(coalesce(p_mentions, '{}')) and au.is_deleted = false and au.status <> 'removed';
  if cardinality(v_ids) > 20 then raise exception 'Mỗi tin chỉ tag tối đa 20 người'; end if;

  -- Phản hồi: tin gần nhất trong dự án do một người mình tag viết, có tag mình
  select pc.id into v_reply from public.project_comments pc
   where pc.project_id = p_project_id and pc.is_deleted = false
     and pc.created_by = any(v_ids) and v_me = any(pc.mention_user_ids)
   order by pc.created_at desc limit 1;

  insert into public.project_comments(project_id, to_dept_code, task_no, body, author_dept, mention_user_ids, reply_to_comment_id)
  values (p_project_id, nullif(p_to_dept, ''), p_task_no, btrim(p_body), public.fn_me_dept(), v_ids, v_reply)
  returning id into v_id;
  perform public.fn_notify_mentions(v_id);
  return v_id;
end $$;

revoke execute on function public.fn_add_comment(bigint, text, varchar, smallint, bigint[]) from public, anon;
grant execute on function public.fn_add_comment(bigint, text, varchar, smallint, bigint[]) to authenticated;
revoke execute on function
  public.fn_notify_mentions(bigint),
  public.fn_teams_card_chat(text, text, text, text, text, text, text, text, text),
  public.fn_teams_fact_row(text, text, int)
from public, anon, authenticated;

commit;
