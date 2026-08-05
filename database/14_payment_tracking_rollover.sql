-- =====================================================================
--  14 — تتبّع السداد + ترحيل المستخلصات غير المكتملة
--  ينفذ بعد 13
--
--  دورة ما بعد التنفيذ:
--   in_progress → (رفع الفاتورة على المنصة) → completed «تم الرفع على المنصة»
--             → (تسجيل السداد + إشعار السداد) → paid «تم السداد»
--
--  الترحيل: أول كل شهر تُرحَّل المستخلصات غير المكتملة (ليست completed/paid)
--          من الشهور السابقة إلى الشهر الحالي مع ملاحظة «مرحّل من شهر ...».
-- =====================================================================

-- قيم الأنواع الجديدة (تُنفَّذ منفصلة قبل الاستخدام)
alter type extract_status add value if not exists 'paid';
alter type history_action add value if not exists 'paid';

-- تاريخ السداد
alter table public.extracts add column if not exists paid_at timestamptz;

-- مُشغّل السجل: إجراء «تم السداد» + تنبيه السداد للإدارة
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
    elsif new.status = 'paid'           then act := 'paid';
    elsif new.status = 'pending_manager' and old.status = 'returned' then act := 'resubmitted';
    else  return new;
    end if;
    if act in ('returned','manager_returned') then cmt := new.return_comment; else cmt := null; end if;
    if new.delay_note is not null and length(trim(new.delay_note)) > 0 then
      cmt := coalesce(cmt || ' — ', '') || 'سبب التأخير: ' || new.delay_note;
    end if;
    insert into public.extract_history(extract_id, action, actor_id, comment)
    values (new.id, act, auth.uid(), cmt);
    if act = 'paid' then
      insert into public.notifications(target_dept, extract_id, message)
      values (new.department_id, new.id, 'تم سداد المستخلص ' || new.extract_number);
    end if;
  end if;
  return new;
end; $$;
revoke execute on function public.log_history() from anon, authenticated;

-- ترحيل المستخلصات غير المكتملة إلى الشهر الحالي
create or replace function public.rollover_open_extracts()
returns int language plpgsql security definer set search_path = public as $$
declare cur text := to_char(now(),'YYYY-MM'); n int;
begin
  with moved as (
    update public.extracts
    set period_month = cur,
        notes = case when notes is null or trim(notes)='' then '' else notes || ' | ' end
                || 'مرحّل من شهر ' || period_month
    where status not in ('completed','paid')
      and period_month < cur
    returning 1
  ) select count(*) into n from moved;
  return n;
end; $$;
revoke execute on function public.rollover_open_extracts() from anon, authenticated;

-- جدولة شهرية (أول كل شهر 00:05 UTC)
create extension if not exists pg_cron;
select cron.schedule('rollover-open-extracts', '5 0 1 * *', $$select public.rollover_open_extracts()$$);
