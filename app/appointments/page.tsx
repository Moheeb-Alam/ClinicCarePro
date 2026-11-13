import Link from "next/link";
import { redirect } from "next/navigation";
import { CalendarDays, Clock3, UserRoundPlus } from "lucide-react";
import { signOut } from "@/app/actions/auth";
import { createClient } from "@/lib/supabase/server";
import { formatLocalDateTime, localDateBoundary } from "@/lib/dates";
import { createAppointment, updateAppointmentStatus } from "./actions";

export const instant = false;

type AppointmentsPageProps = {
  searchParams: Promise<{ created?: string; updated?: string; error?: string }>;
};

const messages: Record<string, string> = {
  invalid: "Check the patient, doctor, time, and duration fields.",
  date: "Choose a future appointment time within the next 12 months.",
  selection: "Choose an active patient and doctor from this clinic.",
  token: "A visit token could not be allocated. Please try again.",
  conflict: "That doctor already has an appointment during the selected time.",
  save: "The appointment could not be saved. Please try again.",
  forbidden: "Your role cannot perform that appointment action.",
  missing: "The appointment could not be found.",
  transition: "That appointment status change is no longer available.",
};

const nextFrontDeskStatus: Record<string, { label: string; value: string } | undefined> = {
  scheduled: { label: "Confirm", value: "confirmed" },
  confirmed: { label: "Check in", value: "checked_in" },
};

