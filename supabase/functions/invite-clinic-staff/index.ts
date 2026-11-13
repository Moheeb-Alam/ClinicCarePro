import { createClient } from "jsr:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const authorization = request.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return json({ error: "unauthorized" }, 401);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceRoleKey) return json({ error: "server_configuration" }, 500);

  let body: { email?: unknown; full_name?: unknown; phone?: unknown; clinic_id?: unknown; role?: unknown };
  try { body = await request.json(); } catch { return json({ error: "invalid_json" }, 400); }
  const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
  const fullName = typeof body.full_name === "string" ? body.full_name.trim() : "";
  const phone = typeof body.phone === "string" ? body.phone.trim() : "";
  const clinicId = typeof body.clinic_id === "string" ? body.clinic_id : "";
  const targetRole = typeof body.role === "string" ? body.role : "";
  const roles = ["super_admin", "admin", "receptionist", "doctor", "lab_technician", "radiology_technician", "radiologist", "pharmacist", "accountant", "auditor"];
  if (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)
    || fullName.length < 2 || fullName.length > 160 || phone.length > 32
    || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(clinicId)
    || !roles.includes(targetRole)) {
    return json({ error: "invalid_fields" }, 400);
  }

  const userClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: authorization } }, auth: { persistSession: false, autoRefreshToken: false } });
  const { data: actorResult, error: actorError } = await userClient.auth.getUser();
  if (actorError || !actorResult.user) return json({ error: "unauthorized" }, 401);
  const serviceClient = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: actorMembership } = await serviceClient.from("clinic_memberships").select("role")
    .eq("clinic_id", clinicId).eq("user_id", actorResult.user.id).eq("active", true).maybeSingle();
  const { data: actorProfile } = await serviceClient.from("profiles").select("active").eq("id", actorResult.user.id).maybeSingle();
  const { data: clinic } = await serviceClient.from("clinics").select("active").eq("id", clinicId).maybeSingle();
  if (!actorMembership || !["super_admin", "admin"].includes(actorMembership.role)
    || !actorProfile?.active || !clinic?.active
    || (actorMembership.role === "admin" && ["super_admin", "admin"].includes(targetRole))) {
    return json({ error: "forbidden" }, 403);
  }
  const { data: invitation, error: inviteError } = await serviceClient.auth.admin.inviteUserByEmail(email, {
    data: { full_name: fullName },
  });
  if (inviteError || !invitation.user) {
    const alreadyExists = inviteError?.message.toLowerCase().includes("already") ?? false;
    return json({ error: alreadyExists ? "user_exists" : "invite_failed" }, alreadyExists ? 409 : 502);
  }

  const { error: profileError } = await serviceClient.from("profiles").upsert({
    id: invitation.user.id, full_name: fullName, phone: phone || null, active: true,
  }, { onConflict: "id" });
  if (profileError) return json({ error: "profile_provision_failed", user_id: invitation.user.id }, 500);
  return json({ user_id: invitation.user.id, invited: true });
});
