// =====================================================================
//  Edge Function: create-user
//  تنشئ مستخدماً جديداً بواسطة الأدمن — يحدد اسم مستخدم وكلمة مرور فقط
//  تحوّل اسم المستخدم داخلياً إلى بريد وهمي ثابت للدومين، فلا يرى الموظف
//  أي بريد إلكتروني — يدخل باسم المستخدم فقط.
//
//  النشر:  supabase functions deploy create-user
//  المتغيرات المطلوبة (Project Settings > Edge Functions > Secrets):
//    SUPABASE_URL
//    SUPABASE_SERVICE_ROLE_KEY   (سري — لا يظهر أبداً في كود الواجهة)
//    INTERNAL_EMAIL_DOMAIN       مثال: mustakhlas.internal
// =====================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
    const SERVICE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const DOMAIN       = Deno.env.get("INTERNAL_EMAIL_DOMAIN") ?? "mustakhlas.internal";

    // عميل بصلاحية الخدمة (سري)
    const admin = createClient(SUPABASE_URL, SERVICE_KEY, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    // 1) التحقق من أن الطالب أدمن فعلاً
    const authHeader = req.headers.get("Authorization") ?? "";
    const jwt = authHeader.replace("Bearer ", "");
    const { data: caller, error: callerErr } = await admin.auth.getUser(jwt);
    if (callerErr || !caller?.user) {
      return json({ error: "غير مصرح" }, 401);
    }
    const { data: callerProfile } = await admin
      .from("profiles").select("role").eq("id", caller.user.id).single();
    if (callerProfile?.role !== "admin") {
      return json({ error: "هذه العملية للأدمن فقط" }, 403);
    }

    // 2) قراءة البيانات المرسلة
    const { name, username, password, role, department_id, job_title } = await req.json();
    if (!name || !username || !password || !role) {
      return json({ error: "بيانات ناقصة" }, 400);
    }
    const needsDept = role === "department" || role === "dept_manager";

    // اسم المستخدم -> بريد داخلي ثابت
    const email = `${String(username).toLowerCase().trim()}@${DOMAIN}`;

    // 3) إنشاء مستخدم Auth (مؤكد تلقائياً)
    const { data: created, error: createErr } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { name, username },
    });
    if (createErr) {
      return json({ error: createErr.message }, 400);
    }

    // 4) إنشاء صف الملف الشخصي (Profile)
    const { error: profErr } = await admin.from("profiles").insert({
      id: created.user!.id,
      name,
      username: String(username).toLowerCase().trim(),
      role,
      department_id: needsDept ? department_id : null,
      job_title: job_title ?? null,
    });
    if (profErr) {
      // تراجع: حذف مستخدم Auth لو فشل إنشاء الملف
      await admin.auth.admin.deleteUser(created.user!.id);
      return json({ error: profErr.message }, 400);
    }

    return json({ ok: true, id: created.user!.id, username }, 200);
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
