-- =====================================================================
--  15 — تحديث تنبيهات الحالة لدورة اعتماد المدير المباشر
--  ينفذ بعد 14
-- =====================================================================

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
      values ('accounts', new.id,
        'مستخلص ' || new.extract_number || ' اعتمده المدير — بانتظار مراجعة الحسابات');
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
    -- تنبيه «تم السداد» يُنشأ داخل log_history
  end if;
  return new;
end; $$;
revoke execute on function public.notify_on_status() from anon, authenticated;
