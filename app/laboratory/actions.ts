"use server";

import { randomUUID } from "node:crypto";
import { redirect } from "next/navigation";
import { z } from "zod";
import { createClient } from "@/lib/supabase/server";

const resultFieldSchema = z.object({
  key: z.string().regex(/^[a-z][a-z0-9_]{0,39}$/),
  label: z.string().trim().min(1).max(80),
  type: z.enum(["number", "text", "boolean"]),
  unit: z.string().trim().max(30).optional(),
  referenceMin: z.number().optional(),
  referenceMax: z.number().optional(),
  criticalMin: z.number().optional(),
  criticalMax: z.number().optional(),
}).refine((field) => field.referenceMin === undefined || field.referenceMax === undefined || field.referenceMin <= field.referenceMax)
  .refine((field) => field.criticalMin === undefined || field.criticalMax === undefined || field.criticalMin <= field.criticalMax);

async function getClinicMembership() {
  const supabase = await createClient();
  const { data: claimsData } = await supabase.auth.getClaims();
  const userId = String(claimsData?.claims?.sub ?? "");
  if (!userId) redirect("/login");
  const { data: membership } = await supabase.from("clinic_memberships")
    .select("clinic_id, role").eq("user_id", userId).eq("active", true).order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (!membership) redirect("/");
  return { supabase, userId, membership };
}

export async function createLabCategory(formData: FormData) {
  const parsed = z.string().trim().min(2).max(100).safeParse(formData.get("name"));
  if (!parsed.success) redirect("/laboratory?error=invalid");
  const { supabase, membership } = await getClinicMembership();
  if (!["super_admin", "admin"].includes(membership.role)) redirect("/laboratory?error=forbidden");
  const { error } = await supabase.from("lab_categories").insert({ clinic_id: membership.clinic_id, name: parsed.data });
  if (error) redirect(error.code === "23505" ? "/laboratory?error=duplicate" : "/laboratory?error=save");
  redirect("/laboratory?category=1#catalog");
}

export async function createLabTest(formData: FormData) {
  const schemaText = String(formData.get("resultSchema") ?? "[]");
  let resultSchema: unknown;
  try { resultSchema = JSON.parse(schemaText); } catch { redirect("/laboratory?error=schema"); }
  const fields = z.array(resultFieldSchema).min(1).max(30).safeParse(resultSchema);
  const parsed = z.object({
    categoryId: z.uuid(),
    code: z.string().trim().min(2).max(40).regex(/^[A-Za-z0-9._-]+$/),
    name: z.string().trim().min(2).max(160),
    description: z.string().trim().max(500).optional(),
    price: z.coerce.number().min(0).max(1_000_000),
    turnaround: z.coerce.number().int().min(1).max(43200).optional(),
  }).safeParse({
    categoryId: formData.get("categoryId"), code: formData.get("code"), name: formData.get("name"),
    description: formData.get("description") || undefined, price: formData.get("price"),
    turnaround: formData.get("turnaround") || undefined,
  });
  if (!parsed.success || !fields.success || new Set(fields.data.map((field) => field.key)).size !== fields.data.length) {
    redirect("/laboratory?error=schema");
  }
  const { supabase, membership } = await getClinicMembership();
  if (!["super_admin", "admin"].includes(membership.role)) redirect("/laboratory?error=forbidden");
  const { error } = await supabase.from("lab_tests").insert({
    clinic_id: membership.clinic_id,
    category_id: parsed.data.categoryId,
    code: parsed.data.code.toUpperCase(),
    name: parsed.data.name,
    description: parsed.data.description || null,
    price: parsed.data.price,
    turnaround_minutes: parsed.data.turnaround ?? null,
    result_schema: fields.data,
  });
  if (error) redirect(error.code === "23505" ? "/laboratory?error=duplicate" : "/laboratory?error=save");
  redirect("/laboratory?test=1#catalog");
}

export async function createLabOrder(formData: FormData) {
  const parsed = z.object({
    patientId: z.uuid(),
    doctorId: z.uuid(),
    testIds: z.array(z.uuid()).min(1).max(20),
    priority: z.enum(["routine", "urgent", "stat"]),
    notes: z.string().trim().max(500).optional(),
  }).safeParse({
    patientId: formData.get("patientId"), doctorId: formData.get("doctorId"),
    testIds: formData.getAll("testIds"), priority: formData.get("priority"),
    notes: formData.get("notes") || undefined,
  });
  if (!parsed.success || new Set(parsed.data.testIds).size !== parsed.data.testIds.length) redirect("/laboratory?error=invalid");
  const { supabase, membership } = await getClinicMembership();
  if (!["super_admin", "admin", "receptionist", "doctor"].includes(membership.role)) redirect("/laboratory?error=forbidden");
  const { error } = await supabase.rpc("create_lab_order", {
    target_clinic: membership.clinic_id,
    target_patient: parsed.data.patientId,
    target_doctor: parsed.data.doctorId,
    target_test_ids: parsed.data.testIds,
    target_priority: parsed.data.priority,
    target_notes: parsed.data.notes ?? null,
  });
  if (error) redirect(error.code === "42501" ? "/laboratory?error=forbidden" : "/laboratory?error=order");
  redirect("/laboratory?ordered=1");
}

