-- =====================================================================
--  02 — الدوال والمشغّلات (Functions & Triggers)
--  ينفذ بعد 01_schema.sql
-- =====================================================================

-- ---------------------------------------------------------------------
--  دالة مساعدة: جلب دور المستخدم الحالي (تُستخدم في سياسات RLS)
-- ---------------------------------------------------------------------
create or replace function public.current_role_of()
returns user_role
language sql stable security definer set search_path = public
as $$
  select role from public.profiles where id = auth.uid();
$$;

-- دالة مساعدة: جلب إدارة المستخدم الحالي
create or replace function public.current_dept_of()
returns uuid
language sql stable security definer set search_path = public
as $$
  select department_id from public.profiles where id = auth.uid();
$$;

-- ---------------------------------------------------------------------
--  الترقيم التلقائي للمستخلص: CODE-YEAR-NNN
--  مثال: OPS-2026-014 — تسلسل مستقل لكل إدارة/سنة
-- ---------------------------------------------------------------------
create or replace function public.generate_extract_number()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  dept_code text;
  yr        text := to_char(now(), 'YYYY');
  seq       int;
begin
  select code into dept_code from public.departments where id = new.department_id;

  -- أعلى رقم تسلسلي مستخدم لنفس الإدارة ونفس السنة
  select coalesce(max( (regexp_match(extract_number, '-(\d+)$'))[1]::int ), 0) + 1
    into seq
  from public.extracts
  where department_id = new.department_id
    and extract_number like dept_code || '-' || yr || '-%';

  new.extract_number := dept_code || '-' || yr || '-' || lpad(seq::text, 3, '0');
  return new;
end;
$$;

create trigger trg_extract_number
  before insert on public.extracts
  for each row
  when (new.extract_number is null or new.extract_number = '')
  execute function public.generate_extract_number();

-- ---------------------------------------------------------------------
--  تحديث حقل last_updated تلقائياً عند أي تعديل على المستخلص
-- ---------------------------------------------------------------------
create or replace function public.touch_last_updated()
returns trigger language plpgsql as $$
begin
  new.last_updated := now();
  return new;
end;
$$;

create trigger trg_touch_extract
  before update on public.extracts
  for each row execute function public.touch_last_updated();

-- ---------------------------------------------------------------------
--  توليد الإشعارات تلقائياً عند تغيّر حالة المستخلص
--   - وصول مستخلص جديد / إعادة إرسال  => إشعار لكل الحسابات
--   - إرجاع للإدارة                    => إشعار لإدارة المستخلص
--   - رفع الفاتورة (completed)          => إشعار لإدارة المستخلص
-- ---------------------------------------------------------------------
create or replace function public.notify_on_status()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  proj_name text;
begin
  select name into proj_name from public.projects where id = new.project_id;

  -- إدراج جديد: مستخلص وصل للحسابات
  if (tg_op = 'INSERT') then
    insert into public.notifications(target_role, extract_id, message)
    values ('accounts', new.id,
      'مستخلص جديد ' || new.extract_number || ' — ' || coalesce(proj_name,'') || ' بانتظار المراجعة');
    return new;
  end if;

  -- تحديث: نتصرف حسب الانتقال في الحالة
  if (tg_op = 'UPDATE' and new.status is distinct from old.status) then

    if new.status = 'returned' then
      insert into public.notifications(target_dept, extract_id, message)
      values (new.department_id, new.id,
        'تم إرجاع المستخلص ' || new.extract_number || ' لوجود ملاحظات: ' || coalesce(new.return_comment,''));

    elsif new.status = 'pending_review' and old.status = 'returned' then
      insert into public.notifications(target_role, extract_id, message)
      values ('accounts', new.id,
        'تمت إعادة إرسال المستخلص ' || new.extract_number || ' بعد التعديل');

    elsif new.status = 'completed' then
      insert into public.notifications(target_dept, extract_id, message)
      values (new.department_id, new.id,
        'تم إصدار الفاتورة للمستخلص ' || new.extract_number);
    end if;
  end if;

  return new;
end;
$$;

create trigger trg_notify_insert
  after insert on public.extracts
  for each row execute function public.notify_on_status();

create trigger trg_notify_update
  after update on public.extracts
  for each row execute function public.notify_on_status();

-- ---------------------------------------------------------------------
--  تسجيل الحركة تلقائياً في سجل الحركات عند تغيّر الحالة
-- ---------------------------------------------------------------------
create or replace function public.log_history()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  act history_action;
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

    insert into public.extract_history(extract_id, action, actor_id, comment)
    values (new.id, act, auth.uid(),
            case when act = 'returned' then new.return_comment else null end);
  end if;
  return new;
end;
$$;

create trigger trg_history_insert
  after insert on public.extracts
  for each row execute function public.log_history();

create trigger trg_history_update
  after update on public.extracts
  for each row execute function public.log_history();
