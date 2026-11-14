-- Rollback cho 002_password_login.sql — chạy trên staging trước; sao lưu trước khi chạy trên production.
-- Sau rollback, app phải dùng lại bản đăng nhập bằng link email (cần SMTP).
begin;
drop function if exists public.fn_activate(text, text, text);
drop function if exists public.fn_reissue_activation(bigint);
drop function if exists public.fn_add_member(text, text, text, varchar, varchar);
drop function if exists public.fn_issue_activation(bigint);
alter table public.app_users
  drop column if exists activation_verified_at, drop column if exists activation_issued_by,
  drop column if exists activation_issued_at, drop column if exists activation_attempts,
  drop column if exists activation_expires_at, drop column if exists activation_hash;
-- Khôi phục fn_add_member và fn_claim_membership của 001: chạy lại hai hàm này từ 001_init.sql
commit;
