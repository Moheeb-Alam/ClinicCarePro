"use server";

import { redirect } from "next/navigation";
import { z } from "zod";
import { createClient } from "@/lib/supabase/server";

export async function saveStaffMembership(formData: FormData) {
  const parsed = z.object({ userId: z.uuid(), role: z.enum(["super_admin", "admin", "receptionist", "doctor", "lab_technician", "radiology_technician", "radiologist", "pharmacist", "accountant", "auditor"]), active: z.enum(["true", "false"]) }).safeParse({
    userId: formData.get("userId"), role: formData.get("role"), active: formData.get("active"),
  });
  if (!parsed.success) redirect("/staff?error=invalid");
  const supabase = await createClient();
  const { data: claims } = await supabase.auth.getClaims();
  const userId = String(claims?.claims?.sub ?? "");
  if (!userId) redirect("/login");
  const { data: membership } = await supabase.from("clinic_memberships").select("clinic_id, role")
    .eq("user_id", userId).eq("active", true).order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (!membership || !["super_admin", "admin"].includes(membership.role)) redirect("/staff?error=forbidden");
  const { error } = await supabase.rpc("manage_clinic_membership", {
    target_clinic: membership.clinic_id, target_user: parsed.data.userId,
    target_role: parsed.data.role, target_active: parsed.data.active === "true",
  });
  if (error) redirect(error.code === "42501" ? "/staff?error=forbidden" : "/staff?error=save");
  redirect("/staff?saved=1");
}

export async function inviteStaffMember(formData: FormData) {
  const parsed = z.object({
    fullName: z.string().trim().min(2).max(160), email: z.email().max(254),
    phone: z.string().trim().max(32).optional(),
    role: z.enum(["super_admin", "admin", "receptionist", "doctor", "lab_technician", "radiology_technician", "radiologist", "pharmacist", "accountant", "auditor"]),
  }).safeParse({ fullName: formData.get("fullName"), email: formData.get("email"), phone: formData.get("phone") || undefined, role: formData.get("role") });
  if (!parsed.success) redirect("/staff?error=invalid#invite");
  const supabase = await createClient();
  const { data: claims } = await supabase.auth.getClaims();
  const userId = String(claims?.claims?.sub ?? "");
  if (!userId) redirect("/login");
  const { data: membership } = await supabase.from("clinic_memberships").select("clinic_id, role")
    .eq("user_id", userId).eq("active", true).order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (!membership || !["super_admin", "admin"].includes(membership.role)
    || (membership.role === "admin" && ["super_admin", "admin"].includes(parsed.data.role))) redirect("/staff?error=forbidden#invite");
  const { data: invitation, error: inviteError } = await supabase.functions.invoke("invite-clinic-staff", {
    body: { clinic_id: membership.clinic_id, role: parsed.data.role, email: parsed.data.email, full_name: parsed.data.fullName, phone: parsed.data.phone ?? "" },
  });
  if (inviteError || !invitation?.user_id) {
    let failureCode = String(invitation?.error ?? "");
    const responseContext = (inviteError as { context?: unknown } | null)?.context;
    if (!failureCode && responseContext instanceof Response) {
      try { failureCode = String((await responseContext.clone().json()).error ?? ""); } catch { /* use generic failure below */ }
    }
    const message = (failureCode || inviteError?.message || "").toLowerCase();
    if (message.includes("user_exists") || message.includes("already")) redirect("/staff?error=exists#invite");
    redirect(message.includes("forbidden") ? "/staff?error=forbidden#invite" : "/staff?error=invite#invite");
  }
  const { error: membershipError } = await supabase.rpc("manage_clinic_membership", {
    target_clinic: membership.clinic_id, target_user: invitation.user_id,
    target_role: parsed.data.role, target_active: true,
  });
  if (membershipError) redirect("/staff?error=assignment#invite");
  redirect("/staff?invited=1");
}
