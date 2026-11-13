import Link from "next/link";
import { redirect } from "next/navigation";
import { Activity, FileImage, ScanLine } from "lucide-react";
import { signOut } from "@/app/actions/auth";
import { createClient } from "@/lib/supabase/server";
import { beginImagingStudy, createImagingOrder, createImagingService, signRadiologyReport, updateImagingStatus } from "./actions";

export const instant = false;

type ImagingPageProps = { searchParams: Promise<Record<string, string | undefined>> };
const messages: Record<string, string> = {
  invalid: "Review the form fields and try again.", forbidden: "Your role does not have permission for this imaging action.",
  duplicate: "That imaging service code already exists.", save: "The service could not be saved.",
  order: "The imaging order could not be created.", transition: "That imaging status change is not valid.",
  study: "The study could not be started.", report: "The report could not be signed. The linked PACS study and report version must be valid.",
};

function money(value: number | string) {
  return new Intl.NumberFormat("en-PK", { style: "currency", currency: "PKR", maximumFractionDigits: 2 }).format(Number(value));
}

export default async function ImagingPage({ searchParams }: ImagingPageProps) {
  const params = await searchParams;
  const supabase = await createClient();
  const { data: claimsData, error: claimsError } = await supabase.auth.getClaims();
  if (!claimsData?.claims || claimsError) redirect("/login");
  const userId = String(claimsData.claims.sub ?? "");
  const { data: membership, error: membershipError } = await supabase.from("clinic_memberships").select("clinic_id, role")
    .eq("user_id", String(claimsData.claims.sub ?? "")).eq("active", true).order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (membershipError || !membership || !["super_admin", "admin", "receptionist", "doctor", "radiology_technician", "radiologist", "auditor"].includes(membership.role)) redirect("/");
  const role = membership.role;
  let doctorQuery = supabase.from("doctors").select("id, full_name, specialization").eq("clinic_id", membership.clinic_id).eq("active", true);
  if (role === "doctor") doctorQuery = doctorQuery.eq("profile_id", userId);
  const [clinicResult, patientResult, doctorResult, serviceResult, orderResult] = await Promise.all([
    supabase.from("clinics").select("name").eq("id", membership.clinic_id).maybeSingle(),
    supabase.from("patients").select("id, mr_number, full_name").eq("clinic_id", membership.clinic_id).is("archived_at", null).order("full_name").limit(500),
    doctorQuery.order("full_name").limit(250),
    supabase.from("imaging_services").select("id, code, name, modality, body_region, price, active").eq("clinic_id", membership.clinic_id).order("name"),
    supabase.from("imaging_orders").select("id, patient_id, ordered_by_doctor_id, service_id, service_name_snapshot, modality, price_snapshot, priority, status, ordered_at, clinical_question")
      .eq("clinic_id", membership.clinic_id).order("ordered_at", { ascending: false }).limit(100),
  ]);
  const orderIds = (orderResult.data ?? []).map((order) => order.id);
  const [studyResult, patientNamesResult, doctorNamesResult] = orderIds.length ? await Promise.all([
    supabase.from("imaging_studies").select("id, order_id, accession_number, modality, dicom_study_uid, pacs_study_id, performed_at")
      .eq("clinic_id", membership.clinic_id).in("order_id", orderIds),
    supabase.from("patients").select("id, mr_number, full_name").eq("clinic_id", membership.clinic_id).in("id", (orderResult.data ?? []).map((order) => order.patient_id)),
    supabase.from("doctors").select("id, full_name").eq("clinic_id", membership.clinic_id).in("id", (orderResult.data ?? []).map((order) => order.ordered_by_doctor_id)),
  ]) : [{ data: [], error: null }, { data: [], error: null }, { data: [], error: null }];
  const studyIds = (studyResult.data ?? []).map((study) => study.id);
  const [reportResult, fileResult] = studyIds.length ? await Promise.all([
    supabase.from("radiology_reports").select("id, study_id, version, findings, impression, signed_at")
      .eq("clinic_id", membership.clinic_id).in("study_id", studyIds).order("version", { ascending: false }),
    supabase.from("imaging_files").select("id, study_id, byte_size, uploaded_at").eq("clinic_id", membership.clinic_id).in("study_id", studyIds),
  ]) : [{ data: [], error: null }, { data: [], error: null }];

  const patients = new Map((patientNamesResult.data ?? []).map((patient) => [patient.id, patient]));
  const doctors = new Map((doctorNamesResult.data ?? []).map((doctor) => [doctor.id, doctor.full_name]));
  const studies = new Map((studyResult.data ?? []).map((study) => [study.order_id, study]));
  const latestReports = new Map<string, NonNullable<typeof reportResult.data>[number]>();
  for (const report of reportResult.data ?? []) if (!latestReports.has(report.study_id)) latestReports.set(report.study_id, report);
  const filesByStudy = new Map<string, number>();
  for (const file of fileResult.data ?? []) filesByStudy.set(file.study_id, (filesByStudy.get(file.study_id) ?? 0) + Number(file.byte_size));
  const canOrder = ["super_admin", "admin", "receptionist", "doctor"].includes(role);
  const canManageCatalog = ["super_admin", "admin"].includes(role);
  const canSchedule = ["super_admin", "radiology_technician"].includes(role);
  const canSign = ["super_admin", "radiologist"].includes(role);
  const canDeliver = ["super_admin", "admin", "receptionist"].includes(role);

  return (
    <main className="patients-page imaging-page">
      <header className="patients-topbar"><Link className="patients-brand" href="/">✚ <b>cliniccare<span>pro</span></b></Link><nav><Link href="/">Overview</Link><span>/</span><strong>Imaging</strong></nav><div className="patients-user"><Link href="/">{String(claimsData.claims.email ?? "Clinic account")}</Link><form action={signOut}><button>Sign out</button></form></div></header>
      <div className="patients-content">
        <div className="patients-title-row"><div><p className="patients-eyebrow">DIAGNOSTICS / IMAGING</p><h1>Imaging</h1><p>{clinicResult.data?.name ?? "Your clinic"} · Orders, accessioning, and signed reports</p></div><span className="appointment-count"><ScanLine size={15} /> {orderResult.data?.length ?? 0} recent orders</span></div>
        <div className="patient-alert error" role="note"><b>PACS connection required.</b> This workspace can create and track orders, but image upload, DICOM verification, and viewing require a configured private PACS/DICOM service. Image acquisition cannot be marked complete until that service links the study identifier.</div>
        {params.ordered && <div className="patient-alert success" role="status">Imaging order created.</div>}
        {(params.updated || params.study || params.reported || params.service) && <div className="patient-alert success" role="status">Imaging record updated.</div>}
        {params.error && messages[params.error] && <div className="patient-alert error" role="alert">{messages[params.error]}</div>}

        {canOrder && <section className="patient-form-card" id="create"><div className="patient-form-heading"><span><FileImage size={17} /></span><div><h2>Order imaging</h2><p>Service price and modality are snapshotted from the clinic catalog.</p></div></div>
          {patientResult.error || doctorResult.error || serviceResult.error ? <div className="patients-empty compact-empty"><b>Order data is unavailable</b><p>Check imaging migrations and clinic access policies.</p></div> : !patientResult.data?.length || !serviceResult.data?.some((service) => service.active) ? <div className="patients-empty compact-empty"><b>Set up patients and imaging services</b><p>Active clinic services are required before ordering.</p></div> : <form action={createImagingOrder} className="patient-form"><label>Patient *<select name="patientId" required defaultValue=""><option value="" disabled>Select patient</option>{patientResult.data.map((patient) => <option key={patient.id} value={patient.id}>{patient.full_name} · {patient.mr_number}</option>)}</select></label><label>Ordering doctor *<select name="doctorId" required defaultValue=""><option value="" disabled>Select doctor</option>{doctorResult.data?.map((doctor) => <option key={doctor.id} value={doctor.id}>{doctor.full_name} · {doctor.specialization}</option>)}</select></label><label>Service *<select name="serviceId" required defaultValue=""><option value="" disabled>Select imaging service</option>{serviceResult.data.filter((service) => service.active).map((service) => <option key={service.id} value={service.id}>{service.name} · {service.modality.toUpperCase()} · {money(service.price)}</option>)}</select></label><label>Priority<select name="priority" defaultValue="routine"><option value="routine">Routine</option><option value="urgent">Urgent</option><option value="stat">STAT</option></select></label><label className="patient-address">Clinical question<input name="question" maxLength={1000} /></label><div className="patient-form-actions"><span>Only the ordering doctor and imaging team can access the clinical order.</span><button type="submit">Create imaging order</button></div></form>}
        </section>}

        <section className="patients-table-card"><div className="patients-table-heading"><div><h2>Imaging worklist</h2><p>Accession, study, report, and delivery status</p></div><Activity size={18} color="#377ae0" /></div>
          {orderResult.error ? <div className="patients-empty"><b>Unable to load imaging worklist</b><p>Check schema setup and role access.</p></div> : orderResult.data?.length ? <div className="imaging-order-list">{orderResult.data.map((order) => {
            const patient = patients.get(order.patient_id);
            const study = studies.get(order.id);
            const report = study ? latestReports.get(study.id) : undefined;
            const fileBytes = study ? filesByStudy.get(study.id) ?? 0 : 0;
            return <article className="imaging-order-card" key={order.id}><header><div><b>{order.service_name_snapshot}</b><small>{patient?.full_name ?? "Patient record"} · {patient?.mr_number ?? ""} · Dr. {doctors.get(order.ordered_by_doctor_id) ?? "Doctor"}</small><small>{order.modality.toUpperCase()} · {order.priority.toUpperCase()} · {new Intl.DateTimeFormat("en-PK", { dateStyle: "medium", timeStyle: "short", timeZone: "Asia/Karachi" }).format(new Date(order.ordered_at))}</small></div><span className={`status-pill status-${order.status}`}>{order.status.replaceAll("_", " ")}</span></header>
              {order.clinical_question && <p className="imaging-question">Clinical question: {order.clinical_question}</p>}
              {study && <div className="imaging-study-meta"><span>Accession <b>{study.accession_number}</b></span><span>{study.dicom_study_uid || study.pacs_study_id ? "PACS linked" : "PACS not linked"}</span>{fileBytes > 0 && <span>{(fileBytes / 1048576).toFixed(1)} MB registered</span>}</div>}
              {report && <details className="imaging-report-preview"><summary>Signed report · v{report.version} · {new Intl.DateTimeFormat("en-PK", { dateStyle: "medium", timeZone: "Asia/Karachi" }).format(new Date(report.signed_at))}</summary><h4>Findings</h4><p>{report.findings}</p><h4>Impression</h4><p>{report.impression}</p></details>}
              <div className="imaging-actions">
                {order.status === "ordered" && canSchedule && <form action={updateImagingStatus}><input type="hidden" name="orderId" value={order.id} /><input type="hidden" name="status" value="scheduled" /><button type="submit">Schedule</button></form>}
                {order.status === "scheduled" && canSchedule && <form action={beginImagingStudy}><input type="hidden" name="orderId" value={order.id} /><button type="submit">Start / assign accession</button></form>}
                {order.status === "verified" && canDeliver && <form action={updateImagingStatus}><input type="hidden" name="orderId" value={order.id} /><input type="hidden" name="status" value="delivered" /><button type="submit">Mark delivered</button></form>}
                {study && canSign && ["image_acquired", "report_draft", "verified"].includes(order.status) && <details className="imaging-report-form"><summary>{report ? "Correct signed report" : "Write and sign report"}</summary><form action={signRadiologyReport}><input type="hidden" name="studyId" value={study.id} />{report && <><input type="hidden" name="previousReportId" value={report.id} /><label>Correction reason<input name="correctionReason" minLength={5} maxLength={500} required /></label></>}<label>Findings<textarea name="findings" required maxLength={20000} rows={4} defaultValue={report?.findings ?? ""} /></label><label>Impression<textarea name="impression" required maxLength={5000} rows={3} defaultValue={report?.impression ?? ""} /></label><button type="submit">Sign report</button></form></details>}
                {order.status === "in_progress" && <span className="imaging-waiting"><Activity size={14} /> Waiting for PACS to attach and verify study</span>}
              </div>
            </article>;
          })}</div> : <div className="patients-empty"><span><ScanLine size={18} /></span><b>No imaging orders</b><p>Orders placed by the clinic will appear here.</p></div>}
        </section>

        {canManageCatalog && <section className="patient-form-card" id="catalog"><div className="patient-form-heading"><span><ScanLine size={17} /></span><div><h2>Imaging service catalog</h2><p>Configure modalities, body regions, and current service prices.</p></div></div><form action={createImagingService} className="patient-form imaging-catalog-form"><label>Code *<input name="code" required minLength={2} maxLength={40} pattern="[A-Za-z0-9._-]+" /></label><label>Service name *<input name="name" required minLength={2} maxLength={160} /></label><label>Modality *<select name="modality"><option value="xray">X-ray</option><option value="ct">CT</option><option value="mri">MRI</option></select></label><label>Body region<input name="bodyRegion" maxLength={120} /></label><label>Price (PKR) *<input name="price" type="number" min="0" max="1000000" step="0.01" required /></label><div className="patient-form-actions"><span>Catalog changes do not rewrite existing order prices.</span><button type="submit">Add imaging service</button></div></form><div className="patients-table-scroll"><table className="patients-table"><thead><tr><th>Code</th><th>Service</th><th>Modality</th><th>Region</th><th>Price</th><th>Status</th></tr></thead><tbody>{(serviceResult.data ?? []).map((service) => <tr key={service.id}><td>{service.code}</td><td>{service.name}</td><td>{service.modality.toUpperCase()}</td><td>{service.body_region ?? "—"}</td><td>{money(service.price)}</td><td>{service.active ? "Active" : "Inactive"}</td></tr>)}</tbody></table></div></section>}
      </div>
    </main>
  );
}