export default async function AppointmentsPage({ searchParams }: AppointmentsPageProps) {
  const { created, updated, error: errorCode } = await searchParams;
  const supabase = await createClient();
  const { data: claimsData, error: claimsError } = await supabase.auth.getClaims();
  if (!claimsData?.claims || claimsError) redirect("/login");

  const userId = String(claimsData.claims.sub ?? "");
  const { data: membership, error: membershipError } = await supabase.from("clinic_memberships")
    .select("clinic_id, role").eq("user_id", userId).eq("active", true).order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (membershipError || !membership) redirect("/");
  if (!["super_admin", "admin", "receptionist", "doctor"].includes(membership.role)) redirect("/");

  const { data: clinic } = await supabase.from("clinics").select("name, timezone")
    .eq("id", membership.clinic_id).maybeSingle();
  const timezone = clinic?.timezone ?? "Asia/Karachi";
  const now = new Date();
  const start = localDateBoundary(now, timezone, 0);
  const end = localDateBoundary(now, timezone, 1);

  const [patientResult, doctorResult, appointmentResult, assignedDoctorResult] = await Promise.all([
    supabase.from("patients").select("id, mr_number, full_name").eq("clinic_id", membership.clinic_id)
      .is("archived_at", null).order("full_name").limit(500),
    supabase.from("doctors").select("id, full_name, specialization").eq("clinic_id", membership.clinic_id)
      .eq("active", true).order("full_name").limit(250),
    supabase.from("appointments").select("id, patient_id, doctor_id, starts_at, status, token_number")
      .eq("clinic_id", membership.clinic_id).gte("starts_at", start).lt("starts_at", end)
      .order("starts_at", { ascending: true }).limit(100),
    membership.role === "doctor"
      ? supabase.from("doctors").select("id").eq("clinic_id", membership.clinic_id).eq("profile_id", userId).maybeSingle()
      : Promise.resolve({ data: null, error: null }),
  ]);

  const patientNames = new Map((patientResult.data ?? []).map((patient) => [patient.id, patient.full_name]));
  const doctorNames = new Map((doctorResult.data ?? []).map((doctor) => [doctor.id, doctor.full_name]));
  const canCreate = ["super_admin", "admin", "receptionist"].includes(membership.role);
  const canManageQueue = canCreate;
  const currentDoctorId = assignedDoctorResult.data?.id;
  const dateLabel = new Intl.DateTimeFormat("en", { dateStyle: "full", timeZone: timezone }).format(now);

  return (
    <main className="appointments-page">
      <header className="patients-topbar">
        <Link className="patients-brand" href="/">✚ <b>cliniccare<span>pro</span></b></Link>
        <nav><Link href="/">Overview</Link><span>/</span><strong>Appointments</strong></nav>
        <div className="patients-user"><span>{String(claimsData.claims.email ?? "Clinic account")}</span><form action={signOut}><button>Sign out</button></form></div>
      </header>
      <div className="patients-content">
        <div className="patients-title-row"><div><p className="patients-eyebrow">WORKSPACE / APPOINTMENTS</p><h1>Appointments</h1><p>{clinic?.name ?? "Your clinic"} · {dateLabel}</p></div><span className="appointment-count"><CalendarDays size={15} /> {appointmentResult.data?.length ?? 0} scheduled</span></div>
        {created && <div className="patient-alert success" role="status">Appointment booked successfully.</div>}
        {updated && <div className="patient-alert success" role="status">Appointment status updated.</div>}
        {errorCode && messages[errorCode] && <div className="patient-alert error" role="alert">{messages[errorCode]}</div>}

        <section className="patients-table-card">
          <div className="patients-table-heading"><div><h2>Today’s appointments</h2><p>Visit queue for {new Intl.DateTimeFormat("en", { dateStyle: "medium", timeZone: timezone }).format(now)}</p></div></div>
          {appointmentResult.error ? <div className="patients-empty"><b>Unable to load appointments</b><p>Check the database connection and access policies, then refresh.</p></div> : appointmentResult.data?.length ? (
            <div className="patients-table-scroll"><table className="patients-table appointments-table"><thead><tr><th>Time / token</th><th>Patient</th><th>Doctor</th><th>Status</th><th>Next step</th></tr></thead><tbody>
              {appointmentResult.data.map((appointment) => {
                const status = appointment.status;
                const isAssignedDoctor = membership.role === "doctor" && currentDoctorId === appointment.doctor_id;
                const nextStatus = canManageQueue ? nextFrontDeskStatus[status] : undefined;
                const clinicalStatus = isAssignedDoctor && status === "checked_in"
                  ? { label: "Start consultation", value: "in_consultation" }
                  : isAssignedDoctor && status === "in_consultation"
                    ? { label: "Complete visit", value: "completed" }
                    : undefined;
                const action = nextStatus ?? clinicalStatus;
                const canCancel = canManageQueue && ["scheduled", "confirmed", "checked_in"].includes(status);
                return <tr key={appointment.id}>
                  <td><b>{new Intl.DateTimeFormat("en", { hour: "numeric", minute: "2-digit", timeZone: timezone }).format(new Date(appointment.starts_at))}</b><small>{appointment.token_number ? `Token ${appointment.token_number}` : "No token"}</small></td>
                  <td><b>{patientNames.get(appointment.patient_id) ?? "Patient record unavailable"}</b></td>
                  <td>{doctorNames.get(appointment.doctor_id) ?? "Doctor record unavailable"}</td>
                  <td><span className={`status-pill status-${status}`}>{status.replaceAll("_", " ")}</span></td>
                  <td>{action || canCancel ? <div className="appointment-row-actions">
                    {action && <form action={updateAppointmentStatus}><input type="hidden" name="appointmentId" value={appointment.id} /><input type="hidden" name="status" value={action.value} /><button>{action.label}</button></form>}
                    {canCancel && <form action={updateAppointmentStatus}><input type="hidden" name="appointmentId" value={appointment.id} /><input type="hidden" name="status" value="cancelled" /><button className="cancel-action">Cancel</button></form>}
                  </div> : <span className="not-available">—</span>}</td>
                </tr>;
              })}
            </tbody></table></div>
          ) : <div className="patients-empty"><span><CalendarDays size={18} /></span><b>No appointments today</b><p>New appointments booked for today will appear in this queue.</p></div>}
          {appointmentResult.data && appointmentResult.data.length === 100 && <p className="patients-pagination">Showing the first 100 appointments for today.</p>}
        </section>

        {canCreate && <section className="patient-form-card appointment-form-card" id="book">
          <div className="patient-form-heading"><span><UserRoundPlus size={17} /></span><div><h2>Book an appointment</h2><p>Appointment conflicts are checked by the database when the booking is saved.</p></div></div>
          {patientResult.error || doctorResult.error ? <div className="patient-alert error">Patient and doctor lists could not be loaded.</div> : !patientResult.data?.length || !doctorResult.data?.length ? <div className="patients-empty compact-empty"><b>Patient and doctor records are required</b><p>Add an active patient and doctor before booking an appointment.</p><Link href="/patients">Open patient directory →</Link><Link href="/doctors">Open doctor directory →</Link></div> : (
            <form action={createAppointment} className="patient-form">
              <label>Patient *<select name="patientId" required defaultValue=""><option value="" disabled>Select a patient</option>{patientResult.data.map((patient) => <option key={patient.id} value={patient.id}>{patient.full_name} · {patient.mr_number}</option>)}</select></label>
              <label>Doctor *<select name="doctorId" required defaultValue=""><option value="" disabled>Select a doctor</option>{doctorResult.data.map((doctor) => <option key={doctor.id} value={doctor.id}>{doctor.full_name} · {doctor.specialization}</option>)}</select></label>
              <label>Start time *<span className="date-control"><Clock3 size={13} /><input name="startsAt" type="datetime-local" required min={formatLocalDateTime(new Date(), timezone)} /></span></label>
              <label>Duration<select name="duration" defaultValue="20"><option value="10">10 minutes</option><option value="15">15 minutes</option><option value="20">20 minutes</option><option value="30">30 minutes</option><option value="45">45 minutes</option><option value="60">60 minutes</option><option value="90">90 minutes</option></select></label>
              <label className="patient-address">Visit reason<input name="reason" maxLength={240} placeholder="Optional note for the care team" /></label>
              <div className="patient-form-actions"><span>Tokens are assigned by the database.</span><button type="submit">Book appointment</button></div>
            </form>
          )}
        </section>}
      </div>
    </main>
  );
}
