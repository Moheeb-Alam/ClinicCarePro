"use server";

import { randomUUID } from "node:crypto";
import { redirect } from "next/navigation";
import { z } from "zod";
import { createClient } from "@/lib/supabase/server";

async function getMembership() {
  const supabase = await createClient();
  const { data: claims } = await supabase.auth.getClaims();
  const userId = String(claims?.claims?.sub ?? "");
  if (!userId) redirect("/login");
  const { data: membership } = await supabase.from("clinic_memberships")
    .select("clinic_id, role").eq("user_id", userId).eq("active", true).order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (!membership) redirect("/");
  return { supabase, membership };
}

export async function createService(formData: FormData) {
  const parsed = z.object({
    code: z.string().trim().min(2).max(40).regex(/^[A-Za-z0-9._-]+$/),
    name: z.string().trim().min(2).max(160),
    kind: z.enum(["consultation", "laboratory", "imaging", "pharmacy", "service", "other"]),
    price: z.coerce.number().min(0).max(100_000_000),
  }).safeParse({ code: formData.get("code"), name: formData.get("name"), kind: formData.get("kind"), price: formData.get("price") });
  if (!parsed.success) redirect("/billing?error=invalid#catalog");
  const { supabase, membership } = await getMembership();
  if (!["super_admin", "admin"].includes(membership.role)) redirect("/billing?error=forbidden");
  const { error } = await supabase.from("service_catalog").insert({
    clinic_id: membership.clinic_id, code: parsed.data.code.toUpperCase(),
    name: parsed.data.name, kind: parsed.data.kind, unit_price: parsed.data.price,
  });
  if (error) redirect(error.code === "23505" ? "/billing?error=duplicate#catalog" : "/billing?error=save#catalog");
  redirect("/billing?service=1#catalog");
}

export async function createBill(formData: FormData) {
  const serviceIds = formData.getAll("serviceIds").map(String);
  const quantities = serviceIds.map((id) => Number(formData.get(`quantity_${id}`)));
  const parsed = z.object({ patientId: z.uuid(), notes: z.string().trim().max(500).optional() }).safeParse({
    patientId: formData.get("patientId"), notes: formData.get("notes") || undefined,
  });
  if (!parsed.success || serviceIds.length < 1 || serviceIds.length > 50
    || serviceIds.some((id) => !z.uuid().safeParse(id).success) || quantities.some((quantity) => !Number.isFinite(quantity) || quantity <= 0 || quantity > 100000)) {
    redirect("/billing?error=invalid#create");
  }
  const { supabase, membership } = await getMembership();
  if (!["super_admin", "admin", "receptionist", "accountant"].includes(membership.role)) redirect("/billing?error=forbidden");
  const { data: billId, error } = await supabase.rpc("create_bill", {
    target_clinic: membership.clinic_id,
    target_patient: parsed.data.patientId,
    target_service_ids: serviceIds,
    target_quantities: quantities,
    target_notes: parsed.data.notes ?? null,
  });
  if (error || !billId) redirect(error?.code === "42501" ? "/billing?error=forbidden" : "/billing?error=create");
  redirect(`/billing?created=${encodeURIComponent(billId)}`);
}

export async function issueBill(formData: FormData) {
  const billId = z.uuid().safeParse(formData.get("billId"));
  if (!billId.success) redirect("/billing?error=invalid");
  const { supabase, membership } = await getMembership();
  if (!["super_admin", "admin", "accountant"].includes(membership.role)) redirect("/billing?error=forbidden");
  const { error } = await supabase.rpc("issue_bill", { target_bill: billId.data });
  if (error) redirect(error.code === "42501" ? "/billing?error=forbidden" : "/billing?error=issue");
  redirect("/billing?issued=1");
}

export async function recordPayment(formData: FormData) {
  const parsed = z.object({
    billId: z.uuid(), amount: z.coerce.number().positive().max(100_000_000),
    method: z.enum(["cash", "card", "bank_transfer", "online"]),
    reference: z.string().trim().max(120).optional(),
  }).safeParse({ billId: formData.get("billId"), amount: formData.get("amount"), method: formData.get("method"), reference: formData.get("reference") || undefined });
  if (!parsed.success) redirect("/billing?error=invalid");
  const { supabase, membership } = await getMembership();
  if (!["super_admin", "admin", "receptionist", "accountant"].includes(membership.role)) redirect("/billing?error=forbidden");
  const { error } = await supabase.rpc("record_payment", {
    target_bill: parsed.data.billId, target_amount: parsed.data.amount,
    target_method: parsed.data.method, target_idempotency_key: randomUUID(),
    target_reference: parsed.data.reference ?? null,
  });
  if (error) redirect(error.code === "42501" ? "/billing?error=forbidden" : "/billing?error=payment");
  redirect("/billing?paid=1");
}

export async function reversePayment(formData: FormData) {
  const parsed = z.object({ paymentId: z.uuid(), reason: z.string().trim().min(5).max(500) }).safeParse({
    paymentId: formData.get("paymentId"), reason: formData.get("reason"),
  });
  if (!parsed.success) redirect("/billing?error=invalid");
  const { supabase, membership } = await getMembership();
  if (!["super_admin", "admin", "accountant"].includes(membership.role)) redirect("/billing?error=forbidden");
  const { error } = await supabase.rpc("reverse_payment", {
    target_payment: parsed.data.paymentId, target_reason: parsed.data.reason,
    target_idempotency_key: randomUUID(),
  });
  if (error) redirect(error.code === "42501" ? "/billing?error=forbidden" : "/billing?error=reversal");
  redirect("/billing?reversed=1");
}

export async function recordExpense(formData: FormData) {
  const parsed = z.object({
    category: z.string().trim().min(2).max(100), description: z.string().trim().min(2).max(500),
    amount: z.coerce.number().positive().max(100_000_000), spentAt: z.iso.date(),
  }).safeParse({ category: formData.get("category"), description: formData.get("description"), amount: formData.get("amount"), spentAt: formData.get("spentAt") });
  if (!parsed.success) redirect("/billing?error=invalid#expenses");
  const { supabase, membership } = await getMembership();
  if (!["super_admin", "admin", "accountant"].includes(membership.role)) redirect("/billing?error=forbidden#expenses");
  const { data: claims } = await supabase.auth.getClaims();
  const userId = String(claims?.claims?.sub ?? "");
  const { error } = await supabase.from("expenses").insert({
    clinic_id: membership.clinic_id, category: parsed.data.category, description: parsed.data.description,
    amount: parsed.data.amount, spent_at: parsed.data.spentAt, recorded_by: userId,
  });
  if (error) redirect("/billing?error=expense#expenses");
  redirect("/billing?expense=1#expenses");
}
