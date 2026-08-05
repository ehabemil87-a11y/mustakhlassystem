-- =====================================================================
--  12 — إصلاح إعادة إرسال المستخلص المرتجع
--  ينفذ بعد 11
--
--  المشكلة: سياسة ext_update_dept كانت تحوي USING فقط (status='returned')،
--  وبغياب WITH CHECK يستخدم PostgreSQL شرط USING نفسه للصف الجديد،
--  فيشترط بقاء الحالة 'returned' ويرفض الانتقال إلى 'pending_review'
--  عند إعادة الإرسال → خطأ: new row violates row-level security policy.
--
--  الحل: WITH CHECK صريح يسمح للإدارة بضبط الحالة إلى 'pending_review'.
-- =====================================================================

drop policy if exists ext_update_dept on public.extracts;
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
