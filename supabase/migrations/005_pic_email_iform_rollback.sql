-- Rollback cho 005_pic_email_iform.sql
-- Quay về: PIC nhập tự do theo tên, không lưu chi tiết iForm.
-- Các cột mới (sale_pic_email, rd_pic_email, plan_pic_email, iform_detail) được GIỮ LẠI
-- để không mất dữ liệu đã nhập; app cũ đơn giản là không dùng tới. Chạy lại 005 vẫn an toàn.
begin;

drop trigger if exists trg_projects_pic_email on public.projects;
drop function if exists public.tg_projects_pic_email();

update public.task_defs set required_fields = array_remove(required_fields, 'sale_pic_email') where task_no = 1;
update public.task_defs set required_fields = array_remove(required_fields, 'rd_pic_email')   where task_no = 3;
update public.task_defs set required_fields = array_remove(required_fields, 'plan_pic_email') where task_no = 7;

-- Đánh dấu xóa (soft delete) các trường đã thêm
update public.field_defs set is_deleted = true, deleted_at = now()
 where field_key in ('sale_pic_email', 'rd_pic_email', 'plan_pic_email', 'iform_detail') and is_deleted = false;

-- Khôi phục hàm theo 001 / 003
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
  v_allowed := v_allowed || array['iform'];
  if nullif(btrim(coalesce(p_fields ->> 'customer', '')), '') is null then
    raise exception 'Cần nhập: Đơn vị nhận mẫu';
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

create or replace function public.fn_apply_fields(p_project_id bigint, p_fields jsonb, p_allowed text[])
returns void language plpgsql security definer set search_path = public as $$
declare v_bad text; v_set text;
begin
  if p_fields is null or p_fields = '{}'::jsonb then return; end if;
  select k into v_bad from jsonb_object_keys(p_fields) k where not (k = any(p_allowed)) limit 1;
  if v_bad is not null then
    raise exception 'Trường "%" không thuộc quyền nhập của bạn ở ô này', v_bad using errcode = '42501';
  end if;
  select string_agg(format('%I = nullif(btrim($1 ->> %L), '''')::%s', f.field_key, f.field_key, f.pg_type), ', ')
    into v_set
    from public.field_defs f
   where f.field_key in (select jsonb_object_keys(p_fields)) and f.is_deleted = false;
  execute format('update public.projects set %s where id = $2 and is_deleted = false', v_set)
    using p_fields, p_project_id;
end $$;

create or replace function public.fn_notify_recipients(p_project_id bigint, p_dept varchar)
returns table(email text) language plpgsql stable security definer set search_path = public as $$
declare v_pic text;
begin
  select lower(btrim(case p_dept when 'KD' then p.sale_pic when 'RD' then p.rd_pic when 'KH' then p.plan_pic end))
    into v_pic from public.projects p where p.id = p_project_id;
  if v_pic is not null and v_pic <> '' then
    return query
      select u.email::text from public.app_users u
       where u.status = 'active' and u.is_deleted = false and u.dept_code = p_dept
         and (lower(btrim(u.display_name)) = v_pic or lower(btrim(u.full_name)) = v_pic);
    if found then return; end if;
  end if;
  return query
    select u.email::text from public.app_users u
     where u.status = 'active' and u.is_deleted = false and u.dept_code = p_dept;
end $$;

commit;
