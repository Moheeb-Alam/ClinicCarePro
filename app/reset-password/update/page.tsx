import Link from "next/link";
import { updatePassword } from "@/app/actions/auth";

export const instant = false;

type UpdatePasswordPageProps = { searchParams: Promise<{ error?: string }> };

export default async function UpdatePasswordPage({ searchParams }: UpdatePasswordPageProps) {
  const { error } = await searchParams;
  return (
    <main className="login-screen"><section className="login-card">
      <Link className="brand login-brand" href="/"><span className="brand-mark">✚</span><span className="brand-copy"><strong>cliniccare<span>pro</span></strong><small>CARE, CONNECTED.</small></span></Link>
      <div className="login-intro"><p className="setup-eyebrow">SECURE YOUR ACCOUNT</p><h1>Choose a new password</h1><p>Use at least 12 characters for your new password.</p></div>
      {error === "invalid" && <p className="login-error" role="alert">Passwords must match and contain at least 12 characters.</p>}
      {error === "save" && <p className="login-error" role="alert">The password could not be updated. Request a new reset link.</p>}
      <form action={updatePassword} className="login-form"><label htmlFor="password">New password</label><input autoComplete="new-password" id="password" name="password" type="password" minLength={12} maxLength={128} required /><label htmlFor="confirmPassword">Confirm password</label><input autoComplete="new-password" id="confirmPassword" name="confirmPassword" type="password" minLength={12} maxLength={128} required /><button className="primary-button" type="submit">Update password <span>→</span></button></form>
    </section></main>
  );
}
