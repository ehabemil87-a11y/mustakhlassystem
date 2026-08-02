-- =====================================================================
--  08 — تفاصيل المشروع (المنطقة، الجهة المالكة، تواريخ التنفيذ)
--  ينفذ بعد 07
--
--  expected_end_date عمود محسوب تلقائياً = start_date + duration_days
-- =====================================================================

alter table public.projects add column if not exists region          text; -- المنطقة
alter table public.projects add column if not exists owner_name      text; -- اسم الجهة المالكة للمشروع
alter table public.projects add column if not exists start_date      date; -- تاريخ استلام المشروع (البداية)
alter table public.projects add column if not exists duration_days   int;  -- مدة المشروع بالأيام
alter table public.projects add column if not exists actual_end_date date; -- تاريخ الانتهاء الفعلي

-- تاريخ الانتهاء المفترض = البداية + المدة (محسوب ومخزّن)
alter table public.projects add column if not exists expected_end_date date
  generated always as (start_date + duration_days) stored;
