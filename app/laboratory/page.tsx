import Link from "next/link";
import { redirect } from "next/navigation";
import { Beaker, FlaskConical, Plus, TestTube2 } from "lucide-react";
import { signOut } from "@/app/actions/auth";
import { createClient } from "@/lib/supabase/server";
import {
  collectLabSample, createLabCategory, createLabOrder, createLabTest,
  deliverLabOrderItem, recordLabResult, rejectLabSample,
  startLabProcessing, verifyLabResult,
} from "./actions";

export const instant = false;

type LabPageProps = { searchParams: Promise<Record<string, string | undefined>> };
type ResultField = {
  key: string;
  label: string;
  type: "number" | "text" | "boolean";
  unit?: string;
  referenceMin?: number;
  referenceMax?: number;
};

const messages: Record<string, string> = {
  invalid: "Check the required fields and try again.",
  schema: "The test result configuration is invalid. Review its configured fields.",
  duplicate: "That category or test code already exists in this clinic.",
  forbidden: "Your role does not have permission to perform that laboratory action.",
  save: "The catalog record could not be saved.",
  order: "The laboratory order could not be created. Check the selected patient, doctor, and tests.",
  sample: "The sample action could not be completed. Check its status and try again.",
  result: "The test result could not be recorded. Check the entered values and try again.",
  transition: "That laboratory workflow transition is not available.",
  verification: "The result could not be verified. Confirm the prior verification step.",
};

function asFields(value: unknown): ResultField[] {
  if (!Array.isArray(value)) return [];
  return value.filter((field): field is ResultField =>
    Boolean(field && typeof field === "object" && "key" in field && "label" in field && "type" in field),
  );
}

