import Link from "next/link";
import { redirect } from "next/navigation";
import { Banknote, ClipboardList, Plus, ReceiptText } from "lucide-react";
import { signOut } from "@/app/actions/auth";
import { createClient } from "@/lib/supabase/server";
import { createBill, createService, issueBill, recordExpense, recordPayment, reversePayment } from "./actions";

export const instant = false;

type BillingPageProps = { searchParams: Promise<Record<string, string | undefined>> };
type PaymentRow = {
  id: string; bill_id: string; entry_type: "payment" | "reversal"; amount: number | string;
  method: string; reference: string | null; reverses_payment_id: string | null;
  reason: string | null; occurred_at: string;
};
type BillItemRow = { bill_id: string; description_snapshot: string; quantity: number | string; unit_price_snapshot: number | string; line_total: number | string };

const messages: Record<string, string> = {
  invalid: "Review the form fields and try again.",
  forbidden: "Your role does not have permission to perform that finance action.",
  duplicate: "That service code already exists in this clinic.",
  save: "The service could not be saved.",
  create: "The draft bill could not be created. Check the patient and selected services.",
  issue: "The bill could not be issued. Check that it contains a positive total.",
  payment: "The payment could not be recorded. Check the bill balance and payment amount.",
  reversal: "The payment could not be reversed. It may already have been reversed.",
};

function money(value: number | string | null | undefined) {
  return new Intl.NumberFormat("en-PK", { style: "currency", currency: "PKR", maximumFractionDigits: 2 }).format(Number(value ?? 0));
}

function when(value: string) {
  return new Intl.DateTimeFormat("en-PK", { dateStyle: "medium", timeStyle: "short", timeZone: "Asia/Karachi" }).format(new Date(value));
}

