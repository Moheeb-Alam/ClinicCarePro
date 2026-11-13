"use server";

import { redirect } from "next/navigation";
import { z } from "zod";
import { createClient } from "@/lib/supabase/server";

async function getMembership() {
  const supabase = await createClient();
  const { data: claims } = await supabase.auth.getClaims();
  const userId = String(claims?.claims?.sub ?? "");
  if (!userId) redirect("/login");
  const { data: membership } = await supabase.from("clinic_memberships").select("clinic_id, role")
    .eq("user_id", userId).eq("active", true).order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (!membership) redirect("/");
  return { supabase, membership };
}

export async function createImagingService(formData: FormData) {
  const parsed = z.object({ modality: z.enum(["xray", "ct", "mri"]), code: z.string().trim().min(2).max(40).regex(/^[A-Za-z0-9._-]+$/), name: z.string().trim().min(2).max(160), bodyRegion: z.string().trim().max(120).optional(), price: z.coerce.number().min(0).max(1_000_000) }).safeParse({
    modality: formData.get("modality"), code: formData.get("code"), name: formData.get("name"), bodyRegion: formData.get("bodyRegion") || undefined, price: formData.get("price"),
  });
  if (!parsed.success) redirect("/imaging?error=invalid#catalog");
  const { supabase, membership } = await getMembership();
  if (!["super_admin", "admin"].includes(membership.role)) redirect("/imaging?error=forbidden");
  const { error } = await supabase.from("imaging_services").insert({ clinic_id: membership.clinic_id, modality: parsed.data.modality, code: parsed.data.code.toUpperCase(), name: parsed.data.name, body_region: parsed.data.bodyRegion ?? null, price: parsed.data.price });
  if (error) redirect(error.code === "23505" ? "/imaging?error=duplicate#catalog" : "/imaging?error=save#catalog");
  redirect("/imaging?service=1#catalog");
}

export async function createImagingOrder(formData: FormData) {
  const parsed = z.object({ patientId: z.uuid(), doctorId: z.uuid(), serviceId: z.uuid(), priority: z.enum(["routine", "urgent", "stat"]), question: z.string().trim().max(1000).optional() }).safeParse({
    patientId: formData.get("patientId"), doctorId: formData.get("doctorId"), serviceId: formData.get("serviceId"), priority: formData.get("priority"), question: formData.get("question") || undefined,
  });
  if (!parsed.success) redirect("/imaging?error=invalid#create");
  const { supabase, membership } = await getMembership();
  if (!["super_admin", "admin", "receptionist", "doctor"].includes(membership.role)) redirect("/imaging?error=forbidden");
  const { error } = await supabase.rpc("create_imaging_order", {
    target_clinic: membership.clinic_id, target_patient: parsed.data.patientId,
    target_doctor: parsed.data.doctorId, target_service: parsed.data.serviceId,
    target_priority: parsed.data.priority, target_question: parsed.data.question ?? null,
  });
  if (error) redirect(error.code === "42501" ? "/imaging?error=forbidden" : "/imaging?error=order");
  redirect("/imaging?ordered=1");
}

export async function updateImagingStatus(formData: FormData) {
  const parsed = z.object({ orderId: z.uuid(), status: z.enum(["scheduled", "delivered"]) }).safeParse({ orderId: formData.get("orderId"), status: formData.get("status") });
  if (!parsed.success) redirect("/imaging?error=invalid");
  const { supabase, membership } = await getMembership();
  const permitted = parsed.data.status === "scheduled"
    ? ["super_admin", "radiology_technician"].includes(membership.role)
    : ["super_admin", "admin", "receptionist"].includes(membership.role);
  if (!permitted) redirect("/imaging?error=forbidden");
  const { error } = await supabase.from("imaging_orders").update({ status: parsed.data.status })
    .eq("clinic_id", membership.clinic_id).eq("id", parsed.data.orderId);
  if (error) redirect("/imaging?error=transition");
  redirect("/imaging?updated=1");
}

export async function beginImagingStudy(formData: FormData) {
  const id = z.uuid().safeParse(formData.get("orderId"));
  if (!id.success) redirect("/imaging?error=invalid");
  const { supabase, membership } = await getMembership();
  if (!["super_admin", "radiology_technician"].includes(membership.role)) redirect("/imaging?error=forbidden");
  const { error } = await supabase.rpc("begin_imaging_study", { target_order: id.data });
  if (error) redirect(error.code === "42501" ? "/imaging?error=forbidden" : "/imaging?error=study");
  redirect("/imaging?study=1");
}

export async function signRadiologyReport(formData: FormData) {
  const parsed = z.object({ studyId: z.uuid(), findings: z.string().trim().min(1).max(20000), impression: z.string().trim().min(1).max(5000), previousReportId: z.string().optional(), correctionReason: z.string().trim().max(500).optional() }).safeParse({
    studyId: formData.get("studyId"), findings: formData.get("findings"), impression: formData.get("impression"), previousReportId: formData.get("previousReportId") || undefined, correctionReason: formData.get("correctionReason") || undefined,
  });
  if (!parsed.success || (parsed.data.previousReportId && !z.uuid().safeParse(parsed.data.previousReportId).success)) redirect("/imaging?error=invalid");
  const { supabase, membership } = await getMembership();
  if (!["super_admin", "radiologist"].includes(membership.role)) redirect("/imaging?error=forbidden");
  const { error } = await supabase.rpc("create_radiology_report", {
    target_study: parsed.data.studyId, target_findings: parsed.data.findings,
    target_impression: parsed.data.impression, target_supersedes: parsed.data.previousReportId ?? null,
    target_correction_reason: parsed.data.correctionReason ?? null,
  });
  if (error) redirect(error.code === "42501" ? "/imaging?error=forbidden" : "/imaging?error=report");
  redirect("/imaging?reported=1");
}
