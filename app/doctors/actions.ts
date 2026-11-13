"use server";

import { redirect } from "next/navigation";
import { z } from "zod";
import { createClient } from "@/lib/supabase/server";

const doctorSchema = z.object({
  fullName: z.string().trim().min(2).max(160),
  specialization: z.string().trim().min(2).max(120),
  qualification: z.string().trim().max(240).optional(),
  experienceYears: z.coerce.number().int().min(0).max(80),
  consultationFee: z.coerce.number().min(0).max(1_000_000),
});

async function getAdminMembership() {
  const supabase = await createClient();
  const { data: claimsData } = await supabase.auth.getClaims();
  const userId = String(claimsData?.claims?.sub ?? "");
  if (!userId) redirect("/login");
  const { data: membership } = await supabase.from("clinic_memberships")
    .select("clinic_id, role").eq("user_id", userId).eq("active", true).order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (!membership) redirect("/");
  if (!["super_admin", "admin"].includes(membership.role)) redirect("/doctors?error=forbidden");
  return { supabase, userId, membership };
}

export async function createDoctor(formData: FormData) {
  const parsed = doctorSchema.safeParse({
    fullName: formData.get("fullName"),
    specialization: formData.get("specialization"),
    qualification: formData.get("qualification") || undefined,
    experienceYears: formData.get("experienceYears"),
    consultationFee: formData.get("consultationFee"),
  });
  if (!parsed.success) redirect("/doctors?error=invalid");
  const { supabase, membership } = await getAdminMembership();
  const input = parsed.data;
  const { error } = await supabase.from("doctors").insert({
    clinic_id: membership.clinic_id,
    full_name: input.fullName,
    specialization: input.specialization,
    qualification: input.qualification || null,
    experience_years: input.experienceYears,
    consultation_fee: input.consultationFee,
  });
  if (error) redirect("/doctors?error=save");
  redirect("/doctors?created=1");
}

export async function setDoctorActive(formData: FormData) {
  const parsed = z.object({ id: z.uuid(), active: z.enum(["true", "false"]) }).safeParse({
    id: formData.get("id"), active: formData.get("active"),
  });
  if (!parsed.success) redirect("/doctors?error=invalid");
  const { supabase, membership } = await getAdminMembership();
  const { error } = await supabase.from("doctors").update({ active: parsed.data.active === "true" })
    .eq("clinic_id", membership.clinic_id).eq("id", parsed.data.id);
  if (error) redirect("/doctors?error=save");
  redirect("/doctors?updated=1");
}
