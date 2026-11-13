import Link from "next/link";
import { signIn } from "@/app/actions/auth";

type LoginPageProps = { searchParams: Promise<{ error?: string; updated?: string }> };

export const instant = false;

export default async function LoginPage({ searchParams }: LoginPageProps) {
  const { error, updated } = await searchParams;
  const message = error === "invalid"
    ? "Enter a valid email and password of at least 8 characters."
    : error === "connection"
      ? "ClinicCare could not connect to Supabase. Check your internet connection and Supabase project settings, then try again."
    : error === "credentials"
      ? "We couldn’t sign you in with those details."
      : error === "callback" || error === "recovery"
        ? "That reset link is invalid or has expired. Request a new link."
        : null;
  return (
    <main className="login-screen">
      <section className="login-card">
        <Link className="brand login-brand" href="/"><span className="brand-mark">✚</span><span className="brand-copy"><strong>cliniccare<span>pro</span></strong><small>CARE, CONNECTED.</small></span></Link>
        <div className="login-intro"><p className="setup-eyebrow">WELCOME BACK</p><h1>Sign in to your clinic</h1><p>Use your authorized clinic account to continue.</p></div>
        {updated && <p className="patient-alert success" role="status">Your password has been updated. Sign in with your new password.</p>}
        {message && <p className="login-error" role="alert">{message}</p>}
        <form action={signIn} className="login-form">
          <label htmlFor="email">Work email</label><input autoComplete="username" id="email" name="email" type="email" placeholder="you@clinic.com" required maxLength={254} />
          <label htmlFor="password">Password</label><input autoComplete="current-password" id="password" name="password" type="password" placeholder="Enter your password" required minLength={8} maxLength={128} />
          <button className="primary-button" type="submit">Sign in <span>→</span></button>
        </form>
        <Link className="forgot-password" href="/reset-password">Forgot your password?</Link>
        <p className="login-foot">Access is managed by your clinic administrator.</p>
      </section>
    </main>
  );
}
