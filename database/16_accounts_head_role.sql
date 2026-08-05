-- =====================================================================
--  16 — فصل دور رئيس الحسابات عن موظف الحسابات
--  ينفذ بعد 15
--
--  الدائرة الصحيحة:
--   1) موظف الإدارة ينشئ
--   2) المدير المباشر يراجع ويرسل
--   3) رئيس الحسابات (accounts_head) يقبل (in_progress) أو يرجع (returned)
--   4) موظف الحسابات (accounts) يرفع الفاتورة الضريبية (completed)
--   5) موظف الحسابات يرفع إشعار السداد (paid)
-- =====================================================================

alter type user_role add value if not exists 'accounts_head';

-- قراءة: إضافة رئيس الحسابات لكل سياسات القراءة
drop policy if exists ext_read on public.extracts;
create policy ext_read on public.extracts for select using (
  department_id = current_dept_of() or current_role_of() in ('accounts','accounts_head','admin','general_manager'));

drop policy if exists hist_read on public.extract_history;
create policy hist_read on public.extract_history for select using (
  exists(select 1 from public.extracts e where e.id=extract_id and (e.department_id=current_dept_of() or current_role_of() in ('accounts','accounts_head','admin','general_manager'))));

drop policy if exists att_read on public.attachments;
create policy att_read on public.attachments for select using (
  exists(select 1 from public.extracts e where e.id=extract_id and (e.department_id=current_dept_of() or current_role_of() in ('accounts','accounts_head','admin','general_manager'))));

drop policy if exists inv_read on public.invoices;
create policy inv_read on public.invoices for select using (
  exists(select 1 from public.extracts e where e.id=extract_id and (e.department_id=current_dept_of() or current_role_of() in ('accounts','accounts_head','admin','general_manager'))));

drop policy if exists prof_read_self on public.profiles;
create policy prof_read_self on public.profiles for select using (
  id=auth.uid() or current_role_of() in ('accounts','accounts_head','admin','general_manager'));

drop policy if exists proj_read on public.projects;
create policy proj_read on public.projects for select using (
  department_id=current_dept_of() or current_role_of() in ('accounts','accounts_head','admin','general_manager'));

drop policy if exists pa_read on public.project_amendments;
create policy pa_read on public.project_amendments for select using (
  exists(select 1 from public.projects p where p.id=project_id and (p.department_id=current_dept_of() or current_role_of() in ('accounts','accounts_head','admin','general_manager'))));

-- تحديث: رئيس الحسابات يقبل/يرجع، موظف الحسابات يرفع الفاتورة/السداد
drop policy if exists ext_update_accounts on public.extracts;
create policy ext_update_accounts_head on public.extracts
  for update using (current_role_of() in ('accounts_head','admin') and status = 'pending_review')
  with check (current_role_of() in ('accounts_head','admin') and status in ('in_progress','returned'));
create policy ext_update_accounts_emp on public.extracts
  for update using (current_role_of() in ('accounts','admin') and status in ('in_progress','completed'))
  with check (current_role_of() in ('accounts','admin') and status in ('completed','paid'));

-- تنبيهات: المراجعة لرئيس الحسابات + تنبيه موظف الحسابات عند القبول
create or replace function public.notify_on_status()
returns trigger language plpgsql security definer set search_path = public as $$
declare proj_name text;
begin
  select name into proj_name from public.projects where id = new.project_id;
  if (tg_op = 'INSERT') then
    insert into public.notifications(target_dept, extract_id, message)
    values (new.department_id, new.id,
      'مستخلص جديد ' || new.extract_number || ' — ' || coalesce(proj_name,'') || ' بانتظار اعتماد المدير المباشر');
    return new;
  end if;
  if (tg_op = 'UPDATE' and new.status is distinct from old.status) then
    if new.status = 'pending_review' and old.status = 'pending_manager' then
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
    elsif new.status = 'pending_manager' and old.status = 'returned' then
      insert into public.notifications(target_dept, extract_id, message)
      values (new.department_id, new.id,
        'تمت إعادة إرسال المستخلص ' || new.extract_number || ' — بانتظار اعتماد المدير المباشر');
    elsif new.status = 'completed' then
      insert into public.notifications(target_dept, extract_id, message)
      values (new.department_id, new.id,
        'تم رفع الفاتورة على المنصة للمستخلص ' || new.extract_number || ' — بانتظار السداد');
    end if;
  end if;
  return new;
end; $$;
revoke execute on function public.notify_on_status() from anon, authenticated;
