-- =====================================================================
--  22 — صلاحية التعديل لمنشئ الطلب + ترحيل بملاحظة إلزامية + مشاريع للجميع
--  ينفذ بعد 21
--
--  (2) التعديل على المستخلص من حق منشئ الطلب فقط (submitted_by) لا كل موظفي الإدارة.
--  (10) المشاريع تصبح مرئية لكل مستخدم مُصادَق (تصفّح على مستوى الشركة).
--  (4) عند إغلاق الشهر: المستخلصات غير المكتملة تُرحَّل تلقائياً للشهر الحالي،
--      ويُرفع علم needs_rollover_note ليُلزَم الموظف بكتابة سبب عدم إرسالها.
-- =====================================================================

-- (2) صلاحية التعديل لمنشئ الطلب فقط
drop policy if exists ext_update_dept_edit on public.extracts;
create policy ext_update_dept_edit on public.extracts
  for update using (current_role_of()='department' and department_id=current_dept_of()
      and submitted_by = auth.uid()
      and status in ('draft','pending_manager','pending_review','in_progress'))
  with check (current_role_of()='department' and department_id=current_dept_of()
      and submitted_by = auth.uid()
      and status in ('draft','pending_manager','pending_review','in_progress'));

drop policy if exists ext_update_dept on public.extracts;
create policy ext_update_dept on public.extracts
  for update using (current_role_of()='department' and department_id=current_dept_of()
      and submitted_by = auth.uid() and status='returned')
  with check (current_role_of()='department' and department_id=current_dept_of()
      and submitted_by = auth.uid() and status='pending_manager');

-- (10) المشاريع مرئية لكل مستخدم مُصادَق عليه
drop policy if exists proj_read on public.projects;
create policy proj_read on public.projects for select
  using (auth.uid() is not null);

-- (4) ملاحظة إلزامية عند الترحيل
alter table public.extracts add column if not exists needs_rollover_note boolean not null default false;

create or replace function public.rollover_open_extracts()
returns int language plpgsql security definer set search_path = public as $$
declare cur text := to_char(now(),'YYYY-MM'); n int;
begin
  with moved as (
    update public.extracts
    set period_month = cur,
        period_from = case when period_from is not null
                           then (date_trunc('month', now()) + (extract(day from period_from)::int - 1) * interval '1 day')::date
                           else period_from end,
        period_to   = case when period_to is not null
                           then (date_trunc('month', now()) + (extract(day from period_to)::int - 1) * interval '1 day')::date
                           else period_to end,
        needs_rollover_note = true
    where status not in ('completed','paid')
      and period_month < cur
    returning id, department_id, extract_number, period_month
  ) select count(*) into n from moved;
  insert into public.notifications(target_dept, extract_id, message)
  select e.department_id, e.id,
         'تم ترحيل المستخلص ' || e.extract_number || ' إلى الشهر الحالي — يجب كتابة سبب عدم إرساله في حينه'
  from public.extracts e
  where e.needs_rollover_note = true and e.period_month = cur
    and not exists (select 1 from public.notifications x
                    where x.extract_id = e.id and x.message like 'تم ترحيل المستخلص%');
  return n;
end; $$;
revoke execute on function public.rollover_open_extracts() from anon, authenticated;
