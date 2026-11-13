import Link from "next/link";
import { redirect } from "next/navigation";
import { Search, UserPlus } from "lucide-react";
import { signOut } from "@/app/actions/auth";
import { createClient } from "@/lib/supabase/server";
import { formatLocalDate } from "@/lib/dates";
import { registerPatient } from "./actions";

export const instant = false;

type PatientsPageProps = {
  searchParams: Promise<{ q?: string; created?: string; error?: string }>;
};

const messages: Record<string, string> = {
  invalid: "Review the form fields. Some values are missing or invalid.",
  duplicate: "A patient with the same phone number or name and date of birth already exists.",
  forbidden: "Your role does not have permission to register patients.",
  save: "The patient could not be saved. Please try again.",
};

export default async function PatientsPage({ searchParams }: PatientsPageProps) {
  const { q = "", created, error: errorCode } = await searchParams;
  const search = q.trim().slice(0, 100);
  const supabase = await createClient();
  const { data: claimsData, error: claimsError } = await supabase.auth.getClaims();
  if (!claimsData?.claims || claimsError) redirect("/login");

  const { data: membership, error: membershipError } = await supabase
    .from("clinic_memberships")
    .select("clinic_id, role")
    .eq("user_id", String(claimsData.claims.sub ?? ""))
    .eq("active", true)
    .limit(1)
    .maybeSingle();
  if (membershipError || !membership) redirect("/");
  if (!["super_admin", "admin", "receptionist", "doctor", "lab_technician", "radiology_technician", "radiologist"].includes(membership.role)) redirect("/");

  let query = supabase
    .from("patients")
    .select("id, mr_number, full_name, gender, phone, blood_group, registration_date", { count: "exact" })
    .eq("clinic_id", membership.clinic_id)
    .is("archived_at", null)
    .order("created_at", { ascending: false })
    .range(0, 24);
  if (search) query = query.ilike("full_name", `%${search.replace(/[,%_]/g, " ")}%`);
  const { data: patients, count, error } = await query;
  const canRegister = ["super_admin", "admin", "receptionist"].includes(membership.role);

  return (
    <main className="patients-page">
      <header className="patients-topbar">
        <Link className="patients-brand" href="/">✚ <b>cliniccare<span>pro</span></b></Link>
        <nav><Link href="/">Overview</Link><span>/</span><strong>Patients</strong></nav>
        <div className="patients-user"><Link href="/">{String(claimsData.claims.email ?? "Clinic account")}</Link><form action={signOut}><button>Sign out</button></form></div>
      </header>
      <div className="patients-content">
        <div className="patients-title-row">
          <div><p className="patients-eyebrow">WORKSPACE / PATIENTS</p><h1>Patients</h1><p>Manage patient registrations and contact details.</p></div>
          {canRegister && <a className="patient-add-button" href="#register"><UserPlus size={16} /> Register patient</a>}
        </div>

        {created && <div className="patient-alert success" role="status">Patient registered successfully.</div>}
        {errorCode && messages[errorCode] && <div className="patient-alert error" role="alert">{messages[errorCode]}</div>}

        <section className="patients-table-card">
          <div className="patients-table-heading"><div><h2>Patient directory</h2><p>{count ?? 0} patient records</p></div>
            <form className="patient-search" action="/patients" method="get"><Search size={15} /><input name="q" defaultValue={search} placeholder="Search by patient name" aria-label="Search patients by name" /><button type="submit">Search</button></form>
          </div>
          {error ? <div className="patients-empty"><b>Unable to load patients</b><p>Check the database connection and access policies, then refresh.</p></div> : patients?.length ? (
            <div className="patients-table-scroll"><table className="patients-table"><thead><tr><th>Patient</th><th>MR number</th><th>Gender</th><th>Phone</th><th>Blood group</th><th>Registered</th></tr></thead><tbody>
              {patients.map((patient) => <tr key={patient.id}><td><span className="patient-initial">{patient.full_name.slice(0, 1).toUpperCase()}</span><b>{patient.full_name}</b></td><td>{patient.mr_number}</td><td>{patient.gender}</td><td>{patient.phone || "—"}</td><td>{patient.blood_group || "—"}</td><td>{new Intl.DateTimeFormat("en", { dateStyle: "medium", timeZone: "Asia/Karachi" }).format(new Date(`${patient.registration_date}T12:00:00`))}</td></tr>)}
            </tbody></table></div>
          ) : <div className="patients-empty"><span><Search size={18} /></span><b>{search ? "No matching patients" : "No patients registered yet"}</b><p>{search ? "Try another name or clear the search." : "Register a patient to start building your clinic directory."}</p></div>}
          {count !== null && count > 25 && <p className="patients-pagination">Showing the first 25 of {count} patients. Narrow your search to find a record.</p>}
        </section>

        {canRegister && <section className="patient-form-card" id="register">
          <div className="patient-form-heading"><span><UserPlus size={17} /></span><div><h2>Register a patient</h2><p>Patient details are stored within your clinic workspace.</p></div></div>
          <form action={registerPatient} className="patient-form">
            <label>Full name *<input name="fullName" required minLength={2} maxLength={160} autoComplete="name" /></label>
            <label>Father / guardian name<input name="fatherName" maxLength={160} /></label>
            <label>Gender *<select name="gender" defaultValue="unknown" required><option value="unknown">Prefer not to say</option><option value="female">Female</option><option value="male">Male</option><option value="other">Other</option></select></label>
            <label>Date of birth<input name="dateOfBirth" type="date" max={formatLocalDate(new Date(), "Asia/Karachi")} /></label>
            <label>Phone number<input name="phone" type="tel" maxLength={32} autoComplete="tel" /></label>
            <label>Email<input name="email" type="email" maxLength={254} autoComplete="email" /></label>
            <label>Blood group<select name="bloodGroup" defaultValue=""><option value="">Not recorded</option>{["A+", "A-", "B+", "B-", "AB+", "AB-", "O+", "O-"].map((group) => <option key={group}>{group}</option>)}</select></label>
            <label>Emergency contact<input name="emergencyContactName" maxLength={160} /></label>
            <label>Emergency contact phone<input name="emergencyContactPhone" type="tel" maxLength={32} /></label>
            <label className="patient-address">Address<textarea name="address" maxLength={500} rows={2} /></label>
            <div className="patient-form-actions"><span>Fields marked * are required.</span><button type="submit">Save patient</button></div>
          </form>
        </section>}
      </div>
    </main>
  );
}
