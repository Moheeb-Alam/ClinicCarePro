"use server";

import { redirect } from "next/navigation";
import { z } from "zod";
import { createClient } from "@/lib/supabase/server";

async function getContext() {
  const supabase = await createClient();
  const { data: claims } = await supabase.auth.getClaims();
  const userId = String(claims?.claims?.sub ?? "");
  if (!userId) redirect("/login");
  const { data: membership } = await supabase.from("clinic_memberships").select("clinic_id, role")
    .eq("user_id", userId).eq("active", true).order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (!membership) redirect("/");
  return { supabase, userId, membership };
}

function encounterId(formData: FormData) {
  const parsed = z.uuid().safeParse(formData.get("encounterId"));
  if (!parsed.success) redirect("/encounters?error=invalid");
  return parsed.data;
}

export async function addEncounterNote(formData: FormData) {
  const id = encounterId(formData);
  const parsed = z.object({ kind: z.enum(["chief_complaint", "history", "examination", "assessment", "plan", "follow_up"]), content: z.string().trim().min(1).max(8000) }).safeParse({
    kind: formData.get("kind"), content: formData.get("content"),
  });
  if (!parsed.success) redirect(`/encounters?encounter=${id}&error=invalid`);
  const { supabase } = await getContext();
  const { error } = await supabase.rpc("add_encounter_note", { target_encounter: id, target_kind: parsed.data.kind, target_content: parsed.data.content });
  if (error) redirect(`/encounters?encounter=${id}&error=save`);
  redirect(`/encounters?encounter=${id}&saved=1`);
}

export async function addEncounterDiagnosis(formData: FormData) {
  const id = encounterId(formData);
  const parsed = z.object({ code: z.string().trim().max(32).optional(), description: z.string().trim().min(2).max(240), primary: z.enum(["true", "false"]) }).safeParse({
    code: formData.get("code") || undefined, description: formData.get("description"), primary: formData.get("primary"),
  });
  if (!parsed.success) redirect(`/encounters?encounter=${id}&error=invalid`);
  const { supabase } = await getContext();
  const { error } = await supabase.rpc("add_encounter_diagnosis", {
    target_encounter: id, target_code: parsed.data.code ?? null,
    target_description: parsed.data.description, primary_diagnosis: parsed.data.primary === "true",
  });
  if (error) redirect(`/encounters?encounter=${id}&error=save`);
  redirect(`/encounters?encounter=${id}&saved=1`);
}

const optionalNumber = z.preprocess((value) => value === "" || value === null ? undefined : Number(value), z.number().finite().optional());

export async function recordVitals(formData: FormData) {
  const id = encounterId(formData);
  const parsed = z.object({
    systolic: optionalNumber, diastolic: optionalNumber, temperature: optionalNumber,
    pulse: optionalNumber, weight: optionalNumber, height: optionalNumber,
  }).safeParse({ systolic: formData.get("systolic"), diastolic: formData.get("diastolic"), temperature: formData.get("temperature"), pulse: formData.get("pulse"), weight: formData.get("weight"), height: formData.get("height") });
  if (!parsed.success || Object.values(parsed.data).every((value) => value === undefined)) redirect(`/encounters?encounter=${id}&error=invalid`);
  const { supabase } = await getContext();
  const { error } = await supabase.rpc("record_encounter_vitals", {
    target_encounter: id, target_systolic: parsed.data.systolic ?? null,
    target_diastolic: parsed.data.diastolic ?? null, target_temperature: parsed.data.temperature ?? null,
    target_pulse: parsed.data.pulse ?? null, target_weight: parsed.data.weight ?? null,
    target_height: parsed.data.height ?? null,
  });
  if (error) redirect(`/encounters?encounter=${id}&error=vitals`);
  redirect(`/encounters?encounter=${id}&saved=1`);
}

export async function createEncounterPrescription(formData: FormData) {
  const id = encounterId(formData);
  const productIds = formData.getAll("productIds").map(String);
  if (!productIds.length || productIds.length > 30 || productIds.some((productId) => !z.uuid().safeParse(productId).success)
    || new Set(productIds).size !== productIds.length) redirect(`/encounters?encounter=${id}&error=prescription`);
  const items = [];
  for (const productId of productIds) {
    const parsed = z.object({ dose: z.string().trim().min(1).max(120), frequency: z.string().trim().min(1).max(120), days: z.coerce.number().int().min(1).max(365), quantity: z.coerce.number().positive().max(100000), instructions: z.string().trim().max(500).optional() }).safeParse({
      dose: formData.get(`dose_${productId}`), frequency: formData.get(`frequency_${productId}`),
      days: formData.get(`days_${productId}`), quantity: formData.get(`quantity_${productId}`),
      instructions: formData.get(`instructions_${productId}`) || undefined,
    });
    if (!parsed.success) redirect(`/encounters?encounter=${id}&error=prescription`);
    items.push({ product_id: productId, dose: parsed.data.dose, frequency: parsed.data.frequency,
      duration_days: parsed.data.days, quantity: parsed.data.quantity, instructions: parsed.data.instructions ?? null });
  }
  const { supabase } = await getContext();
  const { error } = await supabase.rpc("create_prescription", { target_encounter: id, target_items: items });
  if (error) redirect(`/encounters?encounter=${id}&error=prescription`);
  redirect(`/encounters?encounter=${id}&saved=1`);
}

export async function finalizeEncounter(formData: FormData) {
  const id = encounterId(formData);
  const { supabase } = await getContext();
  const { error } = await supabase.rpc("finalize_clinical_encounter", { target_encounter: id });
  if (error) redirect(`/encounters?encounter=${id}&error=finalize`);
  redirect(`/encounters?encounter=${id}&finalized=1`);
}
