-- Rollback cho 010_rename_app.sql: trả lại tên "Theo dõi gửi mẫu" trên card Teams.
begin;

create or replace function public.fn_app_link()
returns text language sql stable security definer set search_path = public as $$
  select case when coalesce(public.fn_setting('app_url'), '') = '' then ''
              else '<br><a href="' || public.fn_setting('app_url') || '">Mở app Theo dõi gửi mẫu</a>' end
$$;

create or replace function public.fn_teams_card(p_style varchar, p_lead text, p_kicker text, p_title text,
                                               p_facts jsonb, p_url text)
returns jsonb language plpgsql stable set search_path = public as $$
declare
  v_color text := case p_style when 'accent' then 'Accent' when 'warning' then 'Warning'
                               when 'attention' then 'Attention' else 'Good' end;
  v_rows jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
           'type', 'ColumnSet', 'spacing', 'Small',
           'columns', jsonb_build_array(
             jsonb_build_object('type', 'Column', 'width', '100px', 'items', jsonb_build_array(
               jsonb_build_object('type', 'TextBlock', 'text', f.e ->> 'l', 'isSubtle', true, 'wrap', true, 'maxLines', 1))),
             jsonb_build_object('type', 'Column', 'width', 'stretch', 'items', jsonb_build_array(
               jsonb_build_object('type', 'TextBlock', 'text', coalesce(nullif(btrim(f.e ->> 'v'), ''), '–'),
                                  'wrap', true, 'maxLines', 1))))
         ) order by f.n), '[]'::jsonb)
    into v_rows
    from jsonb_array_elements(p_facts) with ordinality as f(e, n);

  return jsonb_build_object(
    '$schema', 'http://adaptivecards.io/schemas/adaptive-card.json',
    'type', 'AdaptiveCard', 'version', '1.4',
    'msteams', jsonb_build_object('width', 'Full'),
    'fallbackText', regexp_replace(p_lead, '\*', '', 'g'),
    'body', jsonb_build_array(
      jsonb_build_object('type', 'TextBlock', 'text', '🔔 ' || p_lead, 'wrap', true),
      jsonb_build_object('type', 'Container', 'style', p_style, 'bleed', true, 'spacing', 'Medium',
        'items', jsonb_build_array(
          jsonb_build_object('type', 'TextBlock', 'text', p_kicker, 'size', 'Small', 'weight', 'Bolder',
                             'color', v_color, 'wrap', true, 'maxLines', 1),
          jsonb_build_object('type', 'TextBlock', 'text', p_title, 'size', 'Medium', 'weight', 'Bolder',
                             'wrap', true, 'maxLines', 1, 'spacing', 'None'))),
      jsonb_build_object('type', 'Container', 'spacing', 'Medium', 'items', v_rows),
      jsonb_build_object('type', 'TextBlock', 'text', 'Theo dõi gửi mẫu · Duy Tân Recycling',
                         'size', 'Small', 'isSubtle', true, 'wrap', true, 'spacing', 'Medium')),
    'actions', case when coalesce(p_url, '') = '' then '[]'::jsonb
                    else jsonb_build_array(jsonb_build_object('type', 'Action.OpenUrl', 'title', 'Mở hồ sơ', 'url', p_url)) end);
end $$;

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

create or replace function public.tg_notify_notice() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  p record; v_cur smallint; v_block text; v_dept_name text; v_kicker text; v_title text; v_facts jsonb;
  v_summary text := 'Bạn có 01 thông báo mới từ Theo dõi gửi mẫu';
