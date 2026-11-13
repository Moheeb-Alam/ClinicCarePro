"use server";

import { redirect } from "next/navigation";
import { z } from "zod";
import { createClient } from "@/lib/supabase/server";

const patientSchema = z.object({
  fullName: z.string().trim().min(2).max(160),
  fatherName: z.string().trim().max(160).optional(),
  gender: z.enum(["female", "male", "other", "unknown"]),
  dateOfBirth: z.iso.date().optional(),
  phone: z.string().trim().max(32).refine((value) => /^\+?[0-9\s().-]+$/.test(value) && value.replace(/\D/g, "").length >= 7 && value.replace(/\D/g, "").length <= 15).optional(),
  email: z.union([z.email().max(254), z.literal("")]).optional(),
  address: z.string().trim().max(500).optional(),
  bloodGroup: z.enum(["", "A+", "A-", "B+", "B-", "AB+", "AB-", "O+", "O-"]).optional(),
  emergencyContactName: z.string().trim().max(160).optional(),
  emergencyContactPhone: z.string().trim().max(32).refine((value) => /^\+?[0-9\s().-]+$/.test(value) && value.replace(/\D/g, "").length >= 7 && value.replace(/\D/g, "").length <= 15).optional(),
});

export async function registerPatient(formData: FormData) {
  const parsed = patientSchema.safeParse({
    fullName: formData.get("fullName"),
    fatherName: formData.get("fatherName") || undefined,
    gender: formData.get("gender"),
    dateOfBirth: formData.get("dateOfBirth") || undefined,
    phone: formData.get("phone") || undefined,
    email: formData.get("email") || undefined,
    address: formData.get("address") || undefined,
    bloodGroup: formData.get("bloodGroup") || "",
    emergencyContactName: formData.get("emergencyContactName") || undefined,
    emergencyContactPhone: formData.get("emergencyContactPhone") || undefined,
  });
  if (!parsed.success) redirect("/patients?error=invalid");

  const supabase = await createClient();
  const { data: claimsData } = await supabase.auth.getClaims();
  const userId = claimsData?.claims?.sub;
  if (!userId) redirect("/login");

  const { data: membership, error: membershipError } = await supabase
    .from("clinic_memberships")
    .select("clinic_id, role")
    .eq("user_id", userId)
    .eq("active", true)
    .limit(1)
    .maybeSingle();
  if (membershipError || !membership) redirect("/?notice=clinic-access");
  if (!["super_admin", "admin", "receptionist"].includes(membership.role)) {
    redirect("/patients?error=forbidden");
  }

  const input = parsed.data;
  const phone = input.phone?.replace(/[\s().-]/g, "") || null;
  const emergencyPhone = input.emergencyContactPhone?.replace(/[\s().-]/g, "") || null;
  const { error } = await supabase.rpc("register_patient", {
    target_clinic: membership.clinic_id,
    target_full_name: input.fullName,
    target_gender: input.gender,
    target_father_name: input.fatherName || null,
    target_date_of_birth: input.dateOfBirth || null,
    target_phone: phone,
    target_email: input.email || null,
    target_address: input.address || null,
    target_blood_group: input.bloodGroup || null,
    target_emergency_contact_name: input.emergencyContactName || null,
    target_emergency_contact_phone: emergencyPhone,
  });

  if (error) {
    if (error.code === "23505") redirect("/patients?error=duplicate");
    if (error.code === "42501") redirect("/patients?error=forbidden");
    redirect("/patients?error=save");
  }
  redirect("/patients?created=1");
}
