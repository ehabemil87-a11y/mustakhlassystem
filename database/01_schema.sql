-- =====================================================================
--  نظام متابعة المستخلصات والإشراف عليها — مجموعة الذيابي
--  01 — مخطط قاعدة البيانات (Schema)
--  المنصة: Supabase (PostgreSQL)
--  ينفذ هذا الملف أولاً في SQL Editor على مشروع Supabase جديد ومنفصل
-- =====================================================================

-- تفعيل امتداد توليد المعرفات
create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------
--  الأنواع المخصصة (Enums)
-- ---------------------------------------------------------------------

-- أدوار المستخدمين في النظام
create type user_role as enum ('department', 'accounts', 'admin');

-- حالات المستخلص (دورة العمل)
--   pending_review = قيد المراجعة (وصل للحسابات)
--   in_progress    = قيد التنفيذ (الحسابات تجهز الفاتورة)
--   returned       = مرتجع للإدارة مع ملاحظة (نواقص)
--   completed      = مكتمل (تم رفع الفاتورة)
create type extract_status as enum ('pending_review', 'in_progress', 'returned', 'completed');

-- نوع الإجراء المسجل في سجل الحركات
create type history_action as enum ('submitted', 'resubmitted', 'returned', 'moved_in_progress', 'invoiced');

-- ---------------------------------------------------------------------
--  جدول الإدارات (Departments)
-- ---------------------------------------------------------------------
create table public.departments (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,               -- الاسم بالعربي: التشغيل والصيانة ...
  code        text not null unique,        -- كود مختصر يستخدم في ترقيم المستخلص: OPS, TRN, RDS, EQP
  created_at  timestamptz not null default now()
);

comment on table public.departments is 'الإدارات التي ترفع المستخلصات إلى الحسابات';

-- ---------------------------------------------------------------------
--  جدول المستخدمين / الملفات الشخصية (Profiles)
--  مرتبط 1:1 مع auth.users في Supabase Auth
-- ---------------------------------------------------------------------
create table public.profiles (
  id             uuid primary key references auth.users(id) on delete cascade,
  name           text not null,            -- اسم الموظف
  username       text not null unique,     -- اسم المستخدم الظاهر للدخول (بدون الدومين)
  role           user_role not null default 'department',
  department_id  uuid references public.departments(id) on delete set null, -- null لموظف الحسابات/الأدمن
  is_active      boolean not null default true,
  created_at     timestamptz not null default now()
);

comment on table public.profiles is 'بيانات المستخدمين وأدوارهم وإداراتهم';

-- ---------------------------------------------------------------------
--  جدول المشاريع (Projects) — يُستورد من ملف Excel لكل إدارة
-- ---------------------------------------------------------------------
create table public.projects (
  id             uuid primary key default gen_random_uuid(),
  department_id  uuid not null references public.departments(id) on delete cascade,
  name           text not null,            -- اسم المشروع
  code           text,                     -- كود المشروع (اختياري، من الشيت)
  is_active      boolean not null default true,
  created_at     timestamptz not null default now()
);

create index idx_projects_department on public.projects(department_id);
comment on table public.projects is 'مشاريع كل إدارة، تُستورد دفعة واحدة من ملف Excel';

-- ---------------------------------------------------------------------
--  جدول المستخلصات (Extracts) — السجل الرئيسي
-- ---------------------------------------------------------------------
create table public.extracts (
  id                uuid primary key default gen_random_uuid(),
  extract_number    text not null unique,          -- ترقيم تلقائي: OPS-2026-014
  department_id     uuid not null references public.departments(id),
  project_id        uuid not null references public.projects(id),
  period_month      text not null,                 -- الفترة: 2026-07 (سنة-شهر)
  amount            numeric(14,2) not null default 0,   -- قيمة المستخلص
  notes             text,                          -- ملاحظات الإدارة (اختياري)
  status            extract_status not null default 'pending_review',
  return_comment    text,                          -- آخر تعليق إرجاع من الحسابات
  submitted_by      uuid not null references public.profiles(id),
  submitted_at      timestamptz not null default now(),
  last_updated      timestamptz not null default now()
);

