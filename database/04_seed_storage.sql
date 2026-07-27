-- =====================================================================
--  04 — البيانات الأولية وإعداد التخزين (Seed & Storage)
--  ينفذ بعد 03_rls_policies.sql
-- =====================================================================

-- ---------------------------------------------------------------------
--  إدراج الإدارات الأربعة
-- ---------------------------------------------------------------------
insert into public.departments (name, code) values
  ('التشغيل والصيانة', 'OPS'),
  ('النقليات',         'TRN'),
  ('الطرق',            'RDS'),
  ('تأجير المعدات',    'EQP')
on conflict (code) do nothing;

-- ---------------------------------------------------------------------
--  إعداد bucket خاص لمرفقات المستخلصات والفواتير
--  (يمكن إنشاؤه أيضاً من واجهة Supabase Storage — الاسم: extract-files)
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('extract-files', 'extract-files', false)
on conflict (id) do nothing;

-- سياسات الوصول للتخزين: كل مستخدم مصرّح له يرفع/يقرأ ملفات المستخلصات
-- (التحقق التفصيلي من ملكية المستخلص يتم على مستوى الجداول؛ هنا نضمن أن
--  المستخدم مسجّل الدخول فقط، والروابط تُنشأ كـ Signed URLs قصيرة العمر)

create policy "extract_files_read"
  on storage.objects for select
  using ( bucket_id = 'extract-files' and auth.uid() is not null );

create policy "extract_files_insert"
  on storage.objects for insert
  with check ( bucket_id = 'extract-files' and auth.uid() is not null );

create policy "extract_files_delete"
  on storage.objects for delete
  using (
    bucket_id = 'extract-files'
    and public.current_role_of() in ('accounts','admin')
  );

-- ---------------------------------------------------------------------
--  ملاحظة حول أول مستخدم أدمن:
--  ينشأ أول مستخدم من لوحة Supabase Auth يدوياً، ثم:
--
--    insert into public.profiles (id, name, username, role, department_id)
--    values ('<UUID-من-auth.users>', 'المدير', 'admin', 'admin', null);
--
--  بعدها يمكن إنشاء بقية المستخدمين من شاشة إدارة المستخدمين داخل النظام.
-- ---------------------------------------------------------------------
