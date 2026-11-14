-- =====================================================================
-- 004_teams_card_v2.sql — Card Teams mới: cùng khung, dạng thông báo
-- Chạy SAU 003 (và 003b nếu có). Rollback: 004_teams_card_v2_rollback.sql
--
-- Mỗi card gồm: dòng "Bạn có 0X công việc / thông báo mới từ Theo dõi gửi mẫu",
-- dải tiêu đề có màu theo loại tin, đúng 4 dòng thông tin (mỗi dòng 1 hàng),
-- chân trang và nút "Mở hồ sơ" (mở thẳng hồ sơ: <app_url>#p-<id>).
--   Đến lượt      → lam    (accent)
--   Thông báo     → vàng   (warning)
--   Hủy dự án     → đỏ     (attention)
--   Hoàn thành    → xanh lá (good)
-- Không đổi bảng, không đổi dữ liệu; chỉ thêm hàm và thay nội dung 3 hàm trigger.
-- Hàm fn_teams_send / fn_teams_send_depts cũ được giữ nguyên để rollback được.
-- =====================================================================
begin;

-- Thời điểm theo giờ Việt Nam, dạng 14/11 09:41
create or replace function public.fn_teams_fmt_at(p_at timestamptz)
returns text language sql stable set search_path = public as $$
  select to_char(p_at at time zone 'Asia/Ho_Chi_Minh', 'DD/MM HH24:MI')
$$;

-- "Tên hiển thị · 14/11 09:41"
create or replace function public.fn_teams_actor(p_user_id bigint, p_at timestamptz)
returns text language sql stable security definer set search_path = public as $$
  select concat_ws(' · ',
           coalesce((select u.display_name from public.app_users u where u.id = p_user_id), 'Hệ thống'),
           public.fn_teams_fmt_at(p_at))
$$;

-- Người thao tác gần nhất trên dự án (xác nhận ô hoặc ra quyết định), dùng cho "Giao bởi" / "Chốt bởi"
create or replace function public.fn_teams_last_actor(p_project_id bigint)
returns text language sql stable security definer set search_path = public as $$
  select public.fn_teams_actor(x.by_id, x.at)
    from (
      select t.done_by as by_id, t.done_at as at from public.project_tasks t
       where t.project_id = p_project_id and t.status = 'done' and t.is_deleted = false
      union all
      select g.decided_by, g.decided_at from public.project_gates g
       where g.project_id = p_project_id and g.is_deleted = false
      union all
      select p.created_by, p.created_at from public.projects p where p.id = p_project_id
    ) x
   order by x.at desc nulls last
   limit 1
$$;

create or replace function public.fn_teams_block_count()
returns smallint language sql stable security definer set search_path = public as $$
  select count(*)::smallint from public.task_blocks tb where tb.is_deleted = false
$$;

-- Link mở thẳng hồ sơ; rỗng nếu chưa cấu hình app_url
create or replace function public.fn_project_url(p_project_id bigint)
returns text language sql stable security definer set search_path = public as $$
  select case when coalesce(public.fn_setting('app_url'), '') = '' then ''
              else public.fn_setting('app_url') || '#p-' || p_project_id end
$$;

-- Dựng Adaptive Card. p_facts: mảng [{"l": nhãn, "v": giá trị}] (luôn truyền 4 dòng để card cao bằng nhau)
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

-- Gửi một card cho một người (bất đồng bộ qua pg_net) và ghi notify_log
create or replace function public.fn_teams_send_card(p_project_id bigint, p_email text, p_reason varchar,
                                                    p_summary text, p_card jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_url text := public.fn_setting('teams_webhook_url');
  v_req bigint;
begin
  if coalesce(public.fn_setting('teams_enabled'), 'true') <> 'true' or coalesce(v_url, '') = '' then
    return;
  end if;
  v_req := net.http_post(
    url := v_url,
    body := jsonb_build_object(
      'type', 'message',
      'summary', p_summary,
      'recipient', p_email,
      'attachments', jsonb_build_array(jsonb_build_object(
        'contentType', 'application/vnd.microsoft.card.adaptive', 'contentUrl', null, 'content', p_card))),
    headers := '{"Content-Type": "application/json"}'::jsonb);
  insert into public.notify_log(project_id, recipient, reason, message, request_id, created_by)
  values (p_project_id, p_email, p_reason,
          left(concat_ws(' | ', p_summary,
                         p_card #>> '{body,1,items,0,text}', p_card #>> '{body,1,items,1,text}'), 4000),
          v_req, public.fn_me_id());
end $$;

create or replace function public.fn_teams_send_card_depts(p_project_id bigint, p_depts varchar[], p_reason varchar,
                                                          p_summary text, p_card jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in select distinct x.email from unnest(p_depts) d, public.fn_notify_recipients(p_project_id, d) x loop
    perform public.fn_teams_send_card(p_project_id, r.email, p_reason, p_summary, p_card);
  end loop;
end $$;

-- 1) Chuyển bước → card lam gửi người phụ trách bước mới
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

-- 2) Thông báo trong app → card vàng gửi các phòng nhận
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

-- 3) Hủy → card đỏ (3 phòng); hoàn thành → card xanh lá (KD, R&D); mở lại → báo bước hiện tại
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

-- Hàm nội bộ: không cho client gọi
revoke execute on function
  public.fn_teams_fmt_at(timestamptz), public.fn_teams_actor(bigint, timestamptz),
  public.fn_teams_last_actor(bigint), public.fn_teams_block_count(), public.fn_project_url(bigint),
  public.fn_teams_card(varchar, text, text, text, jsonb, text),
  public.fn_teams_send_card(bigint, text, varchar, text, jsonb),
  public.fn_teams_send_card_depts(bigint, varchar[], varchar, text, jsonb),
  public.fn_notify_step(bigint), public.tg_notify_notice(), public.tg_notify_status()
from public, anon, authenticated;

commit;
