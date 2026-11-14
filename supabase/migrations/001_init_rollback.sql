-- Rollback cho 001_init.sql — CHỈ chạy trên môi trường thử/staging.
-- Trên production: sao lưu (pg_dump) trước khi chạy; script này xóa toàn bộ dữ liệu của app.
begin;

alter publication supabase_realtime drop table
  public.projects, public.project_tasks, public.project_gates, public.project_comments,
  public.project_notices, public.app_users, public.registration_requests;

drop function if exists
  public.fn_set_acting_dept(varchar), public.fn_remove_member(bigint),
  public.fn_update_member(bigint, text, text, text, varchar, varchar),
  public.fn_add_member(text, text, text, varchar, varchar), public.fn_reject_request(bigint),
  public.fn_approve_request(bigint, varchar, varchar), public.fn_register_request(text, text, varchar),
  public.fn_claim_membership(), public.fn_log_activity(bigint, text),
  public.fn_add_comment(bigint, text, varchar, smallint), public.fn_reopen_project(bigint),
  public.fn_cancel_project(bigint, text), public.fn_save_extra(bigint, jsonb),
  public.fn_set_pending(bigint, boolean, text), public.fn_decide_gate(bigint, varchar, varchar, text),
  public.fn_undo_task(bigint, smallint), public.fn_save_task(bigint, smallint, jsonb, boolean),
  public.fn_create_project(jsonb), public.fn_lock_active_project(bigint), public.fn_check_complete(bigint),
  public.fn_missing_fields(bigint, varchar[]), public.fn_apply_fields(bigint, jsonb, text[]),
  public.fn_block_ready_at(bigint, smallint, smallint), public.fn_current_block(bigint),
  public.fn_gate_result(bigint, varchar, smallint), public.fn_task_done(bigint, smallint, smallint)
  cascade;

drop table if exists
  public.audit_log, public.project_notices, public.project_comments, public.project_gates,
  public.project_tasks, public.projects, public.task_defs, public.task_blocks, public.field_defs,
  public.registration_requests cascade;
alter table public.departments drop constraint if exists fk_departments_created_by,
  drop constraint if exists fk_departments_updated_by, drop constraint if exists fk_departments_deleted_by;
drop table if exists public.app_users, public.departments cascade;

drop function if exists
  public.tg_audit_log_readonly(), public.tg_audit(), public.tg_no_hard_delete(), public.tg_touch(),
  public.fn_note(text), public.fn_require_owner(), public.fn_require_member(),
  public.fn_me_dept(), public.fn_is_owner(), public.fn_me_id() cascade;

commit;