export default async function BillingPage({ searchParams }: BillingPageProps) {
  const params = await searchParams;
  const supabase = await createClient();
  const { data: claimsData, error: claimsError } = await supabase.auth.getClaims();
  if (!claimsData?.claims || claimsError) redirect("/login");
  const userId = String(claimsData.claims.sub ?? "");
  const { data: membership, error: membershipError } = await supabase.from("clinic_memberships")
    .select("clinic_id, role").eq("user_id", userId).eq("active", true).order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (membershipError || !membership) redirect("/");
  const role = membership.role;
  if (!["super_admin", "admin", "receptionist", "accountant", "auditor"].includes(role)) redirect("/");

  const [clinicResult, patientResult, serviceResult, billResult, expenseResult] = await Promise.all([
    supabase.from("clinics").select("name").eq("id", membership.clinic_id).maybeSingle(),
    supabase.from("patients").select("id, mr_number, full_name").eq("clinic_id", membership.clinic_id)
      .is("archived_at", null).order("full_name").limit(500),
    supabase.from("service_catalog").select("id, code, name, kind, unit_price, active")
      .eq("clinic_id", membership.clinic_id).order("name"),
    supabase.from("bill_balances").select("id, patient_id, invoice_number, issued_at, created_at, total_amount, amount_paid, balance_due, status")
      .eq("clinic_id", membership.clinic_id).order("created_at", { ascending: false }).limit(100),
    supabase.from("expenses").select("id, category, description, amount, spent_at, created_at")
      .eq("clinic_id", membership.clinic_id).order("spent_at", { ascending: false }).limit(100),
  ]);
  const billIds = (billResult.data ?? []).map((bill) => bill.id);
  const [paymentResult, itemResult] = billIds.length ? await Promise.all([
    supabase.from("payments").select("id, bill_id, entry_type, amount, method, reference, reverses_payment_id, reason, occurred_at")
      .eq("clinic_id", membership.clinic_id).in("bill_id", billIds).order("occurred_at", { ascending: false }),
    supabase.from("bill_items").select("bill_id, description_snapshot, quantity, unit_price_snapshot, line_total")
      .eq("clinic_id", membership.clinic_id).in("bill_id", billIds).order("created_at"),
  ]) : [{ data: [], error: null }, { data: [], error: null }];

  const patientNames = new Map((patientResult.data ?? []).map((patient) => [patient.id, `${patient.full_name} (${patient.mr_number})`]));
  const paymentsByBill = new Map<string, PaymentRow[]>();
  for (const payment of paymentResult.data ?? []) {
    const rows = paymentsByBill.get(payment.bill_id) ?? [];
    rows.push(payment);
    paymentsByBill.set(payment.bill_id, rows);
  }
  const itemsByBill = new Map<string, BillItemRow[]>();
  for (const item of itemResult.data ?? []) {
    const rows = itemsByBill.get(item.bill_id) ?? [];
    rows.push(item);
    itemsByBill.set(item.bill_id, rows);
  }

  const canCreate = ["super_admin", "admin", "receptionist", "accountant"].includes(role);
  const canIssue = ["super_admin", "admin", "accountant"].includes(role);
  const canPay = ["super_admin", "admin", "receptionist", "accountant"].includes(role);
  const canReverse = ["super_admin", "admin", "accountant"].includes(role);
  const canManageCatalog = ["super_admin", "admin"].includes(role);
  const canRecordExpense = ["super_admin", "admin", "accountant"].includes(role);

  return (
    <main className="patients-page billing-page">
      <header className="patients-topbar">
        <Link className="patients-brand" href="/">✚ <b>cliniccare<span>pro</span></b></Link>
        <nav><Link href="/">Overview</Link><span>/</span><strong>Billing</strong></nav>
        <div className="patients-user"><Link href="/">{String(claimsData.claims.email ?? "Clinic account")}</Link><form action={signOut}><button>Sign out</button></form></div>
      </header>
      <div className="patients-content">
        <div className="patients-title-row">
          <div><p className="patients-eyebrow">FINANCE / BILLING</p><h1>Billing</h1><p>{clinicResult.data?.name ?? "Your clinic"} · Invoices, receipts, and service pricing</p></div>
          <span className="appointment-count"><ReceiptText size={15} /> {billResult.data?.length ?? 0} recent bills</span>
        </div>
        {params.created && <div className="patient-alert success" role="status">Draft bill created. An accountant or administrator must issue it before payment.</div>}
        {(params.issued || params.paid || params.reversed || params.service || params.expense) && <div className="patient-alert success" role="status">Finance record saved successfully.</div>}
        {params.error && messages[params.error] && <div className="patient-alert error" role="alert">{messages[params.error]}</div>}

        {canCreate && <section className="patient-form-card" id="create">
          <div className="patient-form-heading"><span><Plus size={17} /></span><div><h2>Create draft bill</h2><p>Prices are loaded and snapshotted by the database from your service catalog.</p></div></div>
          {patientResult.error || serviceResult.error ? <div className="patients-empty compact-empty"><b>Billing data is unavailable</b><p>Check the database migrations, connection, and role policies.</p></div> : !patientResult.data?.length || !serviceResult.data?.some((service) => service.active) ? <div className="patients-empty compact-empty"><b>Set up billing first</b><p>Add patients and active service prices before creating a bill.</p></div> : (
            <form action={createBill} className="patient-form billing-create-form">
              <label>Patient *<select name="patientId" required defaultValue=""><option value="" disabled>Select a patient</option>{patientResult.data.map((patient) => <option key={patient.id} value={patient.id}>{patient.full_name} · {patient.mr_number}</option>)}</select></label>
              <label className="billing-notes">Notes<textarea name="notes" maxLength={500} rows={2} /></label>
              <fieldset className="billing-service-picker"><legend>Services *</legend>
                {serviceResult.data.filter((service) => service.active).map((service) => <label className="billing-service-option" key={service.id}>
                  <span><input type="checkbox" name="serviceIds" value={service.id} /> <b>{service.name}</b><small>{service.kind.replaceAll("_", " ")} · {money(service.unit_price)}</small></span>
                  <span className="billing-quantity">Qty<input type="number" name={`quantity_${service.id}`} min="0.01" max="100000" step="0.01" defaultValue="1" /></span>
                </label>)}
              </fieldset>
              <div className="patient-form-actions"><span>Draft bills do not affect balances until issued.</span><button type="submit">Create draft bill</button></div>
            </form>
          )}
        </section>}

        <section className="patients-table-card">
          <div className="patients-table-heading"><div><h2>Invoices</h2><p>Latest 100 bills in this clinic</p></div><Banknote size={18} color="#377ae0" /></div>
          {billResult.error ? <div className="patients-empty"><b>Unable to load invoices</b><p>Confirm the finance migration has been applied and your role can view bills.</p></div> : billResult.data?.length ? (
            <div className="patients-table-scroll"><table className="patients-table billing-table"><thead><tr><th>Invoice / patient</th><th>Items</th><th>Total</th><th>Paid</th><th>Balance</th><th>Status</th><th>Actions</th></tr></thead>
              <tbody>{billResult.data.map((bill) => {
                const billPayments = paymentsByBill.get(bill.id) ?? [];
                const billItems = itemsByBill.get(bill.id) ?? [];
                return <tr key={bill.id}>
                  <td><b>{bill.invoice_number}</b><small>{patientNames.get(bill.patient_id) ?? "Patient record"}</small><small>{when(bill.created_at)}</small></td>
                  <td>{billItems.map((item) => <small key={`${bill.id}-${item.description_snapshot}`}>{item.description_snapshot} × {item.quantity}</small>)}</td>
                  <td>{money(bill.total_amount)}</td><td>{money(bill.amount_paid)}</td><td className={Number(bill.balance_due) > 0 ? "billing-due" : ""}>{money(bill.balance_due)}</td>
                  <td><span className={`status-pill billing-status-${bill.status}`}>{bill.status.replaceAll("_", " ")}</span></td>
                  <td><div className="billing-actions">
                    {!bill.issued_at && canIssue && <form action={issueBill}><input type="hidden" name="billId" value={bill.id} /><button className="table-action" type="submit">Issue</button></form>}
                    {bill.issued_at && Number(bill.balance_due) > 0 && canPay && <details><summary className="table-action">Take payment</summary><form action={recordPayment} className="billing-inline-form"><input type="hidden" name="billId" value={bill.id} /><label>Amount<input name="amount" type="number" min="0.01" max={bill.balance_due} step="0.01" defaultValue={bill.balance_due} required /></label><label>Method<select name="method" defaultValue="cash"><option value="cash">Cash</option><option value="card">Card</option><option value="bank_transfer">Bank transfer</option><option value="online">Online</option></select></label><label>Reference<input name="reference" maxLength={120} /></label><button type="submit">Record payment</button></form></details>}
                  </div>
                  {billPayments.length > 0 && <details className="billing-history"><summary>{billPayments.length} payment event{billPayments.length === 1 ? "" : "s"}</summary>{billPayments.map((payment) => <div className="billing-payment-row" key={payment.id}><span>{payment.entry_type === "reversal" ? "Reversed" : payment.method.replaceAll("_", " ")} · {when(payment.occurred_at)} · {money(payment.amount)}</span>{payment.entry_type === "payment" && canReverse && <form action={reversePayment}><input type="hidden" name="paymentId" value={payment.id} /><input name="reason" minLength={5} maxLength={500} placeholder="Reversal reason" required /><button type="submit">Reverse</button></form>}</div>)}</details>}
                  </td>
                </tr>;
              })}</tbody>
            </table></div>
          ) : <div className="patients-empty"><span><ClipboardList size={18} /></span><b>No invoices yet</b><p>Create a draft bill to begin recording clinic charges.</p></div>}
        </section>

        <section className="patients-table-card" id="expenses"><div className="patients-table-heading"><div><h2>Clinic expenses</h2><p>Recorded operating expenses, separate from patient invoices</p></div><Banknote size={18} color="#377ae0" /></div>
          {canRecordExpense && <form action={recordExpense} className="patient-form expense-form"><label>Category *<input name="category" required minLength={2} maxLength={100} placeholder="Supplies, utilities..." /></label><label>Description *<input name="description" required minLength={2} maxLength={500} /></label><label>Amount (PKR) *<input name="amount" type="number" min="0.01" max="100000000" step="0.01" required /></label><label>Date *<input name="spentAt" type="date" required defaultValue={new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Karachi" }).format(new Date())} /></label><div className="patient-form-actions"><span>Expense entries are audited and cannot be silently changed.</span><button type="submit">Record expense</button></div></form>}
          {expenseResult.error && canRecordExpense ? <div className="patients-empty compact-empty"><b>Expense entries unavailable</b><p>Check the finance migration and accounting permissions.</p></div> : expenseResult.data?.length ? <div className="patients-table-scroll"><table className="patients-table"><thead><tr><th>Date</th><th>Category</th><th>Description</th><th>Amount</th></tr></thead><tbody>{expenseResult.data.map((expense) => <tr key={expense.id}><td>{expense.spent_at}</td><td>{expense.category}</td><td>{expense.description}</td><td>{money(expense.amount)}</td></tr>)}</tbody></table></div> : <div className="patients-empty compact-empty"><b>No expenses recorded</b><p>Clinic operating costs can be recorded by an accountant or administrator.</p></div>}
        </section>

        {canManageCatalog && <section className="patient-form-card" id="catalog">
          <div className="patient-form-heading"><span><Banknote size={17} /></span><div><h2>Service catalog</h2><p>Manage the clinic prices available for new bills.</p></div></div>
          <form action={createService} className="patient-form billing-catalog-form">
            <label>Code *<input name="code" required minLength={2} maxLength={40} pattern="[A-Za-z0-9._-]+" /></label>
            <label>Service name *<input name="name" required minLength={2} maxLength={160} /></label>
            <label>Category *<select name="kind" defaultValue="service"><option value="consultation">Consultation</option><option value="laboratory">Laboratory</option><option value="imaging">Imaging</option><option value="pharmacy">Pharmacy</option><option value="service">Service</option><option value="other">Other</option></select></label>
            <label>Price (PKR) *<input name="price" type="number" min="0" max="100000000" step="0.01" required /></label>
            <div className="patient-form-actions"><span>Existing issued invoices keep their original price snapshots.</span><button type="submit">Add service</button></div>
          </form>
          <div className="patients-table-scroll"><table className="patients-table"><thead><tr><th>Code</th><th>Service</th><th>Category</th><th>Price</th><th>Status</th></tr></thead><tbody>{(serviceResult.data ?? []).map((service) => <tr key={service.id}><td>{service.code}</td><td>{service.name}</td><td>{service.kind}</td><td>{money(service.unit_price)}</td><td>{service.active ? "Active" : "Inactive"}</td></tr>)}</tbody></table></div>
        </section>}
      </div>
    </main>
  );
}