export default async function LaboratoryPage({ searchParams }: LabPageProps) {
  const params = await searchParams;
  const supabase = await createClient();
  const { data: claimsData, error: claimsError } = await supabase.auth.getClaims();
  if (!claimsData?.claims || claimsError) redirect("/login");
  const userId = String(claimsData.claims.sub ?? "");
  const { data: membership, error: membershipError } = await supabase.from("clinic_memberships")
    .select("clinic_id, role").eq("user_id", userId).eq("active", true).order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (membershipError || !membership) redirect("/");
  if (!["super_admin", "admin", "receptionist", "doctor", "lab_technician", "auditor"].includes(membership.role)) redirect("/");

  const [clinicResult, patientResult, doctorResult, categoryResult, testResult, orderResult] = await Promise.all([
    supabase.from("clinics").select("name").eq("id", membership.clinic_id).maybeSingle(),
    supabase.from("patients").select("id, mr_number, full_name").eq("clinic_id", membership.clinic_id)
      .is("archived_at", null).order("full_name").limit(500),
    supabase.from("doctors").select("id, full_name, specialization").eq("clinic_id", membership.clinic_id)
      .eq("active", true).order("full_name").limit(250),
    supabase.from("lab_categories").select("id, name").eq("clinic_id", membership.clinic_id).eq("active", true).order("sort_order"),
    supabase.from("lab_tests").select("id, category_id, code, name, price, result_schema, active")
      .eq("clinic_id", membership.clinic_id).eq("active", true).order("name"),
    supabase.from("lab_orders").select("id, patient_id, ordered_by_doctor_id, status, priority, ordered_at")
      .eq("clinic_id", membership.clinic_id).order("ordered_at", { ascending: false }).limit(50),
  ]);

  const orderIds = (orderResult.data ?? []).map((order) => order.id);
  const itemResult = orderIds.length
    ? await supabase.from("lab_order_items").select("id, order_id, test_id, test_name_snapshot, price_snapshot, status")
      .eq("clinic_id", membership.clinic_id).in("order_id", orderIds).order("created_at")
    : { data: [], error: null };
  const itemIds = (itemResult.data ?? []).map((item) => item.id);
  const [sampleResult, resultRows, verificationResult] = itemIds.length ? await Promise.all([
    supabase.from("lab_samples").select("id, order_item_id, sample_number, sample_type, status, rejection_reason")
      .eq("clinic_id", membership.clinic_id).in("order_item_id", itemIds).order("created_at", { ascending: false }),
    supabase.from("lab_results").select("id, order_item_id, version, result_values, abnormal_fields, critical")
      .eq("clinic_id", membership.clinic_id).in("order_item_id", itemIds).order("version", { ascending: false }),
    supabase.from("lab_result_verifications").select("result_id, level")
      .eq("clinic_id", membership.clinic_id).in("result_id", (await supabase.from("lab_results")
        .select("id").eq("clinic_id", membership.clinic_id).in("order_item_id", itemIds)).data?.map((row) => row.id) ?? []),
  ]) : [{ data: [], error: null }, { data: [], error: null }, { data: [], error: null }];

  const patientNames = new Map((patientResult.data ?? []).map((patient) => [patient.id, patient.full_name]));
  const doctorNames = new Map((doctorResult.data ?? []).map((doctor) => [doctor.id, doctor.full_name]));
  const tests = new Map((testResult.data ?? []).map((test) => [test.id, test]));
  const itemsByOrder = new Map<string, typeof itemResult.data>();
  for (const item of itemResult.data ?? []) {
    const group = itemsByOrder.get(item.order_id) ?? [];
    group.push(item);
    itemsByOrder.set(item.order_id, group);
  }
  const sampleByItem = new Map<string, NonNullable<typeof sampleResult.data>[number]>();
  for (const sample of sampleResult.data ?? []) if (!sampleByItem.has(sample.order_item_id)) sampleByItem.set(sample.order_item_id, sample);
  const latestResultByItem = new Map<string, NonNullable<typeof resultRows.data>[number]>();
  for (const result of resultRows.data ?? []) if (!latestResultByItem.has(result.order_item_id)) latestResultByItem.set(result.order_item_id, result);
  const verifiedLevels = new Map<string, Set<string>>();
  for (const verification of verificationResult.data ?? []) {
    const levels = verifiedLevels.get(verification.result_id) ?? new Set<string>();
    levels.add(verification.level);
    verifiedLevels.set(verification.result_id, levels);
  }

  const canOrder = ["super_admin", "admin", "receptionist", "doctor"].includes(membership.role);
  const canManageCatalog = ["super_admin", "admin"].includes(membership.role);
  const isLabTech = ["super_admin", "lab_technician"].includes(membership.role);
  const isDoctor = ["super_admin", "doctor"].includes(membership.role);
  const canDeliver = ["super_admin", "admin", "receptionist", "doctor"].includes(membership.role);
  const errorCode = params.error;

  return (
    <main className="patients-page laboratory-page">
      <header className="patients-topbar"><Link className="patients-brand" href="/">✚ <b>cliniccare<span>pro</span></b></Link><nav><Link href="/">Overview</Link><span>/</span><strong>Laboratory</strong></nav><div className="patients-user"><Link href="/">{String(claimsData.claims.email ?? "Clinic account")}</Link><form action={signOut}><button>Sign out</button></form></div></header>
      <div className="patients-content">
        <div className="patients-title-row"><div><p className="patients-eyebrow">DIAGNOSTICS / LABORATORY</p><h1>Laboratory</h1><p>{clinicResult.data?.name ?? "Your clinic"} · Catalog, orders, and result verification</p></div><span className="appointment-count"><FlaskConical size={15} /> {testResult.data?.length ?? 0} active tests</span></div>
        {params.ordered && <div className="patient-alert success" role="status">Laboratory order created. Prices were read from the clinic catalog.</div>}
        {(params.category || params.test) && <div className="patient-alert success" role="status">Laboratory catalog updated.</div>}
        {(params.sample || params.processing || params.result || params.verified || params.delivered) && <div className="patient-alert success" role="status">Laboratory workflow updated.</div>}
        {params.rejected && <div className="patient-alert success" role="status">Sample rejection recorded with its reason.</div>}
        {errorCode && messages[errorCode] && <div className="patient-alert error" role="alert">{messages[errorCode]}</div>}

        {canOrder && <section className="patient-form-card"><div className="patient-form-heading"><span><Beaker size={17} /></span><div><h2>Create a lab order</h2><p>Doctor selection and test prices are validated in the database.</p></div></div>
          {patientResult.error || doctorResult.error || testResult.error ? <div className="patient-alert error">The patient, doctor, or test catalog could not be loaded.</div> : !patientResult.data?.length || !doctorResult.data?.length || !testResult.data?.length ? <div className="patients-empty compact-empty"><b>Clinic setup is incomplete</b><p>Add patients, doctors, and active tests before ordering diagnostics.</p><Link href="/patients">Open patients →</Link><Link href="/doctors">Open doctors →</Link></div> : (
            <form action={createLabOrder} className="patient-form lab-order-form">
              <label>Patient *<select name="patientId" required defaultValue=""><option value="" disabled>Select a patient</option>{patientResult.data.map((patient) => <option key={patient.id} value={patient.id}>{patient.full_name} · {patient.mr_number}</option>)}</select></label>
              <label>Ordering doctor *<select name="doctorId" required defaultValue=""><option value="" disabled>Select a doctor</option>{doctorResult.data.map((doctor) => <option key={doctor.id} value={doctor.id}>{doctor.full_name} · {doctor.specialization}</option>)}</select></label>
              <label>Priority<select name="priority" defaultValue="routine"><option value="routine">Routine</option><option value="urgent">Urgent</option><option value="stat">STAT</option></select></label>
              <fieldset className="test-picker"><legend>Tests *</legend>{testResult.data.map((test) => <label className="test-option" key={test.id}><input type="checkbox" name="testIds" value={test.id} /><span><b>{test.name}</b><small>{test.code}</small></span><strong>{new Intl.NumberFormat("en-PK", { style: "currency", currency: "PKR", maximumFractionDigits: 0 }).format(test.price)}</strong></label>)}</fieldset>
              <label className="patient-address">Clinical note<input name="notes" maxLength={500} placeholder="Optional note for the laboratory team" /></label>
              <div className="patient-form-actions"><span>Total pricing is calculated from the active test catalog.</span><button type="submit">Create lab order</button></div>
            </form>
          )}
        </section>}

        <section className="patients-table-card"><div className="patients-table-heading"><div><h2>Recent lab orders</h2><p>Current sample, processing, and verification status</p></div></div>
          {orderResult.error || itemResult.error ? <div className="patients-empty"><b>Unable to load laboratory orders</b><p>Check the migration status and access policies.</p></div> : orderResult.data?.length ? <div className="lab-orders">{orderResult.data.map((order) => <article className="lab-order-card" key={order.id}>
            <header><div><b>{patientNames.get(order.patient_id) ?? "Patient record unavailable"}</b><small>{new Intl.DateTimeFormat("en", { dateStyle: "medium", timeStyle: "short", timeZone: "Asia/Karachi" }).format(new Date(order.ordered_at))} · {order.priority}</small></div><span className={`status-pill status-${order.status}`}>{order.status.replaceAll("_", " ")}</span></header>
            <p className="lab-order-doctor">Ordered by Dr. {doctorNames.get(order.ordered_by_doctor_id) ?? "Doctor"}</p>
            <div className="lab-items">{(itemsByOrder.get(order.id) ?? []).map((item) => {
              const test = tests.get(item.test_id);
              const fields = asFields(test?.result_schema);
              const sample = sampleByItem.get(item.id);
              const result = latestResultByItem.get(item.id);
              const levels = result ? verifiedLevels.get(result.id) ?? new Set<string>() : new Set<string>();
              return <div className="lab-item" key={item.id}>
                <div className="lab-item-main"><div><b>{item.test_name_snapshot}</b><small>{sample ? `Sample ${sample.sample_number}${sample.sample_type ? ` · ${sample.sample_type}` : ""}` : item.status === "ordered" ? "Sample required" : ""}</small></div><span className={`status-pill status-${item.status}`}>{item.status.replaceAll("_", " ")}</span></div>
                {sample?.status === "rejected" && <p className="sample-rejection">Rejected: {sample.rejection_reason}</p>}
                {result && <div className="lab-result-summary"><b>Result v{result.version}</b>{result.critical && <strong>Critical</strong>}{result.abnormal_fields.length > 0 && <span>Abnormal: {result.abnormal_fields.join(", ")}</span>}</div>}
                <div className="lab-workflow-actions">
                  {isLabTech && item.status === "ordered" && <form action={collectLabSample} className="inline-action"><input type="hidden" name="itemId" value={item.id} /><label>Sample type<input name="sampleType" maxLength={80} placeholder="e.g. blood" /></label><button><TestTube2 size={13} /> Collect sample</button></form>}
                  {isLabTech && sample?.status === "collected" && item.status === "sample_collected" && <><form action={startLabProcessing}><input type="hidden" name="itemId" value={item.id} /><button>Start processing</button></form><form action={rejectLabSample} className="inline-action"><input type="hidden" name="sampleId" value={sample.id} /><label>Reason<input name="reason" minLength={5} maxLength={500} required placeholder="Why is this sample rejected?" /></label><button className="reject-button">Reject sample</button></form></>}
                  {isLabTech && item.status === "processing" && fields.length > 0 && <details className="lab-result-entry"><summary>Enter test results</summary><form action={recordLabResult} className="patient-form"><input type="hidden" name="itemId" value={item.id} />{fields.map((field) => <label key={field.key}>{field.label}{field.unit ? ` (${field.unit})` : ""}{field.type === "boolean" ? <select name={field.key} defaultValue="" required><option value="" disabled>Select result</option><option value="true">Yes</option><option value="false">No</option></select> : <input name={field.key} type={field.type === "number" ? "number" : "text"} step={field.type === "number" ? "any" : undefined} required maxLength={field.type === "text" ? 4000 : undefined} />}{field.referenceMin !== undefined || field.referenceMax !== undefined ? <small className="reference-hint">Reference: {field.referenceMin ?? "—"}–{field.referenceMax ?? "—"} {field.unit}</small> : null}</label>)}<div className="patient-form-actions"><span>Abnormal and critical flags are calculated from the saved reference ranges.</span><button type="submit">Save results</button></div></form></details>}
                  {isLabTech && item.status === "completed" && result && !levels.has("technician_verified") && <form action={verifyLabResult}><input type="hidden" name="resultId" value={result.id} /><input type="hidden" name="level" value="technician_verified" /><button>Verify as technician</button></form>}
                  {isDoctor && item.status === "completed" && result && levels.has("technician_verified") && !levels.has("doctor_verified") && <form action={verifyLabResult} className="inline-action"><input type="hidden" name="resultId" value={result.id} /><input type="hidden" name="level" value="doctor_verified" /><label>Verification note<input name="notes" maxLength={500} placeholder="Optional note" /></label><button>Authorize result</button></form>}
                  {canDeliver && item.status === "verified" && <form action={deliverLabOrderItem}><input type="hidden" name="itemId" value={item.id} /><button>Mark delivered</button></form>}
                </div>
              </div>;
            })}</div>
          </article>)}</div> : <div className="patients-empty"><span><FlaskConical size={18} /></span><b>No laboratory orders</b><p>New lab orders will appear here when created.</p></div>}
        </section>

        {canManageCatalog && <section className="patient-form-card" id="catalog"><div className="patient-form-heading"><span><Plus size={17} /></span><div><h2>Test catalog</h2><p>Configure a result schema for each test. Reference and critical limits are saved with the test.</p></div></div>
          <div className="lab-catalog-grid"><form action={createLabCategory} className="lab-mini-form"><h3>Add category</h3><label>Category name<input name="name" required minLength={2} maxLength={100} placeholder="Hematology" /></label><button type="submit">Add category</button></form>
            <form action={createLabTest} className="lab-mini-form"><h3>Add test</h3><label>Category<select name="categoryId" required defaultValue=""><option value="" disabled>Select a category</option>{categoryResult.data?.map((category) => <option key={category.id} value={category.id}>{category.name}</option>)}</select></label><div className="lab-mini-row"><label>Test code<input name="code" required maxLength={40} placeholder="CBC" /></label><label>Test name<input name="name" required maxLength={160} /></label></div><div className="lab-mini-row"><label>Price (PKR)<input name="price" type="number" min="0" max="1000000" step="0.01" defaultValue="0" required /></label><label>Turnaround minutes<input name="turnaround" type="number" min="1" max="43200" /></label></div><label>Description<input name="description" maxLength={500} /></label><label>Result fields JSON<textarea name="resultSchema" rows={5} required defaultValue={'[{"key":"value","label":"Result","type":"number","unit":"","referenceMin":0,"referenceMax":100}]'} /><small>Each field uses a unique key and a type of number, text, or boolean. Numeric fields can include referenceMin/referenceMax and criticalMin/criticalMax.</small></label><button type="submit">Save test</button></form></div>
        </section>}
      </div>
    </main>
  );
}
