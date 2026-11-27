-- Rollback cho 008_access_log.sql
-- Gỡ hai hàm ghi / đọc lượt truy cập. Bảng access_log được GIỮ LẠI để không mất dữ liệu đã ghi;
-- muốn xóa hẳn thì chạy thủ công: drop table public.access_log;
begin;
drop function if exists public.fn_log_access();
drop function if exists public.fn_access_stats(int);
commit;
