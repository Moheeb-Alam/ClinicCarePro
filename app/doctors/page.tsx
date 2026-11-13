import Link from "next/link";
import { redirect } from "next/navigation";
import { Stethoscope, UserRoundPlus } from "lucide-react";
import { signOut } from "@/app/actions/auth";
import { createClient } from "@/lib/supabase/server";
import { createDoctor, setDoctorActive } from "./actions";

export const instant = false;

type DoctorsPageProps = { searchParams: Promise<{ q?: string; created?: string; updated?: string; error?: string }> };
const messages: Record<string, string> = {
  invalid: "Check the doctor details and try again.",
  save: "The doctor record could not be saved.",
  forbidden: "Your role does not have permission to manage doctor records.",
};

export default async function DoctorsPage({ searchParams }: DoctorsPageProps) {
  const { q = "", created, updated, error: errorCode } = await searchParams;
  const search = q.trim().slice(0, 100);
  const supabase = await createClient();
  const { data: claimsData, error: claimsError } = await supabase.auth.getClaims();
  if (!claimsData?.claims || claimsError) redirect("/login");
  const userId = String(claimsData.claims.sub ?? "");
  const { data: membership, error: membershipError } = await supabase.from("clinic_memberships")
    .select("clinic_id, role").eq("user_id", userId).eq("active", true).order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (membershipError || !membership) redirect("/");
  if (!["super_admin", "admin", "receptionist", "doctor"].includes(membership.role)) redirect("/");
  const { data: doctors, count, error } = await (search
    ? supabase.from("doctors").select("id, full_name, specialization, qualification, experience_years, consultation_fee, active", { count: "exact" })
      .eq("clinic_id", membership.clinic_id).ilike("full_name", `%${search.replace(/[,%_]/g, " ")}%`)
      .order("full_name").range(0, 99)
    : supabase.from("doctors").select("id, full_name, specialization, qualification, experience_years, consultation_fee, active", { count: "exact" })
      .eq("clinic_id", membership.clinic_id).order("full_name").range(0, 99));
  const canManage = ["super_admin", "admin"].includes(membership.role);

  return (
    <main className="patients-page">
      <header className="patients-topbar"><Link className="patients-brand" href="/">✚ <b>cliniccare<span>pro</span></b></Link><nav><Link href="/">Overview</Link><span>/</span><strong>Doctors</strong></nav><div className="patients-user"><Link href="/">{String(claimsData.claims.email ?? "Clinic account")}</Link><form action={signOut}><button>Sign out</button></form></div></header>
      <div className="patients-content">
        <div className="patients-title-row"><div><p className="patients-eyebrow">WORKSPACE / DOCTORS</p><h1>Doctors</h1><p>Manage clinical staff and consultation settings.</p></div>{canManage && <a className="patient-add-button" href="#add-doctor"><UserRoundPlus size={16} /> Add doctor</a>}</div>
        {created && <div className="patient-alert success" role="status">Doctor added successfully.</div>}{updated && <div className="patient-alert success" role="status">Doctor status updated.</div>}{errorCode && messages[errorCode] && <div className="patient-alert error" role="alert">{messages[errorCode]}</div>}
        <section className="patients-table-card"><div className="patients-table-heading"><div><h2>Doctor directory</h2><p>{count ?? 0} doctor records</p></div><form className="patient-search" action="/doctors" method="get"><Stethoscope size={15} /><input name="q" defaultValue={search} placeholder="Search by doctor name" aria-label="Search doctors by name" /><button type="submit">Search</button></form></div>
          {error ? <div className="patients-empty"><b>Unable to load doctors</b><p>Check the database connection and access policies.</p></div> : doctors?.length ? <div className="patients-table-scroll"><table className="patients-table"><thead><tr><th>Doctor</th><th>Specialization</th><th>Qualification</th><th>Experience</th><th>Consultation fee</th><th>Status</th>{canManage && <th>Action</th>}</tr></thead><tbody>
            {doctors.map((doctor) => <tr key={doctor.id}><td><span className="patient-initial doctor-initial">{doctor.full_name.slice(0, 1).toUpperCase()}</span><b>{doctor.full_name}</b></td><td>{doctor.specialization}</td><td>{doctor.qualification || "—"}</td><td>{doctor.experience_years === null ? "—" : `${doctor.experience_years} years`}</td><td>{new Intl.NumberFormat("en-PK", { style: "currency", currency: "PKR", maximumFractionDigits: 0 }).format(doctor.consultation_fee)}</td><td><span className={`status-pill ${doctor.active ? "status-completed" : "status-cancelled"}`}>{doctor.active ? "Active" : "Inactive"}</span></td>{canManage && <td><form action={setDoctorActive}><input type="hidden" name="id" value={doctor.id} /><input type="hidden" name="active" value={String(!doctor.active)} /><button className="table-action">{doctor.active ? "Deactivate" : "Activate"}</button></form></td>}</tr>)}
          </tbody></table></div> : <div className="patients-empty"><span><Stethoscope size={18} /></span><b>{search ? "No matching doctors" : "No doctors added yet"}</b><p>{search ? "Try a different name." : "Add an active doctor before booking appointments."}</p></div>}
          {count !== null && count > 100 && <p className="patients-pagination">Showing the first 100 of {count} doctors.</p>}
        </section>
        {canManage && <section id="add-doctor" className="patient-form-card"><div className="patient-form-heading"><span><Stethoscope size={17} /></span><div><h2>Add a doctor</h2><p>Consultation fees are recorded as clinic pricing details.</p></div></div><form action={createDoctor} className="patient-form"><label>Full name *<input name="fullName" required minLength={2} maxLength={160} /></label><label>Specialization *<input name="specialization" required minLength={2} maxLength={120} placeholder="Family medicine" /></label><label>Qualification<input name="qualification" maxLength={240} placeholder="MBBS, FCPS" /></label><label>Experience (years)<input name="experienceYears" type="number" min="0" max="80" defaultValue="0" required /></label><label>Consultation fee (PKR)<input name="consultationFee" type="number" min="0" max="1000000" step="0.01" defaultValue="0" required /></label><div className="patient-form-actions"><span>Fields marked * are required.</span><button type="submit">Save doctor</button></div></form></section>}
      </div>
    </main>
  );
}
