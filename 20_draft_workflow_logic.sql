-- =====================================================================
--  20 — منطق المسودة (draft) قبل الإرسال للمدير
--  ينفذ بعد 19
--
--  دورة المسودة:
--   يُنشئ النظام (أو الموظف) مستخلصاً بحالة draft
--   → الموظف يرفع المرفقات ويستكمل البيانات ثم يرسله (draft → pending_manager)
--
--  هنا نسمح بإدراج/تعديل حالة draft، ونضبط التنبيهات وحمايات التعديل.
-- =====================================================================

-- إدراج: موظف الإدارة يُنشئ draft أو pending_manager مباشرة
drop policy if exists ext_insert on public.extracts;
create policy ext_insert on public.extracts for insert with check (
  current_role_of() = 'department'
  and department_id = current_dept_of()
  and submitted_by = auth.uid()
  and status in ('draft','pending_manager'));

-- تعديل محتوى المسودة + الإرسال (draft → pending_manager)
drop policy if exists ext_update_dept_edit on public.extracts;
create policy ext_update_dept_edit on public.extracts
  for update using (current_role_of()='department' and department_id=current_dept_of()
      and status in ('draft','pending_manager','pending_review','in_progress'))
  with check (current_role_of()='department' and department_id=current_dept_of()
      and status in ('draft','pending_manager','pending_review','in_progress'));

-- حماية: الموظف يُرسل المسودة/المُرجَع فقط، ولا يعدّل بعد الفاتورة
create or replace function public.enforce_extract_edit()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if current_role_of() = 'department' then
    if old.status in ('completed','paid') then
      raise exception 'لا يمكن تعديل المستخلص بعد رفع الفاتورة الضريبية';
    end if;
    if new.status is distinct from old.status
       and not ( (old.status='returned' and new.status='pending_manager')
              or (old.status='draft'    and new.status='pending_manager') ) then
      raise exception 'لا يمكنك تغيير حالة المستخلص';
    end if;
  end if;
  return new;
end; $$;
drop trigger if exists trg_enforce_extract_edit on public.extracts;
create trigger trg_enforce_extract_edit before update on public.extracts
  for each row execute function public.enforce_extract_edit();

-- التنبيهات: مسودة جديدة (بانتظار الإرسال) + تنبيه عند الإرسال للمدير
create or replace function public.notify_on_status()
returns trigger language plpgsql security definer set search_path = public as $$
declare proj_name text;
begin
  select name into proj_name from public.projects where id = new.project_id;
  if (tg_op = 'INSERT') then
    if new.status = 'draft' then
      insert into public.notifications(target_dept, extract_id, message)
      values (new.department_id, new.id,
        'طلب مستخلص جديد ' || new.extract_number || ' — ' || coalesce(proj_name,'') || ' (بانتظار الإرسال)');
    else
      insert into public.notifications(target_dept, extract_id, message)
      values (new.department_id, new.id,
        'مستخلص جديد ' || new.extract_number || ' بانتظار اعتماد المدير المباشر');
    end if;
    return new;
  end if;
  if (tg_op = 'UPDATE' and new.status is distinct from old.status) then
    if new.status = 'pending_manager' then
      insert into public.notifications(target_dept, extract_id, message)
      values (new.department_id, new.id,
        'مستخلص ' || new.extract_number || ' بانتظار اعتماد المدير المباشر');
    elsif new.status = 'pending_review' and old.status = 'pending_manager' then
      insert into public.notifications(target_role, extract_id, message)
      values ('accounts_head', new.id,
        'مستخلص ' || new.extract_number || ' اعتمده المدير — بانتظار مراجعة رئيس الحسابات');
    elsif new.status = 'in_progress' and old.status = 'pending_review' then
      insert into public.notifications(target_role, extract_id, message)
      values ('accounts', new.id,
        'مستخلص ' || new.extract_number || ' قبله رئيس الحسابات — بانتظار رفع الفاتورة الضريبية');
    elsif new.status = 'returned' then
      insert into public.notifications(target_dept, extract_id, message)
      values (new.department_id, new.id,
        'تم إرجاع المستخلص ' || new.extract_number || ' لوجود ملاحظات: ' || coalesce(new.return_comment,''));
    elsif new.status = 'completed' then
      insert into public.notifications(target_dept, extract_id, message)
      values (new.department_id, new.id,
        'تم رفع الفاتورة على المنصة للمستخلص ' || new.extract_number || ' — بانتظار السداد');
    end if;
  end if;
  return new;
end; $$;
revoke execute on function public.notify_on_status() from anon, authenticated;
