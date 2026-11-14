-- Rollback cho 003_teams_notify.sql (dữ liệu dự án không bị ảnh hưởng; mất cấu hình và nhật ký gửi Teams)
begin;
drop trigger if exists trg_projects_notify_status on public.projects;
drop trigger if exists trg_project_notices_teams on public.project_notices;
drop trigger if exists trg_project_gates_notify on public.project_gates;
drop trigger if exists trg_project_tasks_notify on public.project_tasks;
drop function if exists public.tg_notify_status(), public.tg_notify_notice(), public.tg_notify_step(),
  public.fn_notify_step(bigint), public.fn_app_link(), public.fn_project_title(bigint),
  public.fn_teams_send_depts(bigint, varchar[], varchar, text), public.fn_teams_send(bigint, text, varchar, text),
  public.fn_notify_recipients(bigint, varchar), public.fn_setting(varchar);
alter table public.projects drop column if exists notified_round, drop column if exists notified_block;
drop table if exists public.notify_log, public.app_settings;
commit;
