-- =====================================================================
--  17 — تعديل المستخلص + ملحق تعديلاته
--  ينفذ بعد 16
--
--  منشئ الطلب (موظف الإدارة) يعدّل المبلغ/الملاحظات/رقم الدفعة في أي مرحلة
--  قبل رفع الفاتورة الضريبية (pending_manager/pending_review/in_progress).
--  كل تغيير في المبلغ يُسجَّل في ملحق extract_amendments (قبل/بعد + سبب).
--  البيانات الأمامية للمستخلص تُحدَّث بالقيمة الجديدة، والملحق يحفظ التاريخ.
-- =====================================================================

alter type history_action add value if not exists 'edited';

-- ملحق تعديلات المستخلص
create table if not exists public.extract_amendments (
  id             uuid primary key default gen_random_uuid(),
  extract_id     uuid not null references public.extracts(id) on delete cascade,
  amount_before  numeric(14,2),
  amount_after   numeric(14,2),
  note           text,
  created_by     uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at     timestamptz not null default now()
);
create index if not exists idx_extamend_extract on public.extract_amendments(extract_id);
alter table public.extract_amendments enable row level security;

drop policy if exists exa_read on public.extract_amendments;
create policy exa_read on public.extract_amendments for select using (
  exists(select 1 from public.extracts e where e.id=extract_id
    and (e.department_id=current_dept_of() or current_role_of() in ('accounts','accounts_head','admin','general_manager'))));

drop policy if exists exa_insert on public.extract_amendments;
create policy exa_insert on public.extract_amendments for insert with check (
  exists(select 1 from public.extracts e where e.id=extract_id
    and e.department_id=current_dept_of() and current_role_of()='department'
    and e.status in ('pending_manager','pending_review','in_progress','returned')));

-- الموظف يعدّل محتوى مستخلصه قبل الفاتورة
drop policy if exists ext_update_dept_edit on public.extracts;
create policy ext_update_dept_edit on public.extracts
  for update using (current_role_of()='department' and department_id=current_dept_of()
      and status in ('pending_manager','pending_review','in_progress'))
  with check (current_role_of()='department' and department_id=current_dept_of()
      and status in ('pending_manager','pending_review','in_progress'));

-- حماية: الموظف لا يغيّر الحالة (إلا إعادة الإرسال) ولا يعدّل بعد الفاتورة/السداد
create or replace function public.enforce_extract_edit()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if current_role_of() = 'department' then
    if old.status in ('completed','paid') then
      raise exception 'لا يمكن تعديل المستخلص بعد رفع الفاتورة الضريبية';
    end if;
    if new.status is distinct from old.status
       and not (old.status='returned' and new.status='pending_manager') then
      raise exception 'لا يمكنك تغيير حالة المستخلص';
    end if;
  end if;
  return new;
end; $$;
drop trigger if exists trg_enforce_extract_edit on public.extracts;
create trigger trg_enforce_extract_edit before update on public.extracts
  for each row execute function public.enforce_extract_edit();
