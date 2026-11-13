import Link from "next/link";
import { requestPasswordReset } from "@/app/actions/auth";

export const instant = false;

type ResetPageProps = { searchParams: Promise<{ sent?: string; error?: string }> };

export default async function ResetPasswordPage({ searchParams }: ResetPageProps) {
  const { sent, error } = await searchParams;
  return (
    <main className="login-screen"><section className="login-card">
      <Link className="brand login-brand" href="/login"><span className="brand-mark">✚</span><span className="brand-copy"><strong>cliniccare<span>pro</span></strong><small>CARE, CONNECTED.</small></span></Link>
      <div className="login-intro"><p className="setup-eyebrow">ACCOUNT ACCESS</p><h1>Reset your password</h1><p>Enter your work email. If an account exists, we’ll send reset instructions.</p></div>
      {sent && <p className="patient-alert success" role="status">If the account exists, reset instructions have been sent.</p>}
      {error === "invalid" && <p className="login-error" role="alert">Enter a valid work email address.</p>}
      <form action={requestPasswordReset} className="login-form"><label htmlFor="email">Work email</label><input autoComplete="email" id="email" name="email" type="email" required maxLength={254} /><button className="primary-button" type="submit">Send reset link <span>→</span></button></form>
      <Link className="forgot-password" href="/login">Back to sign in</Link>
    </section></main>
  );
}
