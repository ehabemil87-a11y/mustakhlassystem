-- =====================================================================
--  06 — المدير العام (قراءة فقط) + رقم الدفعة + سبب التأخير
--  ينفذ بعد 05_sla_delay_alerts.sql
--
--  ملاحظة: أضف قيمة الـ enum في جملة منفصلة (خارج transaction) قبل بقية
--  الملف حتى تصبح القيمة متاحة للاستخدام:
--      alter type user_role add value if not exists 'general_manager';
-- =====================================================================

alter type user_role add value if not exists 'general_manager';

-- 1) أعمدة جديدة على المستخلصات
alter table public.extracts add column if not exists payment_number text; -- رقم الدفعة
alter table public.extracts add column if not exists delay_note     text; -- سبب تأخير آخر إجراء (يُسجَّل في السجل)

-- 2) تسجيل سبب التأخير في سجل الحركات مع كل إجراء مغيّر للحالة
create or replace function public.log_history()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  act history_action;
  cmt text;
begin
  if (tg_op = 'INSERT') then
    insert into public.extract_history(extract_id, action, actor_id, comment)
    values (new.id, 'submitted', new.submitted_by, null);
    return new;
  end if;

  if (tg_op = 'UPDATE' and new.status is distinct from old.status) then
    if    new.status = 'returned'       then act := 'returned';
    elsif new.status = 'in_progress'    then act := 'moved_in_progress';
    elsif new.status = 'completed'      then act := 'invoiced';
    elsif new.status = 'pending_review' and old.status = 'returned' then act := 'resubmitted';
    else  return new;
    end if;

    if act = 'returned' then cmt := new.return_comment; else cmt := null; end if;
    if new.delay_note is not null and length(trim(new.delay_note)) > 0 then
      cmt := coalesce(cmt || ' — ', '') || 'سبب التأخير: ' || new.delay_note;
    end if;

    insert into public.extract_history(extract_id, action, actor_id, comment)
    values (new.id, act, auth.uid(), cmt);
  end if;
  return new;
end;
$$;
revoke execute on function public.log_history() from anon, authenticated;

-- 3) توسيع سياسات القراءة لتشمل المدير العام (قراءة فقط لكل البيانات)
drop policy if exists ext_read on public.extracts;
create policy ext_read on public.extracts
  for select using (
    department_id = current_dept_of()
    or current_role_of() in ('accounts','admin','general_manager')
  );

drop policy if exists proj_read on public.projects;
create policy proj_read on public.projects
  for select using (
    department_id = current_dept_of()
    or current_role_of() in ('accounts','admin','general_manager')
  );

drop policy if exists inv_read on public.invoices;
create policy inv_read on public.invoices
  for select using (
    exists (select 1 from public.extracts e where e.id = extract_id
      and (e.department_id = current_dept_of() or current_role_of() in ('accounts','admin','general_manager'))));

drop policy if exists att_read on public.attachments;
create policy att_read on public.attachments
  for select using (
    exists (select 1 from public.extracts e where e.id = extract_id
      and (e.department_id = current_dept_of() or current_role_of() in ('accounts','admin','general_manager'))));

drop policy if exists hist_read on public.extract_history;
create policy hist_read on public.extract_history
  for select using (
    exists (select 1 from public.extracts e where e.id = extract_id
      and (e.department_id = current_dept_of() or current_role_of() in ('accounts','admin','general_manager'))));

drop policy if exists prof_read_self on public.profiles;
create policy prof_read_self on public.profiles
  for select using (id = auth.uid() or current_role_of() in ('accounts','admin','general_manager'));