create index idx_extracts_department on public.extracts(department_id);
create index idx_extracts_status     on public.extracts(status);
create index idx_extracts_project    on public.extracts(project_id);
comment on table public.extracts is 'المستخلصات المرفوعة من الإدارات، وحالتها في دورة العمل';

-- ---------------------------------------------------------------------
--  جدول المرفقات (Attachments) — مصنفة بالنوع
-- ---------------------------------------------------------------------
--  أنواع المرفقات المقترحة (تُدار كنص حر أو قائمة في الواجهة):
--    'extract'      = المستخلص نفسه
--    'receipt'      = شهادة استلام
--    'quantities'   = كشف كميات
--    'other'        = أخرى
create table public.attachments (
  id            uuid primary key default gen_random_uuid(),
  extract_id    uuid not null references public.extracts(id) on delete cascade,
  storage_path  text not null,             -- المسار داخل bucket الخاص بالتخزين
  file_name     text not null,             -- اسم الملف الأصلي للعرض
  doc_type      text not null default 'other',  -- تصنيف المرفق
  uploaded_by   uuid references public.profiles(id),
  uploaded_at   timestamptz not null default now()
);

create index idx_attachments_extract on public.attachments(extract_id);
comment on table public.attachments is 'ملفات كل مستخلص، مخزنة في bucket خاص';

-- ---------------------------------------------------------------------
--  جدول الفواتير (Invoices) — علاقة 1:1 مع المستخلص
-- ---------------------------------------------------------------------
create table public.invoices (
  id               uuid primary key default gen_random_uuid(),
  extract_id       uuid not null unique references public.extracts(id) on delete cascade, -- UNIQUE يضمن فاتورة واحدة فقط
  invoice_number   text not null,           -- رقم الفاتورة اليدوي من نظام الحسابات
  amount           numeric(14,2) not null default 0,
  storage_path     text,                    -- ملف الفاتورة (اختياري)
  file_name        text,
  issued_by        uuid not null references public.profiles(id),
  issued_at        timestamptz not null default now()
);

comment on table public.invoices is 'فاتورة واحدة لكل مستخلص (قيد UNIQUE على extract_id)';

-- ---------------------------------------------------------------------
--  جدول سجل الحركات (Extract History) — Audit Trail
-- ---------------------------------------------------------------------
create table public.extract_history (
  id           uuid primary key default gen_random_uuid(),
  extract_id   uuid not null references public.extracts(id) on delete cascade,
  action       history_action not null,
  comment      text,                        -- تعليق الإجراء (مثلاً سبب الإرجاع)
  actor_id     uuid references public.profiles(id),
  created_at   timestamptz not null default now()
);

create index idx_history_extract on public.extract_history(extract_id);
comment on table public.extract_history is 'كل حركة على المستخلص لتتبع كامل (Timeline)';

-- ---------------------------------------------------------------------
--  جدول الإشعارات (Notifications) — تُنشأ تلقائياً بالمشغّلات
-- ---------------------------------------------------------------------
create table public.notifications (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid references public.profiles(id) on delete cascade, -- المستلم (null = كل الحسابات)
  target_role  user_role,                   -- بديل: توجيه لكل من له هذا الدور
  target_dept  uuid references public.departments(id), -- بديل: توجيه لإدارة معينة
  extract_id   uuid references public.extracts(id) on delete cascade,
  message      text not null,
  is_read      boolean not null default false,
  created_at   timestamptz not null default now()
);

create index idx_notifications_user on public.notifications(user_id, is_read);
create index idx_notifications_dept on public.notifications(target_dept, is_read);
comment on table public.notifications is 'إشعارات فورية عبر Supabase Realtime';
