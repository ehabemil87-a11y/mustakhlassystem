-- =====================================================================
--  10 — المدة (أشهر + أيام) + ملاحق/تعديلات العقد
--  ينفذ بعد 09
--
--  • duration_days       = عدد الأشهر (كما في 09)
--  • duration_extra_days = أيام إضافية فوق الأشهر  → المدة = أشهر + أيام
--  • expected_end_date   = start_date + أشهر + أيام (محسوب ومخزّن)
--  • project_amendments  = سجل ملاحق العقد (زيادة/تخفيض قيمة، تمديد مدة)
-- =====================================================================

-- ---------- المدة: أيام إضافية فوق الأشهر ----------
alter table public.projects add column if not exists duration_extra_days int not null default 0;

alter table public.projects drop column if exists expected_end_date;
alter table public.projects add column expected_end_date date
  generated always as (
    (start_date + make_interval(months => duration_days, days => duration_extra_days))::date
  ) stored;

comment on column public.projects.duration_extra_days is 'أيام إضافية على المدة (المدة الكاملة = duration_days شهراً + duration_extra_days يوماً)';
comment on column public.projects.expected_end_date   is 'الانتهاء المفترض = start_date + duration_days شهراً + duration_extra_days يوماً';

-- ---------- ملاحق/تعديلات العقد ----------
create table if not exists public.project_amendments (
  id             uuid primary key default gen_random_uuid(),
  project_id     uuid not null references public.projects(id) on delete cascade,
  effective_date date,                                  -- تاريخ سريان التعديل
  value_change   numeric(14,2) not null default 0,      -- + زيادة / − تخفيض على قيمة العقد
  value_before   numeric(14,2),                         -- لقطة: القيمة قبل التعديل
  value_after    numeric(14,2),                         -- لقطة: القيمة بعد التعديل
  days_change    int not null default 0,                -- + تمديد / − تقليص بالأيام
  note           text,                                  -- السبب/البيان
  created_by     uuid default auth.uid(),
  created_at     timestamptz not null default now()
);
create index if not exists idx_amend_project on public.project_amendments(project_id);

alter table public.project_amendments enable row level security;

drop policy if exists pa_read on public.project_amendments;
create policy pa_read on public.project_amendments for select using (
  exists(select 1 from public.projects p where p.id = project_id
    and (p.department_id = current_dept_of() or current_role_of() in ('accounts','admin','general_manager')))
);

drop policy if exists pa_manage on public.project_amendments;
create policy pa_manage on public.project_amendments for all using (
  exists(select 1 from public.projects p where p.id = project_id
    and (current_role_of() = 'admin' or p.department_id = current_dept_of()))
) with check (
  exists(select 1 from public.projects p where p.id = project_id
    and (current_role_of() = 'admin' or p.department_id = current_dept_of()))
);

comment on table public.project_amendments is 'ملاحق/تعديلات العقد: زيادة/تخفيض القيمة، تمديد المدة، مع تاريخ السريان والسبب';
