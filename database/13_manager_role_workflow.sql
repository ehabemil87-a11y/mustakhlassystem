-- =====================================================================
--  13 — دور المدير المباشر + دورة الاعتماد الداخلية + المسمى الوظيفي
--  ينفذ بعد 12
--
--  دورة العمل الجديدة:
--   الموظف (department) ينشئ الطلب → pending_manager
--   المدير المباشر (dept_manager) يعتمد → pending_review (الحسابات)
--                              أو يرجع للموظف → returned
--   الموظف يعدّل المرتجع ويعيد الإرسال → pending_manager (اعتماد المدير من جديد)
--   الحسابات: pending_review → in_progress → completed (كالسابق)
-- =====================================================================

-- 1) قيم الأنواع الجديدة (تُنفَّذ منفصلة قبل استخدامها)
alter type user_role      add value if not exists 'dept_manager';
alter type extract_status add value if not exists 'pending_manager';
alter type history_action add value if not exists 'created';
alter type history_action add value if not exists 'manager_approved';
alter type history_action add value if not exists 'manager_returned';

-- 2) المسمى الوظيفي
alter table public.profiles add column if not exists job_title text;

-- 3) مُشغّل سجل الحركات محدّثاً لمرحلة اعتماد المدير المباشر
create or replace function public.log_history()
returns trigger language plpgsql security definer set search_path = public as $$
declare act history_action; cmt text;
begin
  if (tg_op = 'INSERT') then
    insert into public.extract_history(extract_id, action, actor_id, comment)
    values (new.id, 'created', new.submitted_by, null);
    return new;
  end if;
  if (tg_op = 'UPDATE' and new.status is distinct from old.status) then
    if    new.status = 'pending_review' and old.status = 'pending_manager' then act := 'manager_approved';
    elsif new.status = 'returned'       and old.status = 'pending_manager' then act := 'manager_returned';
    elsif new.status = 'returned'       then act := 'returned';
    elsif new.status = 'in_progress'    then act := 'moved_in_progress';
    elsif new.status = 'completed'      then act := 'invoiced';
    elsif new.status = 'pending_manager' and old.status = 'returned' then act := 'resubmitted';
    else  return new;
    end if;
    if act in ('returned','manager_returned') then cmt := new.return_comment; else cmt := null; end if;
    if new.delay_note is not null and length(trim(new.delay_note)) > 0 then
      cmt := coalesce(cmt || ' — ', '') || 'سبب التأخير: ' || new.delay_note;
    end if;
    insert into public.extract_history(extract_id, action, actor_id, comment)
    values (new.id, act, auth.uid(), cmt);
  end if;
  return new;
end; $$;
revoke execute on function public.log_history() from anon, authenticated;

-- 4) سياسات الصلاحيات
-- الموظف: ينشئ فقط بحالة pending_manager
drop policy if exists ext_insert on public.extracts;
create policy ext_insert on public.extracts
  for insert with check (
    current_role_of() = 'department'
    and department_id = current_dept_of()
    and submitted_by = auth.uid()
    and status = 'pending_manager'
  );

-- الموظف: يعيد إرسال المرتجع إلى المدير (returned -> pending_manager)
drop policy if exists ext_update_dept on public.extracts;
create policy ext_update_dept on public.extracts
  for update using (
    current_role_of() = 'department'
    and department_id = current_dept_of()
    and status = 'returned'
  ) with check (
    current_role_of() = 'department'
    and department_id = current_dept_of()
    and status = 'pending_manager'
  );

-- المدير المباشر: يعتمد (->pending_review) أو يرجع للموظف (->returned)
drop policy if exists ext_update_manager on public.extracts;
create policy ext_update_manager on public.extracts
  for update using (
    current_role_of() = 'dept_manager'
    and department_id = current_dept_of()
    and status = 'pending_manager'
  ) with check (
    current_role_of() = 'dept_manager'
    and department_id = current_dept_of()
    and status in ('pending_review','returned')
  );
