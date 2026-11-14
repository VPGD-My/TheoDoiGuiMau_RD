-- 003b: cập nhật định dạng tin nhắn Teams (Adaptive Card). Chỉ cần chạy nếu đã chạy 003 bản trước.
begin;
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

revoke execute on function public.fn_teams_send(bigint, text, varchar, text) from public, anon, authenticated;
commit;
