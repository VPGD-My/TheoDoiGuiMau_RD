-- Rollback cho 009_customers_project_code.sql
-- Gỡ cơ chế tự cấp mã và các hàm đổi tên / gộp khách; fn_create_project quay về bản 005.
-- Bảng customers và các cột customer_id, project_seq, project_code được GIỮ LẠI (không mất mã đã cấp).
begin;
drop trigger if exists trg_projects_customer on public.projects;
drop function if exists public.tg_projects_customer();
drop function if exists public.fn_merge_customers(bigint, bigint), public.fn_rename_customer(bigint, text),
  public.fn_customer_resolve(text);
create or replace function public.fn_create_project(p_fields jsonb)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  v_me bigint := public.fn_require_member();
  v_id bigint;
  v_allowed text[];
  v_missing text;
  v_start timestamptz;
begin
  if public.fn_me_dept() <> 'KD' then
    raise exception 'Chỉ Kinh doanh được tạo dự án mới' using errcode = '42501';
  end if;
  select array_agg(distinct f) into v_allowed
    from public.task_defs td, unnest(td.required_fields) f where td.block_no = 1 and td.is_deleted = false;
  v_allowed := v_allowed || array['iform', 'iform_detail'];
  if nullif(btrim(coalesce(p_fields ->> 'customer', '')), '') is null then
    raise exception 'Cần nhập: Đơn vị nhận mẫu';
  end if;
  if p_fields ? 'iform_detail' and jsonb_typeof(p_fields -> 'iform_detail') not in ('object', 'string', 'null') then
    raise exception 'Chi tiết phiếu iForm không hợp lệ';
  end if;

  perform public.fn_note(format('Đăng ký dự án %s – xác nhận bước 1', p_fields ->> 'customer'));
  insert into public.projects(customer) values (btrim(p_fields ->> 'customer')) returning id into v_id;
  perform public.fn_apply_fields(v_id, p_fields, v_allowed);

  select string_agg(m, ', ') into v_missing
    from (select public.fn_missing_fields(v_id, td.required_fields) m
            from public.task_defs td where td.block_no = 1 and td.is_deleted = false order by td.task_no) x
   where m is not null;
  if v_missing is not null then raise exception 'Cần nhập: %', v_missing; end if;

  v_start := least(now(), coalesce(public.fn_block_ready_at(v_id, 1::smallint, 1::smallint), now()));
  insert into public.project_tasks(project_id, task_no, round, status, started_at, started_by, done_at, done_by)
  select v_id, td.task_no, 1, 'done', v_start, v_me, now(), v_me
    from public.task_defs td where td.block_no = 1 and td.is_deleted = false;
  return v_id;
end $$;
commit;
