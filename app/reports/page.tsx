import Link from "next/link";
import { redirect } from "next/navigation";
import { ChartNoAxesCombined, Download, FileText, FlaskConical, Receipt, ScanLine, Users } from "lucide-react";
import { signOut } from "@/app/actions/auth";
import { createClient } from "@/lib/supabase/server";

export const instant = false;
type ReportsPageProps = { searchParams: Promise<Record<string, string | undefined>> };
type Summary = { appointments: number; patients_registered: number; lab_orders: number; imaging_orders: number; billed_amount: number; collected_amount: number; outstanding_amount: number; expenses_amount: number };
type DailyReportRow = { report_date: string; billed_amount: number | string; collected_amount: number | string; expense_amount: number | string };

function dateInTimezone(date: Date) {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Karachi", year: "numeric", month: "2-digit", day: "2-digit" }).format(date);
}

function addDays(value: string, days: number) {
  const [year, month, day] = value.split("-").map(Number);
  const date = new Date(Date.UTC(year, month - 1, day + days));
  return `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, "0")}-${String(date.getUTCDate()).padStart(2, "0")}`;
}

function isDate(value: string | undefined): value is string {
  if (!value || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const date = new Date(`${value}T00:00:00.000Z`);
  return !Number.isNaN(date.getTime()) && date.toISOString().slice(0, 10) === value;
}

function money(value: number | string | undefined) {
  return new Intl.NumberFormat("en-PK", { style: "currency", currency: "PKR", maximumFractionDigits: 2 }).format(Number(value ?? 0));
}

export default async function ReportsPage({ searchParams }: ReportsPageProps) {
  const params = await searchParams;
  const supabase = await createClient();
  const { data: claimsData, error: claimsError } = await supabase.auth.getClaims();
  if (!claimsData?.claims || claimsError) redirect("/login");
  const { data: membership, error: membershipError } = await supabase.from("clinic_memberships").select("clinic_id, role")
    .eq("user_id", String(claimsData.claims.sub ?? "")).eq("active", true).order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (membershipError || !membership || !["super_admin", "admin", "accountant", "auditor"].includes(membership.role)) redirect("/");

  const today = dateInTimezone(new Date());
  const end = isDate(params.end) ? params.end : today;
  const start = isDate(params.start) ? params.start : addDays(end, -6);
  const endExclusive = addDays(end, 1);
  const validRange = start <= end && Date.parse(`${endExclusive}T00:00:00Z`) - Date.parse(`${start}T00:00:00Z`) <= 366 * 86400000;
  const [clinicResult, summaryResult, dailyResult] = await Promise.all([
    supabase.from("clinics").select("name").eq("id", membership.clinic_id).maybeSingle(),
    validRange ? supabase.rpc("clinic_report_summary", { target_clinic: membership.clinic_id, target_start: start, target_end: endExclusive }) : Promise.resolve({ data: null, error: { message: "Invalid date range" } }),
    validRange ? supabase.rpc("clinic_daily_financial_report", { target_clinic: membership.clinic_id, target_start: start, target_end: endExclusive }) : Promise.resolve({ data: [], error: { message: "Invalid date range" } }),
  ]);
  const summary = summaryResult.data as Summary | null;
  const dailyRows = (dailyResult.data ?? []) as DailyReportRow[];
  const reportError = summaryResult.error || dailyResult.error;
  const metrics = [
    { label: "Appointments", value: summary?.appointments, icon: Users },
    { label: "New patients", value: summary?.patients_registered, icon: Users },
    { label: "Lab orders", value: summary?.lab_orders, icon: FlaskConical },
    { label: "Imaging orders", value: summary?.imaging_orders, icon: ScanLine },
    { label: "Billed", value: money(summary?.billed_amount), icon: Receipt },
    { label: "Collected", value: money(summary?.collected_amount), icon: Receipt },
    { label: "Outstanding", value: money(summary?.outstanding_amount), icon: FileText },
    { label: "Expenses", value: money(summary?.expenses_amount), icon: Receipt },
  ];

  return (
    <main className="patients-page reports-page">
      <header className="patients-topbar"><Link className="patients-brand" href="/">✚ <b>cliniccare<span>pro</span></b></Link><nav><Link href="/">Overview</Link><span>/</span><strong>Reports</strong></nav><div className="patients-user"><Link href="/">{String(claimsData.claims.email ?? "Clinic account")}</Link><form action={signOut}><button>Sign out</button></form></div></header>
      <div className="patients-content">
        <div className="patients-title-row"><div><p className="patients-eyebrow">ANALYTICS / REPORTS</p><h1>Clinic reports</h1><p>{clinicResult.data?.name ?? "Your clinic"} · Aggregated operational and finance totals</p></div><span className="appointment-count"><ChartNoAxesCombined size={15} /> {start} – {end}</span></div>
        <section className="patient-form-card"><form method="get" action="/reports" className="patient-form report-filter"><label>From<input name="start" type="date" defaultValue={start} required /></label><label>To<input name="end" type="date" defaultValue={end} required /></label><div className="patient-form-actions"><span>Maximum report window: 366 days. No patient names are included.</span><button type="submit">Run report</button></div></form></section>
        {!validRange && <div className="patient-alert error" role="alert">Choose a valid date range of no more than 366 days.</div>}
        {validRange && reportError && <div className="patient-alert error" role="alert">Report data is unavailable. Confirm migration 010 is installed and your role can access reporting.</div>}
        <div className="report-metric-grid">{metrics.map(({ label, value, icon: Icon }) => <article className="report-metric" key={label}><span><Icon size={16} /></span><small>{label}</small><b>{value ?? "—"}</b></article>)}</div>
        <section className="patients-table-card"><div className="patients-table-heading"><div><h2>Daily billing summary</h2><p>Issued invoice totals and net payments by clinic-local date</p></div><a className="table-action report-download" href={`/reports/export?start=${start}&end=${end}`}><Download size={13} /> Download CSV</a></div>
          {dailyRows.length ? <div className="patients-table-scroll"><table className="patients-table"><thead><tr><th>Date</th><th>Billed (PKR)</th><th>Collected (PKR)</th><th>Expenses (PKR)</th><th>Net cash (PKR)</th></tr></thead><tbody>{dailyRows.map((row) => <tr key={row.report_date}><td>{row.report_date}</td><td>{money(row.billed_amount)}</td><td>{money(row.collected_amount)}</td><td>{money(row.expense_amount)}</td><td>{money(Number(row.collected_amount) - Number(row.expense_amount))}</td></tr>)}</tbody></table></div> : <div className="patients-empty"><span><ChartNoAxesCombined size={18} /></span><b>No billing activity in this period</b><p>Issued bills and payment events will appear here.</p></div>}
        </section>
        <p className="patients-pagination">Reports use clinic-local dates and aggregated totals. They are operational summaries, not audited financial statements.</p>
      </div>
    </main>
  );
}
