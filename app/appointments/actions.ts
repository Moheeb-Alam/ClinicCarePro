"use server";

import { redirect } from "next/navigation";
import { z } from "zod";
import { createClient } from "@/lib/supabase/server";
import { parseLocalDateTime } from "@/lib/dates";

const appointmentSchema = z.object({
  patientId: z.uuid(),
  doctorId: z.uuid(),
  startsAt: z.string().regex(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/),
  duration: z.coerce.number().int().min(10).max(90),
  reason: z.string().trim().max(240).optional(),
});

export async function createAppointment(formData: FormData) {
  const parsed = appointmentSchema.safeParse({
    patientId: formData.get("patientId"),
    doctorId: formData.get("doctorId"),
    startsAt: formData.get("startsAt"),
    duration: formData.get("duration"),
    reason: formData.get("reason") || undefined,
  });
  if (!parsed.success) redirect("/appointments?error=invalid");

  const supabase = await createClient();
  const { data: claimsData } = await supabase.auth.getClaims();
  const userId = String(claimsData?.claims?.sub ?? "");
  if (!userId) redirect("/login");

  const { data: membership } = await supabase.from("clinic_memberships")
    .select("clinic_id, role").eq("user_id", userId).eq("active", true).order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (!membership) redirect("/?notice=clinic-access");
  if (!["super_admin", "admin", "receptionist"].includes(membership.role)) {
    redirect("/appointments?error=forbidden");
  }

  const { data: clinic } = await supabase.from("clinics")
    .select("timezone").eq("id", membership.clinic_id).maybeSingle();
  const startsAt = parseLocalDateTime(parsed.data.startsAt, clinic?.timezone ?? "Asia/Karachi");
  if (!startsAt || startsAt <= new Date() || startsAt.getTime() > Date.now() + 365 * 24 * 60 * 60 * 1000) {
    redirect("/appointments?error=date");
  }

  const [patient, doctor] = await Promise.all([
    supabase.from("patients").select("id").eq("clinic_id", membership.clinic_id)
      .eq("id", parsed.data.patientId).is("archived_at", null).maybeSingle(),
    supabase.from("doctors").select("id").eq("clinic_id", membership.clinic_id)
      .eq("id", parsed.data.doctorId).eq("active", true).maybeSingle(),
  ]);
  if (!patient.data || !doctor.data) redirect("/appointments?error=selection");

  const endsAt = new Date(startsAt.getTime() + parsed.data.duration * 60_000);
  const { error } = await supabase.rpc("book_appointment", {
    target_clinic: membership.clinic_id,
    target_patient: parsed.data.patientId,
    target_doctor: parsed.data.doctorId,
    target_starts_at: startsAt.toISOString(),
    target_ends_at: endsAt.toISOString(),
    target_reason: parsed.data.reason || null,
  });
  if (error) {
    if (error.code === "23P01") redirect("/appointments?error=conflict");
    redirect("/appointments?error=save");
  }
  redirect("/appointments?created=1");
}

const statusSchema = z.object({
  appointmentId: z.uuid(),
  status: z.enum(["confirmed", "checked_in", "in_consultation", "completed", "cancelled", "no_show"]),
});

export async function updateAppointmentStatus(formData: FormData) {
  const parsed = statusSchema.safeParse({
    appointmentId: formData.get("appointmentId"),
    status: formData.get("status"),
  });
  if (!parsed.success) redirect("/appointments?error=invalid");

  const supabase = await createClient();
  const { data: claimsData } = await supabase.auth.getClaims();
  const userId = String(claimsData?.claims?.sub ?? "");
  if (!userId) redirect("/login");
  const { data: membership } = await supabase.from("clinic_memberships")
    .select("clinic_id, role").eq("user_id", userId).eq("active", true).order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (!membership) redirect("/?notice=clinic-access");

  const { data: appointment } = await supabase.from("appointments")
    .select("id, status, doctor_id").eq("clinic_id", membership.clinic_id)
    .eq("id", parsed.data.appointmentId).maybeSingle();
  if (!appointment) redirect("/appointments?error=missing");

  const frontDesk = ["super_admin", "admin", "receptionist"].includes(membership.role);
  const doctorCanUpdate = membership.role === "doctor" && ["in_consultation", "completed"].includes(parsed.data.status);
  if (!frontDesk && !doctorCanUpdate) redirect("/appointments?error=forbidden");

  const transitions: Record<string, string[]> = {
    scheduled: ["confirmed", "cancelled", "no_show"],
    confirmed: ["checked_in", "cancelled", "no_show"],
    checked_in: ["in_consultation", "cancelled", "no_show"],
    in_consultation: ["completed"],
  };
  if (!transitions[appointment.status]?.includes(parsed.data.status)) {
    redirect("/appointments?error=transition");
  }

  if (doctorCanUpdate) {
    const { data: assignedDoctor } = await supabase.from("doctors").select("id")
      .eq("clinic_id", membership.clinic_id).eq("profile_id", userId)
      .eq("id", appointment.doctor_id).maybeSingle();
    if (!assignedDoctor) redirect("/appointments?error=forbidden");
  }

  if (parsed.data.status === "in_consultation") {
    const { data: encounterId, error } = await supabase.rpc("start_clinical_encounter", { target_appointment: appointment.id });
    if (error || !encounterId) redirect("/appointments?error=transition");
    redirect(`/encounters?encounter=${encodeURIComponent(encounterId)}`);
  }

  const { data: changed, error } = await supabase.from("appointments").update({ status: parsed.data.status })
    .eq("clinic_id", membership.clinic_id).eq("id", appointment.id).eq("status", appointment.status)
    .select("id").maybeSingle();
  if (error || !changed) redirect("/appointments?error=transition");
  redirect("/appointments?updated=1");
}