export async function collectLabSample(formData: FormData) {
  const parsed = z.object({ itemId: z.uuid(), sampleType: z.string().trim().max(80).optional() }).safeParse({
    itemId: formData.get("itemId"), sampleType: formData.get("sampleType") || undefined,
  });
  if (!parsed.success) redirect("/laboratory?error=invalid");
  const { supabase } = await getClinicMembership();
  const dateParts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Karachi", year: "numeric", month: "2-digit", day: "2-digit",
  }).formatToParts(new Date());
  const dateValues = Object.fromEntries(dateParts.map((part) => [part.type, part.value]));
  const date = `${dateValues.year}${dateValues.month}${dateValues.day}`;
  const sampleNumber = `S-${date}-${randomUUID().slice(0, 8).toUpperCase()}`;
  const { error } = await supabase.rpc("collect_lab_sample", {
    target_item: parsed.data.itemId, target_sample_number: sampleNumber,
    target_sample_type: parsed.data.sampleType ?? null,
  });
  if (error) redirect(error.code === "42501" ? "/laboratory?error=forbidden" : "/laboratory?error=sample");
  redirect("/laboratory?sample=1");
}

export async function rejectLabSample(formData: FormData) {
  const parsed = z.object({ sampleId: z.uuid(), reason: z.string().trim().min(5).max(500) }).safeParse({
    sampleId: formData.get("sampleId"), reason: formData.get("reason"),
  });
  if (!parsed.success) redirect("/laboratory?error=invalid");
  const { supabase } = await getClinicMembership();
  const { error } = await supabase.rpc("reject_lab_sample", {
    target_sample: parsed.data.sampleId, rejection_note: parsed.data.reason,
  });
  if (error) redirect(error.code === "42501" ? "/laboratory?error=forbidden" : "/laboratory?error=sample");
  redirect("/laboratory?rejected=1");
}

export async function startLabProcessing(formData: FormData) {
  const itemId = z.uuid().safeParse(formData.get("itemId"));
  if (!itemId.success) redirect("/laboratory?error=invalid");
  const { supabase } = await getClinicMembership();
  const { error } = await supabase.rpc("transition_lab_item_status", { target_item: itemId.data, target_status: "processing" });
  if (error) redirect(error.code === "42501" ? "/laboratory?error=forbidden" : "/laboratory?error=transition");
  redirect("/laboratory?processing=1");
}

export async function recordLabResult(formData: FormData) {
  const itemId = z.uuid().safeParse(formData.get("itemId"));
  if (!itemId.success) redirect("/laboratory?error=invalid");
  const { supabase, membership } = await getClinicMembership();
  const { data: item } = await supabase.from("lab_order_items").select("id, test_id")
    .eq("clinic_id", membership.clinic_id).eq("id", itemId.data).maybeSingle();
  if (!item) redirect("/laboratory?error=result");
  const { data: test } = await supabase.from("lab_tests").select("result_schema")
    .eq("clinic_id", membership.clinic_id).eq("id", item.test_id).maybeSingle();
  const fields = z.array(resultFieldSchema).safeParse(test?.result_schema);
  if (!fields.success || !fields.data.length) redirect("/laboratory?error=schema");
  const values: Record<string, unknown> = {};
  for (const field of fields.data) {
    const raw = formData.get(field.key);
    if (typeof raw !== "string" || raw.length === 0) redirect("/laboratory?error=result");
    if (field.type === "number") {
      const numeric = Number(raw);
      if (!Number.isFinite(numeric)) redirect("/laboratory?error=result");
      values[field.key] = numeric;
    } else if (field.type === "boolean") {
      if (raw !== "true" && raw !== "false") redirect("/laboratory?error=result");
      values[field.key] = raw === "true";
    } else {
      values[field.key] = raw.trim().slice(0, 4000);
    }
  }
  const { error } = await supabase.rpc("record_lab_result", { target_item: itemId.data, target_values: values });
  if (error) redirect(error.code === "42501" ? "/laboratory?error=forbidden" : "/laboratory?error=result");
  redirect("/laboratory?result=1");
}

export async function verifyLabResult(formData: FormData) {
  const parsed = z.object({ resultId: z.uuid(), level: z.enum(["technician_verified", "doctor_verified"]), notes: z.string().trim().max(500).optional() }).safeParse({
    resultId: formData.get("resultId"), level: formData.get("level"), notes: formData.get("notes") || undefined,
  });
  if (!parsed.success) redirect("/laboratory?error=invalid");
  const { supabase } = await getClinicMembership();
  const { error } = await supabase.rpc("verify_lab_result", {
    target_result: parsed.data.resultId, target_level: parsed.data.level, target_notes: parsed.data.notes ?? null,
  });
  if (error) redirect(error.code === "42501" ? "/laboratory?error=forbidden" : "/laboratory?error=verification");
  redirect("/laboratory?verified=1");
}

export async function deliverLabOrderItem(formData: FormData) {
  const itemId = z.uuid().safeParse(formData.get("itemId"));
  if (!itemId.success) redirect("/laboratory?error=invalid");
  const { supabase } = await getClinicMembership();
  const { error } = await supabase.rpc("transition_lab_item_status", { target_item: itemId.data, target_status: "delivered" });
  if (error) redirect(error.code === "42501" ? "/laboratory?error=forbidden" : "/laboratory?error=transition");
  redirect("/laboratory?delivered=1");
}
