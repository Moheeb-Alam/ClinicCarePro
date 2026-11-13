"use server";

import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { z } from "zod";

const credentialsSchema = z.object({
  email: z.email().max(254),
  password: z.string().min(8).max(128),
});

export async function signIn(formData: FormData) {
  const credentials = credentialsSchema.safeParse({
    email: String(formData.get("email") ?? "").trim().toLowerCase(),
    password: String(formData.get("password") ?? ""),
  });
  if (!credentials.success) {
    redirect("/login?error=invalid");
  }
  const supabase = await createClient();
  const { error } = await supabase.auth.signInWithPassword(credentials.data);
  if (error) {
    if (error.name === "AuthRetryableFetchError" || error.status === 0) {
      redirect("/login?error=connection");
    }
    redirect("/login?error=credentials");
  }
  redirect("/");
}

export async function signOut() {
  const supabase = await createClient();
  await supabase.auth.signOut();
  redirect("/login");
}

export async function requestPasswordReset(formData: FormData) {
  const email = z.email().max(254).safeParse(String(formData.get("email") ?? "").trim().toLowerCase());
  if (!email.success) redirect("/reset-password?error=invalid");
  const supabase = await createClient();
  const siteUrl = process.env.NEXT_PUBLIC_SITE_URL ?? "http://localhost:3000";
  await supabase.auth.resetPasswordForEmail(email.data, {
    redirectTo: `${siteUrl}/auth/callback?next=/reset-password/update`,
  });
  // Keep the response identical for existing and unknown accounts.
  redirect("/reset-password?sent=1");
}

export async function updatePassword(formData: FormData) {
  const password = String(formData.get("password") ?? "");
  const confirmPassword = String(formData.get("confirmPassword") ?? "");
  const parsed = z.string().min(12).max(128).safeParse(password);
  if (!parsed.success || password !== confirmPassword) redirect("/reset-password/update?error=invalid");
  const supabase = await createClient();
  const { data } = await supabase.auth.getClaims();
  if (!data?.claims) redirect("/login?error=recovery");
  const { error } = await supabase.auth.updateUser({ password: parsed.data });
  if (error) redirect("/reset-password/update?error=save");
  redirect("/login?updated=1");
}
