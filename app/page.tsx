import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { localDateBoundary } from "@/lib/dates";
import Dashboard from "./dashboard";

export const instant = false;

export default async function Home() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;

  if (!url || !key) {
    return (
      <main className="setup-screen">
        <div className="setup-card">
          <span className="brand-mark">✚</span>
          <p className="setup-eyebrow">CLINICCARE PRO</p>
          <h1>Connect your clinic workspace</h1>
          <p>Add your Supabase project URL and publishable key to <code>.env.local</code>, then apply the migration to enable secure sign-in and live clinic data.</p>
          <Link href="https://supabase.com/dashboard" target="_blank" rel="noreferrer">Open Supabase dashboard ↗</Link>
        </div>
      </main>
    );
  }

  const supabase = await createClient();
  const { data, error: claimsError } = await supabase.auth.getClaims();
  if (!data?.claims || claimsError) redirect("/login");

  const userId = String(data.claims.sub ?? "");
  const { data: membership, error: membershipError } = await supabase
    .from("clinic_memberships")
    .select("clinic_id, role")
    .eq("user_id", userId)
    .eq("active", true)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (membershipError || !membership) {
    return (
      <main className="setup-screen">
        <div className="setup-card">
          <span className="brand-mark">✚</span>
          <p className="setup-eyebrow">CLINICCARE PRO</p>
          <h1>Clinic access not set up</h1>
          <p>{membershipError
            ? `The app could not read clinic membership data (${membershipError.code}: ${membershipError.message}).` 
            : "No active clinic membership was found for this login. Check the email and membership rows in Supabase SQL Editor."}</p>
        </div>
      </main>
    );
  }

  const { data: clinic } = await supabase
    .from("clinics")
    .select("name, timezone")
    .eq("id", membership.clinic_id)
    .maybeSingle();
  const timezone = clinic?.timezone ?? "Asia/Karachi";
  const now = new Date();
  const start = localDateBoundary(now, timezone, 0);
  const end = localDateBoundary(now, timezone, 1);
  const canReadPatients = ["super_admin", "admin", "receptionist", "doctor", "lab_technician", "radiology_technician", "radiologist"].includes(membership.role);
  const canReadAppointments = ["super_admin", "admin", "receptionist", "doctor"].includes(membership.role);
  const canReadEncounters = ["super_admin", "admin", "doctor", "auditor"].includes(membership.role);

  const [patients, appointments, doctors, encounters] = await Promise.all([
    supabase.from("patients").select("id", { count: "exact", head: true })
      .eq("clinic_id", membership.clinic_id).is("archived_at", null),
    supabase.from("appointments").select("id", { count: "exact", head: true })
      .eq("clinic_id", membership.clinic_id).gte("starts_at", start).lt("starts_at", end)
      .in("status", ["scheduled", "confirmed", "checked_in", "in_consultation"]),
    supabase.from("doctors").select("id", { count: "exact", head: true })
      .eq("clinic_id", membership.clinic_id).eq("active", true),
    supabase.from("encounters").select("id", { count: "exact", head: true })
      .eq("clinic_id", membership.clinic_id).is("finalized_at", null),
  ]);
  const { data: appointmentRows, error: appointmentRowsError } = await supabase
    .from("appointments")
    .select("id, starts_at, status, patient_id, doctor_id")
    .eq("clinic_id", membership.clinic_id)
    .gte("starts_at", start)
    .lt("starts_at", end)
    .in("status", ["scheduled", "confirmed", "checked_in", "in_consultation"])
    .order("starts_at", { ascending: true })
    .limit(5);
  const patientIds = [...new Set((appointmentRows ?? []).map((appointment) => appointment.patient_id))];
  const doctorIds = [...new Set((appointmentRows ?? []).map((appointment) => appointment.doctor_id))];
  const [patientsById, doctorsById] = await Promise.all([
    patientIds.length
      ? supabase.from("patients").select("id, full_name").in("id", patientIds)
      : Promise.resolve({ data: [], error: null }),
    doctorIds.length
      ? supabase.from("doctors").select("id, full_name").in("id", doctorIds)
      : Promise.resolve({ data: [], error: null }),
  ]);
  const patientNames = new Map((patientsById.data ?? []).map((patient) => [patient.id, patient.full_name]));
  const doctorNames = new Map((doctorsById.data ?? []).map((doctor) => [doctor.id, doctor.full_name]));

  return (
    <Dashboard
      clinicName={clinic?.name ?? "Your clinic"}
      userEmail={String(data.claims.email ?? "")}
      role={membership.role}
      schedule={!canReadAppointments || appointmentRowsError ? null : (appointmentRows ?? []).map((appointment) => ({
        id: appointment.id,
        startsAt: appointment.starts_at,
        status: appointment.status,
        patientName: patientNames.get(appointment.patient_id) ?? "Patient",
        doctorName: doctorNames.get(appointment.doctor_id) ?? "Doctor",
      }))}
      stats={{
        patients: !canReadPatients || patients.error ? null : patients.count,
        appointments: !canReadAppointments || appointments.error ? null : appointments.count,
        doctors: doctors.error ? null : doctors.count,
        encounters: !canReadEncounters || encounters.error ? null : encounters.count,
      }}
    />
  );
}


