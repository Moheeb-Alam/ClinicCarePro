import Link from "next/link";
import { redirect } from "next/navigation";
import { History, Search } from "lucide-react";
import { signOut } from "@/app/actions/auth";
import { createClient } from "@/lib/supabase/server";

export const instant = false;
type AuditPageProps = { searchParams: Promise<Record<string, string | undefined>> };

export default async function AuditPage({ searchParams }: AuditPageProps) {
  const params = await searchParams;
  const moduleFilter = (params.module ?? "").trim().slice(0, 80);
  const supabase = await createClient();
  const { data: claimsData, error: claimsError } = await supabase.auth.getClaims();
  if (!claimsData?.claims || claimsError) redirect("/login");
  const { data: membership, error: membershipError } = await supabase.from("clinic_memberships").select("clinic_id, role")
    .eq("user_id", String(claimsData.claims.sub ?? "")).eq("active", true).order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (membershipError || !membership || !["super_admin", "admin", "auditor"].includes(membership.role)) redirect("/");
  let query = supabase.from("audit_logs").select("id, actor_id, actor_role, action, module, record_id, reason, occurred_at", { count: "exact" })
    .eq("clinic_id", membership.clinic_id).order("occurred_at", { ascending: false }).limit(100);
  if (moduleFilter) query = query.ilike("module", `%${moduleFilter.replace(/[,%_]/g, " ")}%`);
  const { data, error, count } = await query;

  return (
    <main className="patients-page audit-page">
      <header className="patients-topbar"><Link className="patients-brand" href="/">✚ <b>cliniccare<span>pro</span></b></Link><nav><Link href="/">Overview</Link><span>/</span><strong>Audit log</strong></nav><div className="patients-user"><Link href="/">{String(claimsData.claims.email ?? "Clinic account")}</Link><form action={signOut}><button>Sign out</button></form></div></header>
      <div className="patients-content">
        <div className="patients-title-row"><div><p className="patients-eyebrow">ADMINISTRATION / AUDIT</p><h1>Audit log</h1><p>Append-only clinic event history · sensitive before/after values are not shown here</p></div><span className="appointment-count"><History size={15} /> {count ?? 0} events</span></div>
        <section className="patients-table-card"><div className="patients-table-heading"><div><h2>Recent events</h2><p>Showing the latest 100 matches</p></div><form className="patient-search" action="/audit" method="get"><Search size={15} /><input name="module" defaultValue={moduleFilter} placeholder="Filter by table or module" aria-label="Filter audit log by module" /><button type="submit">Filter</button></form></div>
          {error ? <div className="patients-empty"><b>Unable to load audit events</b><p>Check database setup and your administrator/auditor access.</p></div> : data?.length ? <div className="patients-table-scroll"><table className="patients-table audit-table"><thead><tr><th>Time</th><th>Module</th><th>Action</th><th>Actor</th><th>Role</th><th>Record ID</th><th>Reason</th></tr></thead><tbody>{data.map((row) => <tr key={row.id}><td>{new Intl.DateTimeFormat("en-PK", { dateStyle: "medium", timeStyle: "short", timeZone: "Asia/Karachi" }).format(new Date(row.occurred_at))}</td><td>{row.module}</td><td><span className="status-pill">{row.action}</span></td><td>{row.actor_id ? `${row.actor_id.slice(0, 8)}…` : "System"}</td><td>{row.actor_role?.replaceAll("_", " ") ?? "System"}</td><td>{row.record_id ?? "—"}</td><td>{row.reason ?? "—"}</td></tr>)}</tbody></table></div> : <div className="patients-empty"><span><History size={18} /></span><b>No audit events found</b><p>Clinic records and workflow changes will be logged here.</p></div>}
        </section>
      </div>
    </main>
  );
}