begin
  select pr.expected_sample, pr.trial_date, pr.lot, pr.production_line into p
    from public.projects pr where pr.id = new.project_id;
  v_cur := public.fn_current_block(new.project_id);
  select tb.name into v_block from public.task_blocks tb where tb.block_no = v_cur;
  select d.name into v_dept_name from public.departments d where d.code = new.author_dept;
  v_kicker := upper('Thông báo từ ' || coalesce(v_dept_name, 'hệ thống'))
              || case when v_cur is not null then ' · BƯỚC ' || v_cur || '/' || public.fn_teams_block_count() else '' end;

  if new.author_dept = 'KH' and new.body like 'Kế hoạch chốt ngày%' then
    v_title := 'Đã chốt ngày có mẫu';
    v_facts := jsonb_build_array(
      jsonb_build_object('l', 'Dự án', 'v', public.fn_project_title(new.project_id)),
      jsonb_build_object('l', 'Ngày có mẫu', 'v', concat_ws(' · ', to_char(p.expected_sample, 'DD/MM/YYYY'),
                                                         'trial ' || to_char(p.trial_date, 'DD/MM/YYYY'))),
      jsonb_build_object('l', 'LOT · Line', 'v', coalesce(p.lot, '–') || ' · ' || coalesce(p.production_line, '–')),
      jsonb_build_object('l', 'Gửi bởi', 'v', public.fn_teams_actor(new.created_by, new.created_at)));
  else
    v_title := 'Thông báo mới';
    v_facts := jsonb_build_array(
      jsonb_build_object('l', 'Dự án', 'v', public.fn_project_title(new.project_id)),
      jsonb_build_object('l', 'Nội dung', 'v', new.body),
      jsonb_build_object('l', 'Bước hiện tại', 'v', v_block),
      jsonb_build_object('l', 'Gửi bởi', 'v', public.fn_teams_actor(new.created_by, new.created_at)));
  end if;

  perform public.fn_teams_send_card_depts(new.project_id, new.to_dept_codes, 'notice', v_summary,
    public.fn_teams_card('warning', 'Bạn có **01 thông báo mới** từ Theo dõi gửi mẫu', v_kicker, v_title,
                         v_facts, public.fn_project_url(new.project_id)));
  return null;
end $$;

create or replace function public.tg_notify_status() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_cur smallint; v_block text; v_total smallint := public.fn_teams_block_count(); v_days int;
  v_summary text := 'Bạn có 01 thông báo mới từ Theo dõi gửi mẫu';
  v_lead text := 'Bạn có **01 thông báo mới** từ Theo dõi gửi mẫu';
begin
  if new.status = 'cancelled' then
    v_cur := public.fn_current_block(new.id);
    select tb.name into v_block from public.task_blocks tb where tb.block_no = v_cur;
    perform public.fn_teams_send_card_depts(new.id, array['KD','RD','KH'], 'cancel', v_summary,
      public.fn_teams_card('attention', v_lead,
        'DỰ ÁN ĐÃ HỦY' || case when v_cur is not null then ' · DỪNG Ở BƯỚC ' || v_cur || '/' || v_total else '' end,
        public.fn_project_title(new.id),
        jsonb_build_array(
          jsonb_build_object('l', 'Dự án', 'v', public.fn_project_title(new.id)),
          jsonb_build_object('l', 'Lý do', 'v', new.cancel_reason),
          jsonb_build_object('l', 'Bước cuối', 'v', v_block),
          jsonb_build_object('l', 'Hủy bởi', 'v', public.fn_teams_actor(new.cancelled_by, coalesce(new.cancelled_at, now())))),
        public.fn_project_url(new.id)));
  elsif new.status = 'launched' then
    v_days := greatest(1, round(extract(epoch from (now() - new.created_at)) / 86400)::int);
    perform public.fn_teams_send_card_depts(new.id, array['KD','RD'], 'launch', v_summary,
      public.fn_teams_card('good', v_lead,
        'DỰ ÁN HOÀN THÀNH · BƯỚC ' || v_total || '/' || v_total,
        'Sẵn sàng tung sản phẩm',
        jsonb_build_array(
          jsonb_build_object('l', 'Dự án', 'v', public.fn_project_title(new.id)),
          jsonb_build_object('l', 'Mã SP', 'v', new.product_code),
          jsonb_build_object('l', 'Ngày tung SP', 'v', concat_ws(' · ', to_char(new.launch_date, 'DD/MM/YYYY'),
                                                              'tổng ' || v_days || ' ngày')),
          jsonb_build_object('l', 'Chốt bởi', 'v', public.fn_teams_last_actor(new.id))),
        public.fn_project_url(new.id)));
  elsif new.status = 'active' and old.status <> 'active' then
    update public.projects set notified_block = null where id = new.id;
    perform public.fn_notify_step(new.id);
  end if;
  return null;
end $$;

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

commit;
