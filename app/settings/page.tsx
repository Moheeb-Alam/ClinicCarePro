import Link from "next/link";
import { redirect } from "next/navigation";
import { Building2, Settings2 } from "lucide-react";
import { signOut } from "@/app/actions/auth";
import { createClient } from "@/lib/supabase/server";
import { createDepartment, saveClinicSettings, updateDepartment } from "./actions";

export const instant = false;
type SettingsPageProps = { searchParams: Promise<Record<string, string | undefined>> };

export default async function SettingsPage({ searchParams }: SettingsPageProps) {
  const params = await searchParams;
  const supabase = await createClient();
  const { data: claimsData, error: claimsError } = await supabase.auth.getClaims();
  if (!claimsData?.claims || claimsError) redirect("/login");
  const { data: membership, error: membershipError } = await supabase.from("clinic_memberships").select("clinic_id, role")
    .eq("user_id", String(claimsData.claims.sub ?? "")).eq("active", true).order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (membershipError || !membership || !["super_admin", "admin"].includes(membership.role)) redirect("/");
  const [clinicResult, departmentResult] = await Promise.all([
    supabase.from("clinics").select("name, slug, timezone, phone, email, address").eq("id", membership.clinic_id).maybeSingle(),
    supabase.from("departments").select("id, name, active").eq("clinic_id", membership.clinic_id).order("name"),
  ]);
  const errors: Record<string, string> = {
    forbidden: "Your role cannot change clinic settings.", invalid: "Check the fields and try again.",
    slug: "That clinic URL is already in use.", save: "The setting could not be saved.", department: "That department name already exists.",
  };

  return (
    <main className="patients-page settings-page">
      <header className="patients-topbar"><Link className="patients-brand" href="/">✚ <b>cliniccare<span>pro</span></b></Link><nav><Link href="/">Overview</Link><span>/</span><strong>Settings</strong></nav><div className="patients-user"><Link href="/">{String(claimsData.claims.email ?? "Clinic account")}</Link><form action={signOut}><button>Sign out</button></form></div></header>
      <div className="patients-content">
        <div className="patients-title-row"><div><p className="patients-eyebrow">ADMINISTRATION / CONFIGURATION</p><h1>Clinic settings</h1><p>Manage clinic identity, time zone, and department lists</p></div><span className="appointment-count"><Settings2 size={15} /> Administrator</span></div>
        {params.saved && <div className="patient-alert success" role="status">Clinic settings saved.</div>}
        {params.department && <div className="patient-alert success" role="status">Department list updated.</div>}
        {params.error && errors[params.error] && <div className="patient-alert error" role="alert">{errors[params.error]}</div>}
        {clinicResult.error || !clinicResult.data ? <div className="patient-alert error">Clinic settings could not be loaded.</div> : <section className="patient-form-card" id="clinic">
          <div className="patient-form-heading"><span><Building2 size={17} /></span><div><h2>Clinic profile</h2><p>Time zone controls local appointment, invoice, and report dates.</p></div></div>
          <form action={saveClinicSettings} className="patient-form settings-form"><label>Clinic name *<input name="name" required minLength={2} maxLength={180} defaultValue={clinicResult.data.name} /></label><label>Clinic slug *<input name="slug" required pattern="[a-z0-9]+(-[a-z0-9]+)*" maxLength={180} defaultValue={clinicResult.data.slug} /></label><label>Time zone *<input name="timezone" required maxLength={80} defaultValue={clinicResult.data.timezone} placeholder="Asia/Karachi" /></label><label>Phone<input name="phone" maxLength={32} defaultValue={clinicResult.data.phone ?? ""} /></label><label>Email<input name="email" type="email" maxLength={254} defaultValue={clinicResult.data.email ?? ""} /></label><label className="settings-address">Address<textarea name="address" maxLength={500} rows={2} defaultValue={clinicResult.data.address ?? ""} /></label><div className="patient-form-actions"><span>Use an IANA time zone, such as Asia/Karachi or America/New_York.</span><button type="submit">Save clinic profile</button></div></form>
        </section>}
        <section className="patients-table-card" id="departments"><div className="patients-table-heading"><div><h2>Departments</h2><p>Clinic departments used for doctor records and scheduling.</p></div><Settings2 size={18} color="#377ae0" /></div>
          {departmentResult.error ? <div className="patients-empty"><b>Unable to load departments</b><p>Check clinic setup and administrator access.</p></div> : departmentResult.data?.length ? <div className="patients-table-scroll"><table className="patients-table"><thead><tr><th>Department</th><th>Status</th><th>Change status</th></tr></thead><tbody>{departmentResult.data.map((department) => <tr key={department.id}><td>{department.name}</td><td>{department.active ? "Active" : "Inactive"}</td><td><form action={updateDepartment} className="department-inline-form"><input type="hidden" name="id" value={department.id} /><input type="hidden" name="active" value={String(!department.active)} /><button className="table-action" type="submit">{department.active ? "Deactivate" : "Activate"}</button></form></td></tr>)}</tbody></table></div> : <div className="patients-empty compact-empty"><b>No departments configured</b><p>Add clinic service areas below.</p></div>}
          <form action={createDepartment} className="department-create-form"><label>New department<input name="name" required minLength={2} maxLength={100} /></label><button type="submit">Add department</button></form>
        </section>
      </div>
    </main>
  );
}
