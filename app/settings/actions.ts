"use server";

import { redirect } from "next/navigation";
import { z } from "zod";
import { createClient } from "@/lib/supabase/server";

async function adminClinic() {
  const supabase = await createClient();
  const { data: claims } = await supabase.auth.getClaims();
  const userId = String(claims?.claims?.sub ?? "");
  if (!userId) redirect("/login");
  const { data: membership } = await supabase.from("clinic_memberships").select("clinic_id, role")
    .eq("user_id", userId).eq("active", true).order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (!membership || !["super_admin", "admin"].includes(membership.role)) redirect("/settings?error=forbidden");
  return { supabase, membership };
}

export async function saveClinicSettings(formData: FormData) {
  const parsed = z.object({ name: z.string().trim().min(2).max(180), slug: z.string().trim().regex(/^[a-z0-9]+(-[a-z0-9]+)*$/).max(180), timezone: z.string().trim().min(1).max(80), phone: z.string().trim().max(32).optional(), email: z.union([z.email(), z.literal("")]).optional(), address: z.string().trim().max(500).optional() }).safeParse({
    name: formData.get("name"), slug: formData.get("slug"), timezone: formData.get("timezone"),
    phone: formData.get("phone") || undefined, email: formData.get("email") || "", address: formData.get("address") || undefined,
  });
  if (!parsed.success) redirect("/settings?error=invalid#clinic");
  const { supabase, membership } = await adminClinic();
  const { error } = await supabase.rpc("update_clinic_settings", {
    target_clinic: membership.clinic_id, target_name: parsed.data.name, target_slug: parsed.data.slug,
    target_timezone: parsed.data.timezone, target_phone: parsed.data.phone ?? null,
    target_email: parsed.data.email || null, target_address: parsed.data.address ?? null,
  });
  if (error) redirect(error.code === "23505" ? "/settings?error=slug#clinic" : "/settings?error=save#clinic");
  redirect("/settings?saved=1#clinic");
}

export async function createDepartment(formData: FormData) {
  const name = z.string().trim().min(2).max(100).safeParse(formData.get("name"));
  if (!name.success) redirect("/settings?error=invalid#departments");
  const { supabase, membership } = await adminClinic();
  const { error } = await supabase.from("departments").insert({ clinic_id: membership.clinic_id, name: name.data });
  if (error) redirect(error.code === "23505" ? "/settings?error=department#departments" : "/settings?error=save#departments");
  redirect("/settings?department=1#departments");
}

export async function updateDepartment(formData: FormData) {
  const parsed = z.object({ id: z.uuid(), active: z.enum(["true", "false"]) }).safeParse({ id: formData.get("id"), active: formData.get("active") });
  if (!parsed.success) redirect("/settings?error=invalid#departments");
  const { supabase, membership } = await adminClinic();
  const { error } = await supabase.from("departments").update({ active: parsed.data.active === "true" })
    .eq("clinic_id", membership.clinic_id).eq("id", parsed.data.id);
  if (error) redirect("/settings?error=save#departments");
  redirect("/settings?department=1#departments");
}
