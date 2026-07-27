-- =====================================================================
--  05 — تنبيهات التأخير حسب المراحل (SLA Delay Alerts)
--  ينفذ بعد 04_seed_storage.sql
--
--  يتيح للأدمن تحديد عدد الأيام المسموح بها لكل مرحلة من مراحل دورة العمل،
--  وبعد تجاوز المدة يُنشأ تنبيه تلقائي بوجود تأخير للجهة المسؤولة، ويظهر
--  المستخلص في الواجهة بشارة «متأخر».
-- =====================================================================

-- ---------------------------------------------------------------------
--  1) تتبّع لحظة آخر تغيّر للحالة (نقيس مدة التأخير منها)
-- ---------------------------------------------------------------------
alter table public.extracts
  add column if not exists status_changed_at timestamptz not null default now();

create or replace function public.touch_status_changed()
returns trigger language plpgsql set search_path = public as $$
begin
  if (tg_op = 'UPDATE' and new.status is distinct from old.status) then
    new.status_changed_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists trg_status_changed on public.extracts;
create trigger trg_status_changed
  before update on public.extracts
  for each row execute function public.touch_status_changed();

-- ---------------------------------------------------------------------
--  2) جدول إعدادات التنبيهات (صف واحد فقط — Singleton)
--     كل عمود = الحد الأقصى للأيام قبل إطلاق تنبيه التأخير لتلك المرحلة.
--     القيمة 0 = تعطيل التنبيه لتلك المرحلة تحديداً.
-- ---------------------------------------------------------------------
create table if not exists public.sla_settings (
  id                  boolean primary key default true,
  pending_review_days int  not null default 2,   -- بانتظار مراجعة الحسابات (رفع/مراجعة المستخلص)
  in_progress_days    int  not null default 3,   -- بانتظار رفع الفاتورة من الحسابات
  returned_days       int  not null default 2,   -- بانتظار تعديل الإدارة وإعادة الإرسال
  enabled             boolean not null default true,
  updated_at          timestamptz not null default now(),
  constraint sla_singleton check (id)
);
insert into public.sla_settings (id) values (true) on conflict (id) do nothing;

alter table public.sla_settings enable row level security;

-- الجميع (المسجّلون) يقرؤون الإعدادات لحساب التأخير، والأدمن فقط يعدّلها
create policy sla_read on public.sla_settings
  for select using (auth.uid() is not null);
create policy sla_write on public.sla_settings
  for all using (current_role_of() = 'admin') with check (current_role_of() = 'admin');

-- ---------------------------------------------------------------------
--  3) دالة توليد تنبيهات التأخير
--     تفحص المستخلصات المتوقفة في مرحلة تجاوزت مدتها، وتنشئ تنبيهاً واحداً
--     لكل (مستخلص/مرحلة) — تتجنب التكرار بفحص عدم وجود تنبيه تأخير مطابق
--     منذ آخر تغيّر للحالة. تعيد عدد التنبيهات التي أنشأتها.
-- ---------------------------------------------------------------------
create or replace function public.generate_delay_alerts()
returns int
language plpgsql security definer set search_path = public
as $$
declare
  s    public.sla_settings;
  rec  record;
  cnt  int := 0;
begin
  select * into s from public.sla_settings where id = true;
  if not found or not s.enabled then
    return 0;
  end if;

  for rec in
    select e.id, e.extract_number, e.department_id, e.status, e.status_changed_at
    from public.extracts e
    where e.status in ('pending_review','in_progress','returned')
  loop
    if rec.status = 'pending_review' and s.pending_review_days > 0
       and rec.status_changed_at < now() - make_interval(days => s.pending_review_days) then
      if not exists (
        select 1 from public.notifications n
        where n.extract_id = rec.id and n.message like 'تأخير في مراجعة%'
          and n.created_at > rec.status_changed_at
      ) then
        insert into public.notifications(target_role, extract_id, message)
        values ('accounts', rec.id,
          'تأخير في مراجعة المستخلص ' || rec.extract_number ||
          ' (تجاوز ' || s.pending_review_days || ' يوم منذ الاستلام)');
        cnt := cnt + 1;
      end if;

    elsif rec.status = 'in_progress' and s.in_progress_days > 0
       and rec.status_changed_at < now() - make_interval(days => s.in_progress_days) then
      if not exists (
        select 1 from public.notifications n
        where n.extract_id = rec.id and n.message like 'تأخير في رفع الفاتورة%'
          and n.created_at > rec.status_changed_at
      ) then
        insert into public.notifications(target_role, extract_id, message)
        values ('accounts', rec.id,
          'تأخير في رفع الفاتورة للمستخلص ' || rec.extract_number ||
          ' (تجاوز ' || s.in_progress_days || ' يوم قيد التنفيذ)');
        cnt := cnt + 1;
      end if;

    elsif rec.status = 'returned' and s.returned_days > 0
       and rec.status_changed_at < now() - make_interval(days => s.returned_days) then
      if not exists (
        select 1 from public.notifications n
        where n.extract_id = rec.id and n.message like 'تأخير في تعديل%'
          and n.created_at > rec.status_changed_at
      ) then
        insert into public.notifications(target_dept, extract_id, message)
        values (rec.department_id, rec.id,
          'تأخير في تعديل وإعادة إرسال المستخلص ' || rec.extract_number ||
          ' (تجاوز ' || s.returned_days || ' يوم كمرتجع)');
        cnt := cnt + 1;
      end if;
    end if;
  end loop;

  return cnt;
end;
$$;

-- الدوال الداخلية لا تُستدعى مباشرة عبر REST RPC
revoke execute on function public.generate_delay_alerts() from anon, authenticated;

-- ---------------------------------------------------------------------
--  4) جدولة تشغيل الدالة تلقائياً كل ساعة عبر pg_cron
--     (تنشئ التنبيهات دون الحاجة لأي خادم خارجي)
-- ---------------------------------------------------------------------
create extension if not exists pg_cron with schema pg_catalog;

select cron.schedule(
  'mustakhlas-delay-alerts',
  '0 * * * *',
  $$select public.generate_delay_alerts();$$
);
