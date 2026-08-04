-- =====================================================================
--  11 — حساب الانتهاء المفترض آمن عند فراغ الأشهر/الأيام
--  ينفذ بعد 10
--
--  make_interval(months => NULL) يُرجع NULL فيُبطل التاريخ كله.
--  نستخدم coalesce(..,0) حتى يُعامَل الفراغ كصفر.
--  (مفيد للمشاريع المقدّرة بالأيام فقط: المدة=0/فارغ، الأيام=258)
-- =====================================================================

alter table public.projects drop column if exists expected_end_date;
alter table public.projects add column expected_end_date date
  generated always as (
    (start_date + make_interval(months => coalesce(duration_days,0), days => coalesce(duration_extra_days,0)))::date
  ) stored;

comment on column public.projects.expected_end_date is 'الانتهاء المفترض = start_date + (duration_days أو 0) شهراً + (duration_extra_days أو 0) يوماً';
