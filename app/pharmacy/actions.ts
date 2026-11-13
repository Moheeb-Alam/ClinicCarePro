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

export async function createProduct(formData: FormData) {
  const parsed = z.object({
    code: z.string().trim().min(2).max(40).regex(/^[A-Za-z0-9._-]+$/),
    name: z.string().trim().min(2).max(160), genericName: z.string().trim().max(160).optional(),
    strength: z.string().trim().max(80).optional(), dosageForm: z.string().trim().min(2).max(80),
    unit: z.string().trim().min(1).max(30), salePrice: z.coerce.number().min(0).max(1_000_000),
    reorderLevel: z.coerce.number().min(0).max(100_000_000),
  }).safeParse({
    code: formData.get("code"), name: formData.get("name"), genericName: formData.get("genericName") || undefined,
    strength: formData.get("strength") || undefined, dosageForm: formData.get("dosageForm"), unit: formData.get("unit"),
    salePrice: formData.get("salePrice"), reorderLevel: formData.get("reorderLevel"),
  });
  if (!parsed.success) redirect("/pharmacy?error=invalid#catalog");
  const { supabase, membership } = await getMembership();
  if (!["super_admin", "admin"].includes(membership.role)) redirect("/pharmacy?error=forbidden");
  const { error } = await supabase.from("pharmacy_products").insert({
    clinic_id: membership.clinic_id, code: parsed.data.code.toUpperCase(), name: parsed.data.name,
    generic_name: parsed.data.genericName ?? null, strength: parsed.data.strength ?? null,
    dosage_form: parsed.data.dosageForm, unit_label: parsed.data.unit,
    sale_price: parsed.data.salePrice, reorder_level: parsed.data.reorderLevel,
  });
  if (error) redirect(error.code === "23505" ? "/pharmacy?error=duplicate#catalog" : "/pharmacy?error=save#catalog");
  redirect("/pharmacy?product=1#catalog");
}

export async function receiveStock(formData: FormData) {
  const parsed = z.object({
    productId: z.uuid(), batch: z.string().trim().min(1).max(80), expiry: z.iso.date(),
    quantity: z.coerce.number().positive().max(10_000_000), unitCost: z.coerce.number().min(0).max(10_000_000),
  }).safeParse({
    productId: formData.get("productId"), batch: formData.get("batch"), expiry: formData.get("expiry"),
    quantity: formData.get("quantity"), unitCost: formData.get("unitCost"),
  });
  if (!parsed.success) redirect("/pharmacy?error=invalid#receive");
  const { supabase, membership } = await getMembership();
  if (!["super_admin", "admin", "pharmacist", "accountant"].includes(membership.role)) redirect("/pharmacy?error=forbidden");
  const { error } = await supabase.rpc("receive_pharmacy_stock", {
    target_clinic: membership.clinic_id, target_product: parsed.data.productId,
    target_batch: parsed.data.batch, target_expiry: parsed.data.expiry,
    target_quantity: parsed.data.quantity, target_unit_cost: parsed.data.unitCost,
  });
  if (error) redirect(error.code === "42501" ? "/pharmacy?error=forbidden" : "/pharmacy?error=stock");
  redirect("/pharmacy?received=1");
}

export async function dispensePrescriptionItem(formData: FormData) {
  const parsed = z.object({ itemId: z.uuid(), quantity: z.coerce.number().positive().max(100_000) }).safeParse({
    itemId: formData.get("itemId"), quantity: formData.get("quantity"),
  });
  if (!parsed.success) redirect("/pharmacy?error=invalid");
  const { supabase, membership } = await getMembership();
  if (!["super_admin", "admin", "pharmacist"].includes(membership.role)) redirect("/pharmacy?error=forbidden");
  const { error } = await supabase.rpc("dispense_prescription_item", {
    target_item: parsed.data.itemId, target_quantity: parsed.data.quantity,
    target_idempotency_key: randomUUID(),
  });
  if (error) redirect(error.code === "42501" ? "/pharmacy?error=forbidden" : "/pharmacy?error=dispense");
  redirect("/pharmacy?dispensed=1");
}
