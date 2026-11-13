"use server";

import { redirect } from "next/navigation";
import { z } from "zod";
import { createClient } from "@/lib/supabase/server";

export async function markNotificationRead(formData: FormData) {
  const id = z.uuid().safeParse(formData.get("notificationId"));
  if (!id.success) redirect("/notifications?error=invalid");
  const supabase = await createClient();
  const { data: claims } = await supabase.auth.getClaims();
  if (!claims?.claims?.sub) redirect("/login");
  const { error } = await supabase.rpc("mark_notification_read", { target_notification: id.data });
  if (error) redirect("/notifications?error=save");
  redirect("/notifications?read=1");
}

export async function markAllNotificationsRead() {
  const supabase = await createClient();
  const { data: claims } = await supabase.auth.getClaims();
  const userId = String(claims?.claims?.sub ?? "");
  if (!userId) redirect("/login");
  const { error } = await supabase.rpc("mark_all_notifications_read");
  if (error) redirect("/notifications?error=save");
  redirect("/notifications?read=1");
}
