-- =====================================================================
--  09 — تحويل مدة المشروع من أيام إلى أشهر
--  ينفذ بعد 08
--
--  المدة الآن تُقاس بالأشهر: القيمة 60 تعني 60 شهراً.
--  تاريخ الانتهاء المفترض = تاريخ البداية + عدد الأشهر.
--  (اسم العمود duration_days تاريخي؛ قيمته تُفسَّر الآن كأشهر.)
-- =====================================================================

-- إعادة تعريف العمود المحسوب ليضيف أشهراً بدل الأيام
alter table public.projects drop column if exists expected_end_date;

alter table public.projects add column expected_end_date date
  generated always as ((start_date + make_interval(months => duration_days))::date) stored;

comment on column public.projects.duration_days   is 'مدة المشروع بالأشهر (الاسم تاريخي؛ القيمة تُفسَّر كأشهر)';
comment on column public.projects.expected_end_date is 'الانتهاء المفترض = start_date + duration_days شهراً (محسوب ومخزّن)';
