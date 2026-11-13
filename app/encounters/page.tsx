import Link from "next/link";
import { redirect } from "next/navigation";
import { ClipboardPlus, FileCheck2, HeartPulse, Plus, Stethoscope } from "lucide-react";
import { signOut } from "@/app/actions/auth";
import { createClient } from "@/lib/supabase/server";
import { addEncounterDiagnosis, addEncounterNote, createEncounterPrescription, finalizeEncounter, recordVitals } from "./actions";

export const instant = false;

type EncounterPageProps = { searchParams: Promise<Record<string, string | undefined>> };

const errorMessages: Record<string, string> = {
  invalid: "Review the fields and try again.", save: "The clinical record could not be saved.",
  vitals: "Vitals were not saved. Check values and permissions.",
  prescription: "The prescription could not be saved. Review each selected medicine and dose.",
  finalize: "The encounter cannot be signed yet. Add the required assessment and resolve any errors.",
};

export default async function EncountersPage({ searchParams }: EncounterPageProps) {
  const params = await searchParams;
  const supabase = await createClient();
  const { data: claimsData, error: claimsError } = await supabase.auth.getClaims();
  if (!claimsData?.claims || claimsError) redirect("/login");
  const userId = String(claimsData.claims.sub ?? "");
  const { data: membership, error: membershipError } = await supabase.from("clinic_memberships").select("clinic_id, role")
    .eq("user_id", userId).eq("active", true).order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (membershipError || !membership || !["super_admin", "admin", "doctor", "auditor"].includes(membership.role)) redirect("/");

  const [clinicResult, encountersResult, productResult] = await Promise.all([
    supabase.from("clinics").select("name").eq("id", membership.clinic_id).maybeSingle(),
    supabase.from("encounters").select("id, patient_id, appointment_id, doctor_id, started_at, finalized_at")
      .eq("clinic_id", membership.clinic_id).order("started_at", { ascending: false }).limit(50),
    supabase.from("pharmacy_products").select("id, name, strength, dosage_form").eq("clinic_id", membership.clinic_id).eq("active", true).order("name").limit(100),
  ]);
  const encounters = encountersResult.data ?? [];
  const selected = encounters.find((encounter) => encounter.id === params.encounter) ?? null;
  const patientIds = [...new Set(encounters.map((encounter) => encounter.patient_id))];
  const doctorIds = [...new Set(encounters.map((encounter) => encounter.doctor_id))];
  const [patientResult, doctorResult] = patientIds.length ? await Promise.all([
    supabase.from("patients").select("id, full_name, mr_number, date_of_birth, gender, blood_group")
      .eq("clinic_id", membership.clinic_id).in("id", patientIds),
    supabase.from("doctors").select("id, full_name").eq("clinic_id", membership.clinic_id).in("id", doctorIds),
  ]) : [{ data: [], error: null }, { data: [], error: null }];
  const patientById = new Map((patientResult.data ?? []).map((patient) => [patient.id, patient]));
  const doctorById = new Map((doctorResult.data ?? []).map((doctor) => [doctor.id, doctor.full_name]));
  const [notesResult, diagnosisResult, vitalsResult, prescriptionResult] = selected ? await Promise.all([
    supabase.from("encounter_notes").select("id, kind, content, author_id, created_at").eq("clinic_id", membership.clinic_id)
      .eq("encounter_id", selected.id).order("created_at", { ascending: true }),
    supabase.from("encounter_diagnoses").select("id, code, description, is_primary, recorded_at").eq("clinic_id", membership.clinic_id)
      .eq("encounter_id", selected.id).order("recorded_at", { ascending: true }),
    supabase.from("vitals").select("id, systolic_bp, diastolic_bp, temperature_c, pulse_bpm, weight_kg, height_cm, recorded_at")
      .eq("clinic_id", membership.clinic_id).eq("encounter_id", selected.id).order("recorded_at", { ascending: false }),
    supabase.from("prescriptions").select("id, status, prescribed_at").eq("clinic_id", membership.clinic_id).eq("encounter_id", selected.id).order("prescribed_at", { ascending: false }),
  ]) : [{ data: [], error: null }, { data: [], error: null }, { data: [], error: null }, { data: [], error: null }];
  const prescriptionIds = (prescriptionResult.data ?? []).map((row) => row.id);
  const prescriptionItems = prescriptionIds.length ? await supabase.from("prescription_items")
    .select("prescription_id, product_name_snapshot, strength_snapshot, dose, frequency, duration_days, quantity, instructions")
    .eq("clinic_id", membership.clinic_id).in("prescription_id", prescriptionIds) : { data: [], error: null };

  const canEdit = ["super_admin", "doctor"].includes(membership.role);
  const canAddVitals = canEdit;

  return (
    <main className="patients-page encounters-page">
      <header className="patients-topbar"><Link className="patients-brand" href="/">✚ <b>cliniccare<span>pro</span></b></Link><nav><Link href="/">Overview</Link><span>/</span><Link href="/appointments">Appointments</Link><span>/</span><strong>Clinical encounters</strong></nav><div className="patients-user"><Link href="/">{String(claimsData.claims.email ?? "Clinic account")}</Link><form action={signOut}><button>Sign out</button></form></div></header>
      <div className="patients-content">
        <div className="patients-title-row"><div><p className="patients-eyebrow">CLINICAL / ENCOUNTERS</p><h1>Clinical encounters</h1><p>{clinicResult.data?.name ?? "Your clinic"} · Document care, diagnoses, vitals, and prescriptions</p></div><span className="appointment-count"><Stethoscope size={15} /> {encounters.length} recent visits</span></div>
        {params.saved && <div className="patient-alert success" role="status">Clinical record saved.</div>}
        {params.finalized && <div className="patient-alert success" role="status">Encounter signed and finalized. Clinical notes are now read-only.</div>}
        {params.error && errorMessages[params.error] && <div className="patient-alert error" role="alert">{errorMessages[params.error]}</div>}
        {encountersResult.error ? <section className="patients-table-card"><div className="patients-empty"><b>Unable to load encounters</b><p>Check that the encounter migration is installed and your role can access the clinician&apos;s records.</p></div></section> : (
          <div className="encounter-layout">
            <section className="patients-table-card encounter-list-card"><div className="patients-table-heading"><div><h2>Recent encounters</h2><p>Appointments opened by your care team</p></div><Link className="table-action" href="/appointments">Open queue</Link></div>
              {encounters.length ? <div className="encounter-list">{encounters.map((encounter) => {
                const patient = patientById.get(encounter.patient_id);
                return <Link className={selected?.id === encounter.id ? "encounter-list-item selected" : "encounter-list-item"} key={encounter.id} href={`/encounters?encounter=${encounter.id}`}>
                  <span className="patient-initial">{patient?.full_name?.slice(0, 1) ?? "P"}</span><span><b>{patient?.full_name ?? "Patient record"}</b><small>{patient?.mr_number ?? ""} · {new Intl.DateTimeFormat("en-PK", { dateStyle: "medium", timeStyle: "short", timeZone: "Asia/Karachi" }).format(new Date(encounter.started_at))}</small></span><i>{encounter.finalized_at ? "Signed" : "Open"}</i>
                </Link>;
              })}</div> : <div className="patients-empty compact-empty"><b>No encounters yet</b><p>Check in an appointment, then use Start consultation to open its clinical record.</p><Link href="/appointments">Go to appointments →</Link></div>}
            </section>

            {!selected ? <section className="patient-form-card encounter-empty-detail"><ClipboardPlus size={26} /><h2>Select an encounter</h2><p>Choose an open or signed visit to review its clinical record.</p></section> : (() => {
              const patient = patientById.get(selected.patient_id);
              const isOpen = !selected.finalized_at;
              const encounterItems = (prescriptionItems.data ?? []).filter((item) => (prescriptionResult.data ?? []).some((rx) => rx.id === item.prescription_id));
              return <section className="encounter-detail">
                <article className="patient-form-card encounter-patient-card"><div><p className="patients-eyebrow">{selected.finalized_at ? "SIGNED ENCOUNTER" : "ACTIVE ENCOUNTER"}</p><h2>{patient?.full_name ?? "Patient"}</h2><p>{patient?.mr_number ?? "MR number unavailable"} · {patient?.gender ?? ""} {patient?.date_of_birth ? `· DOB ${patient.date_of_birth}` : ""} {patient?.blood_group ? `· ${patient.blood_group}` : ""}</p></div><div><b>Dr. {doctorById.get(selected.doctor_id) ?? "Clinician"}</b><small>{new Intl.DateTimeFormat("en-PK", { dateStyle: "medium", timeStyle: "short", timeZone: "Asia/Karachi" }).format(new Date(selected.started_at))}</small>{selected.finalized_at && <small>Signed {new Intl.DateTimeFormat("en-PK", { dateStyle: "medium", timeZone: "Asia/Karachi" }).format(new Date(selected.finalized_at))}</small>}</div></article>
                {(notesResult.error || diagnosisResult.error || vitalsResult.error) && <div className="patient-alert error">Some clinical history could not be loaded. Check database policies.</div>}
                <section className="patient-form-card"><div className="patient-form-heading"><span><HeartPulse size={17} /></span><div><h2>Vitals</h2><p>Measurements are append-only and timestamped.</p></div></div>
                  {(vitalsResult.data ?? []).length > 0 && <div className="clinical-vitals">{vitalsResult.data?.map((vital) => <div className="clinical-vital-row" key={vital.id}><span>BP <b>{vital.systolic_bp ?? "—"}/{vital.diastolic_bp ?? "—"}</b></span><span>Temp <b>{vital.temperature_c ?? "—"}°C</b></span><span>Pulse <b>{vital.pulse_bpm ?? "—"} bpm</b></span><span>Weight <b>{vital.weight_kg ?? "—"} kg</b></span><span>Height <b>{vital.height_cm ?? "—"} cm</b></span></div>)}</div>}
                  {isOpen && canAddVitals && <form action={recordVitals} className="patient-form clinical-vitals-form"><input type="hidden" name="encounterId" value={selected.id} /><label>Systolic BP<input type="number" name="systolic" min="40" max="300" /></label><label>Diastolic BP<input type="number" name="diastolic" min="20" max="200" /></label><label>Temperature °C<input type="number" name="temperature" min="25" max="45" step="0.1" /></label><label>Pulse bpm<input type="number" name="pulse" min="20" max="250" /></label><label>Weight kg<input type="number" name="weight" min="0.2" max="500" step="0.01" /></label><label>Height cm<input type="number" name="height" min="20" max="260" step="0.01" /></label><div className="patient-form-actions"><span>Leave unmeasured values blank.</span><button type="submit">Save vitals</button></div></form>}
                </section>

                <section className="patient-form-card"><div className="patient-form-heading"><span><ClipboardPlus size={17} /></span><div><h2>Diagnoses</h2><p>Clinical impression and optional coding.</p></div></div>
                  {(diagnosisResult.data ?? []).length > 0 && <ul className="clinical-record-list">{diagnosisResult.data?.map((diagnosis) => <li key={diagnosis.id}><b>{diagnosis.description}</b>{diagnosis.code && <small>{diagnosis.code}</small>}{diagnosis.is_primary && <span>Primary</span>}</li>)}</ul>}
                  {isOpen && canEdit && <form action={addEncounterDiagnosis} className="patient-form clinical-diagnosis-form"><input type="hidden" name="encounterId" value={selected.id} /><label>Diagnosis *<input name="description" required minLength={2} maxLength={240} /></label><label>Code<input name="code" maxLength={32} placeholder="Optional ICD code" /></label><label>Primary<select name="primary" defaultValue="false"><option value="false">No</option><option value="true">Yes</option></select></label><div className="patient-form-actions"><span>Record each diagnosis separately.</span><button type="submit">Add diagnosis</button></div></form>}
                </section>

                <section className="patient-form-card"><div className="patient-form-heading"><span><FileCheck2 size={17} /></span><div><h2>Clinical notes</h2><p>Each saved note is a signed, timestamped entry.</p></div></div>
                  {(notesResult.data ?? []).length > 0 && <div className="clinical-notes-list">{notesResult.data?.map((note) => <article key={note.id}><header><b>{note.kind.replaceAll("_", " ")}</b><time>{new Intl.DateTimeFormat("en-PK", { dateStyle: "medium", timeStyle: "short", timeZone: "Asia/Karachi" }).format(new Date(note.created_at))}</time></header><p>{note.content}</p></article>)}</div>}
                  {isOpen && canEdit && <form action={addEncounterNote} className="patient-form clinical-note-form"><input type="hidden" name="encounterId" value={selected.id} /><label>Section<select name="kind" defaultValue="chief_complaint"><option value="chief_complaint">Chief complaint</option><option value="history">History</option><option value="examination">Examination</option><option value="assessment">Assessment</option><option value="plan">Plan</option><option value="follow_up">Follow-up</option></select></label><label className="clinical-note-content">Note *<textarea name="content" required maxLength={8000} rows={4} /></label><div className="patient-form-actions"><span>Corrections must be added as new notes.</span><button type="submit">Add note</button></div></form>}
                </section>

                <section className="patient-form-card"><div className="patient-form-heading"><span><Plus size={17} /></span><div><h2>Prescriptions</h2><p>Medicine orders are sent to the pharmacy with dose and duration details.</p></div></div>
                  {encounterItems.length > 0 && <ul className="clinical-record-list">{encounterItems.map((item, index) => <li key={`${item.prescription_id}-${index}`}><b>{item.product_name_snapshot} {item.strength_snapshot ?? ""}</b><small>{item.dose} · {item.frequency} · {item.duration_days} days · Qty {item.quantity}</small></li>)}</ul>}
                  {isOpen && canEdit && <form action={createEncounterPrescription} className="clinical-prescription-form"><input type="hidden" name="encounterId" value={selected.id} />
                    {productResult.data?.length ? <>{productResult.data.map((product) => <fieldset key={product.id}><legend><label><input type="checkbox" name="productIds" value={product.id} /> {product.name} {product.strength ?? ""} · {product.dosage_form}</label></legend><div className="patient-form"><label>Dose<input name={`dose_${product.id}`} maxLength={120} placeholder="1 tablet" /></label><label>Frequency<input name={`frequency_${product.id}`} maxLength={120} placeholder="Twice daily" /></label><label>Days<input name={`days_${product.id}`} type="number" min="1" max="365" /></label><label>Quantity<input name={`quantity_${product.id}`} type="number" min="0.01" max="100000" step="0.01" /></label><label className="clinical-note-content">Instructions<input name={`instructions_${product.id}`} maxLength={500} /></label></div></fieldset>)}<div className="patient-form-actions"><span>Only checked products are prescribed.</span><button type="submit">Save prescription</button></div></> : <div className="patients-empty compact-empty"><b>No active pharmacy products</b><p>Set up the product catalog before prescribing medicines.</p><Link href="/pharmacy">Open pharmacy →</Link></div>}
                  </form>}
                </section>
                {isOpen && canEdit && <form action={finalizeEncounter} className="encounter-finalize-form"><input type="hidden" name="encounterId" value={selected.id} /><span>Signing closes the encounter. Add an assessment note first.</span><button type="submit">Sign and finalize encounter</button></form>}
              </section>;
            })()}
          </div>
        )}
      </div>
    </main>
  );
}
