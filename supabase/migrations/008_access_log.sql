-- =====================================================================
-- 008_access_log.sql — Ghi lượt truy cập & thống kê cho Owner
-- Chạy SAU 007. Rollback: 008_access_log_rollback.sql
--
-- 1) access_log: mỗi lần người dùng mở app (đã đăng nhập, tài khoản đang hoạt động) ghi một lượt.
--    Mở lại trong vòng 30 phút không tính thêm lượt.
-- 2) fn_log_access(): app gọi khi vào màn hình chính.
-- 3) fn_access_stats(p_days): CHỈ Owner – trả về các lượt trong p_days ngày gần nhất (tối đa 730)
--    dạng một JSON gọn để app tự vẽ biểu đồ.
-- Bảng chỉ ghi thêm; không ai sửa / xóa qua API (RLS bật, không có policy).
-- =====================================================================
begin;

create table if not exists public.access_log (
  id          bigint generated always as identity primary key,
  user_id     bigint       not null references public.app_users(id),
  dept_code   varchar(10)  references public.departments(code),
  visited_at  timestamptz  not null default now(),
  created_at  timestamptz  not null default now(),
  is_deleted  boolean      not null default false
);
create index if not exists ix_access_log_user_time on public.access_log(user_id, visited_at desc);
create index if not exists ix_access_log_time on public.access_log(visited_at desc) where is_deleted = false;
alter table public.access_log enable row level security;
revoke all on public.access_log from anon, authenticated;

create or replace function public.fn_log_access()
returns void language plpgsql security definer set search_path = public as $$
declare v_me bigint := public.fn_me_id(); v_dept varchar;
begin
  if v_me is null then return; end if;
  if exists (select 1 from public.access_log a
              where a.user_id = v_me and a.visited_at > now() - interval '30 minutes' and a.is_deleted = false) then
    return;
  end if;
  select u.dept_code into v_dept from public.app_users u where u.id = v_me;
  insert into public.access_log(user_id, dept_code) values (v_me, v_dept);
end $$;

create or replace function public.fn_access_stats(p_days int default 400)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_days int := least(greatest(coalesce(p_days, 400), 1), 730);
begin
  perform public.fn_require_owner();
  return jsonb_build_object(
    'since', now() - make_interval(days => v_days),
    'first', (select min(a.visited_at) from public.access_log a where a.is_deleted = false),
    'visits', coalesce((
      select jsonb_agg(jsonb_build_array(a.user_id, floor(extract(epoch from a.visited_at))::bigint, a.dept_code)
                       order by a.visited_at)
        from public.access_log a
       where a.is_deleted = false and a.visited_at > now() - make_interval(days => v_days)), '[]'::jsonb),
    'last', coalesce((
      select jsonb_object_agg(x.user_id, floor(extract(epoch from x.last_at))::bigint)
        from (select a.user_id, max(a.visited_at) as last_at from public.access_log a
               where a.is_deleted = false group by a.user_id) x), '{}'::jsonb));
end $$;

revoke execute on function public.fn_log_access(), public.fn_access_stats(int) from public, anon;
grant execute on function public.fn_log_access(), public.fn_access_stats(int) to authenticated;

commit;
