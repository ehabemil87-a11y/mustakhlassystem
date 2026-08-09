-- =====================================================================
--  21 — توليد المسودات الشهرية تلقائياً + تنبيه المسودات المتأخرة
--  ينفذ بعد 20
--
--  (5) في «تاريخ الاستحقاق» من كل شهر (يوم = يوم «تاريخ إستلام الموقع»
--      من المشروع، مع ضبطه لآخر يوم في الشهر إن لزم) يُنشأ تلقائياً مستخلص
--      بحالة draft لكل مشروع فعّال لم يُنشأ له مستخلص لهذا الشهر بعد،
--      ويُسنَد لأول موظف إدارة في إدارة المشروع، بفترة كامل الشهر الحالي.
--  (6) تنبيه للإدارة فور وجود مسودة جديدة غير مُرسَلة (عبر notify_on_status).
--  (7) تنبيه إضافي إذا بقيت المسودة 3 أيام دون إرسال (notify_stale_drafts).
-- =====================================================================

-- توليد مسودات الشهر الحالي
create or replace function public.generate_monthly_drafts()
returns int language plpgsql security definer set search_path = public as $$
declare r record; emp uuid; pm text := to_char(now(),'YYYY-MM'); cnt int := 0;
        today_d int := extract(day from now())::int;
        last_d  int := extract(day from (date_trunc('month', now()) + interval '1 month' - interval '1 day'))::int;
        due_dt  date;
begin
  for r in
    select p.* from public.projects p
    where p.is_active and p.start_date is not null
      and today_d = least(extract(day from p.start_date)::int, last_d)
      and not exists (select 1 from public.extracts e where e.project_id = p.id and e.period_month = pm)
  loop
    select id into emp from public.profiles
      where role='department' and is_active and department_id = r.department_id
      order by created_at limit 1;
    if emp is null then continue; end if;
    -- تاريخ المستخلص = تاريخ الاستحقاق (يوم إستلام الموقع ضمن الشهر الحالي)
    due_dt := (date_trunc('month', current_date)
               + (least(extract(day from r.start_date)::int, last_d) - 1) * interval '1 day')::date;
    insert into public.extracts(department_id, project_id, period_month, period_from, period_to, amount, submitted_by, status)
    values (r.department_id, r.id, pm, due_dt, due_dt, 0, emp, 'draft');
    cnt := cnt + 1;
  end loop;
  return cnt;
end $$;
revoke execute on function public.generate_monthly_drafts() from anon, authenticated;

-- تنبيه المسودات التي لم تُرسل منذ أكثر من 3 أيام (مرة واحدة لكل مسودة)
create or replace function public.notify_stale_drafts()
returns int language plpgsql security definer set search_path = public as $$
declare r record; cnt int := 0;
begin
  for r in
    select e.* from public.extracts e
    where e.status = 'draft' and e.submitted_at < now() - interval '3 days'
      and not exists (select 1 from public.notifications n
                      where n.extract_id = e.id and n.message like 'تنبيه: طلب%لم يُرسَل%')
  loop
    insert into public.notifications(target_dept, extract_id, message)
    values (r.department_id, r.id, 'تنبيه: طلب مستخلص ' || r.extract_number || ' لم يُرسَل منذ أكثر من 3 أيام');
    cnt := cnt + 1;
  end loop;
  return cnt;
end $$;
revoke execute on function public.notify_stale_drafts() from anon, authenticated;

-- الجدولة اليومية
create extension if not exists pg_cron;
select cron.schedule('generate-monthly-drafts', '0 1 * * *', $$select public.generate_monthly_drafts()$$);
select cron.schedule('notify-stale-drafts',     '0 2 * * *', $$select public.notify_stale_drafts()$$);
