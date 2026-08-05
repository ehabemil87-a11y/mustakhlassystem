-- =====================================================================
--  03 — سياسات الحماية على مستوى الصفوف (Row Level Security)
--  ينفذ بعد 02_functions_triggers.sql
--
--  القاعدة العامة:
--    - موظف الإدارة (department): يرى ويعدّل مستخلصات إدارته فقط
--    - موظف الحسابات (accounts): يرى كل المستخلصات ويعدّل حالتها
--    - الأدمن (admin): وصول كامل
-- =====================================================================

-- تفعيل RLS على كل الجداول
alter table public.departments      enable row level security;
alter table public.profiles         enable row level security;
alter table public.projects         enable row level security;
alter table public.extracts         enable row level security;
alter table public.attachments      enable row level security;
alter table public.invoices         enable row level security;
alter table public.extract_history  enable row level security;
alter table public.notifications    enable row level security;

-- ---------------------------------------------------------------------
--  departments — الجميع يقرأ، الأدمن فقط يعدّل
-- ---------------------------------------------------------------------
create policy dept_read on public.departments
  for select using (auth.uid() is not null);
create policy dept_admin_write on public.departments
  for all using (current_role_of() = 'admin') with check (current_role_of() = 'admin');

-- ---------------------------------------------------------------------
--  profiles — كل مستخدم يقرأ ملفه، الأدمن يقرأ/يعدّل الكل
-- ---------------------------------------------------------------------
create policy prof_read_self on public.profiles
  for select using (id = auth.uid() or current_role_of() in ('accounts','admin'));
create policy prof_admin_all on public.profiles
  for all using (current_role_of() = 'admin') with check (current_role_of() = 'admin');

-- ---------------------------------------------------------------------
--  projects — الإدارة تقرأ مشاريعها، الحسابات/الأدمن يقرأون الكل
-- ---------------------------------------------------------------------
create policy proj_read on public.projects
  for select using (
    department_id = current_dept_of()
    or current_role_of() in ('accounts','admin')
  );
create policy proj_manage on public.projects
  for all using (current_role_of() = 'admin' or department_id = current_dept_of())
  with check (current_role_of() = 'admin' or department_id = current_dept_of());

-- ---------------------------------------------------------------------
--  extracts — أهم جدول
-- ---------------------------------------------------------------------
-- القراءة: الإدارة ترى مستخلصاتها، الحسابات/الأدمن يرون الكل
create policy ext_read on public.extracts
  for select using (
    department_id = current_dept_of()
    or current_role_of() in ('accounts','admin')
  );

-- الإنشاء: موظف الإدارة ينشئ لإدارته فقط
create policy ext_insert on public.extracts
  for insert with check (
    current_role_of() = 'department'
    and department_id = current_dept_of()
    and submitted_by = auth.uid()
  );

-- التعديل من الإدارة: فقط عند الإرجاع (returned) لإعادة الإرسال إلى pending_review
--  USING يفحص الصف القديم (مرتجع)، WITH CHECK يفحص الصف الجديد (قيد المراجعة)
create policy ext_update_dept on public.extracts
  for update using (
    current_role_of() = 'department'
    and department_id = current_dept_of()
    and status = 'returned'
  ) with check (
    current_role_of() = 'department'
    and department_id = current_dept_of()
    and status = 'pending_review'
  );

-- التعديل من الحسابات/الأدمن: تغيير الحالة والمراجعة والإرجاع
create policy ext_update_accounts on public.extracts
  for update using (current_role_of() in ('accounts','admin'));

-- ---------------------------------------------------------------------
--  attachments — تتبع صلاحية المستخلص المرتبط
-- ---------------------------------------------------------------------
create policy att_read on public.attachments
  for select using (
    exists (
      select 1 from public.extracts e
      where e.id = extract_id
        and (e.department_id = current_dept_of() or current_role_of() in ('accounts','admin'))
    )
  );
create policy att_insert on public.attachments
  for insert with check (
    exists (
      select 1 from public.extracts e
      where e.id = extract_id
        and (e.department_id = current_dept_of() or current_role_of() in ('accounts','admin'))
    )
  );

-- ---------------------------------------------------------------------
--  invoices — الحسابات/الأدمن ينشئون، الجميع (المصرح) يقرأ
-- ---------------------------------------------------------------------
create policy inv_read on public.invoices
  for select using (
    exists (
      select 1 from public.extracts e
      where e.id = extract_id
        and (e.department_id = current_dept_of() or current_role_of() in ('accounts','admin'))
    )
  );
create policy inv_write on public.invoices
  for all using (current_role_of() in ('accounts','admin'))
  with check (current_role_of() in ('accounts','admin'));

-- ---------------------------------------------------------------------
--  extract_history — قراءة فقط لمن يرى المستخلص، الكتابة عبر المشغّلات
-- ---------------------------------------------------------------------
create policy hist_read on public.extract_history
  for select using (
    exists (
      select 1 from public.extracts e
      where e.id = extract_id
        and (e.department_id = current_dept_of() or current_role_of() in ('accounts','admin'))
    )
  );

-- ---------------------------------------------------------------------
--  notifications — كل مستخدم يرى إشعاراته الموجهة له أو لدوره أو لإدارته
-- ---------------------------------------------------------------------
create policy notif_read on public.notifications
  for select using (
    user_id = auth.uid()
    or target_role = current_role_of()
    or target_dept = current_dept_of()
  );
create policy notif_update on public.notifications
  for update using (
    user_id = auth.uid()
    or target_role = current_role_of()
    or target_dept = current_dept_of()
  );
