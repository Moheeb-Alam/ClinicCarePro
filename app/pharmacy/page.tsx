import Link from "next/link";
import { redirect } from "next/navigation";
import { Boxes, PackagePlus, Pill, ReceiptText } from "lucide-react";
import { signOut } from "@/app/actions/auth";
import { createClient } from "@/lib/supabase/server";
import { createProduct, dispensePrescriptionItem, receiveStock } from "./actions";

export const instant = false;

type PharmacyPageProps = { searchParams: Promise<Record<string, string | undefined>> };
type PharmacyItem = { id: string; prescription_id: string; product_name_snapshot: string; strength_snapshot: string | null; dosage_form_snapshot: string; dose: string; frequency: string; duration_days: number; quantity: number | string; instructions: string | null };

const messages: Record<string, string> = {
  invalid: "Review the entered fields and try again.", forbidden: "Your role cannot perform that pharmacy action.",
  duplicate: "That product code already exists in this clinic.", save: "The product could not be saved.",
  stock: "The stock receipt could not be saved. Check the lot and expiry details.",
  dispense: "Dispensing failed. Check prescription status and unexpired available stock.",
};

function money(value: number | string) {
  return new Intl.NumberFormat("en-PK", { style: "currency", currency: "PKR", maximumFractionDigits: 2 }).format(Number(value));
}

export default async function PharmacyPage({ searchParams }: PharmacyPageProps) {
  const params = await searchParams;
  const supabase = await createClient();
  const { data: claimsData, error: claimsError } = await supabase.auth.getClaims();
  if (!claimsData?.claims || claimsError) redirect("/login");
  const userId = String(claimsData.claims.sub ?? "");
  const { data: membership, error: membershipError } = await supabase.from("clinic_memberships")
    .select("clinic_id, role").eq("user_id", userId).eq("active", true).order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (membershipError || !membership) redirect("/");
  const role = membership.role;
  if (!["super_admin", "admin", "pharmacist", "accountant", "auditor", "doctor"].includes(role)) redirect("/");

  const [clinicResult, productResult, lotResult, prescriptionResult] = await Promise.all([
    supabase.from("clinics").select("name").eq("id", membership.clinic_id).maybeSingle(),
    supabase.from("pharmacy_products").select("id, code, name, generic_name, strength, dosage_form, unit_label, sale_price, reorder_level, active")
      .eq("clinic_id", membership.clinic_id).order("name"),
    supabase.from("pharmacy_stock_lots").select("id, product_id, batch_number, expires_on, quantity_remaining, purchase_unit_cost")
      .eq("clinic_id", membership.clinic_id).gte("expires_on", new Date().toISOString().slice(0, 10)).gt("quantity_remaining", 0).order("expires_on"),
    supabase.from("prescriptions").select("id, patient_id, doctor_id, status, prescribed_at")
      .eq("clinic_id", membership.clinic_id).in("status", ["active", "partially_dispensed"]).order("prescribed_at", { ascending: false }).limit(100),
  ]);
  const rxIds = (prescriptionResult.data ?? []).map((rx) => rx.id);
  const [rxItemsResult, patientResult, doctorResult] = rxIds.length ? await Promise.all([
    supabase.from("prescription_items").select("id, prescription_id, product_name_snapshot, strength_snapshot, dosage_form_snapshot, dose, frequency, duration_days, quantity, instructions")
      .eq("clinic_id", membership.clinic_id).in("prescription_id", rxIds).order("created_at"),
    supabase.from("patients").select("id, full_name, mr_number").eq("clinic_id", membership.clinic_id)
      .in("id", (prescriptionResult.data ?? []).map((rx) => rx.patient_id)),
    supabase.from("doctors").select("id, full_name").eq("clinic_id", membership.clinic_id),
  ]) : [{ data: [], error: null }, { data: [], error: null }, { data: [], error: null }];
  const itemIds = (rxItemsResult.data ?? []).map((item) => item.id);
  const dispenseResult = itemIds.length ? await supabase.from("pharmacy_dispenses").select("prescription_item_id, quantity")
    .eq("clinic_id", membership.clinic_id).in("prescription_item_id", itemIds) : { data: [], error: null };

  const products = productResult.data ?? [];
  const stockByProduct = new Map<string, number>();
  for (const lot of lotResult.data ?? []) stockByProduct.set(lot.product_id, (stockByProduct.get(lot.product_id) ?? 0) + Number(lot.quantity_remaining));
  const doctorsById = new Map((doctorResult.data ?? []).map((doctor) => [doctor.id, doctor.full_name]));
  const patientsById = new Map((patientResult.data ?? []).map((patient) => [patient.id, `${patient.full_name} (${patient.mr_number})`]));
  const dispensedByItem = new Map<string, number>();
  for (const dispense of dispenseResult.data ?? []) dispensedByItem.set(dispense.prescription_item_id, (dispensedByItem.get(dispense.prescription_item_id) ?? 0) + Number(dispense.quantity));
  const itemsByRx = new Map<string, PharmacyItem[]>();
  for (const item of (rxItemsResult.data ?? []) as PharmacyItem[]) {
    const rows = itemsByRx.get(item.prescription_id) ?? [];
    rows.push(item);
    itemsByRx.set(item.prescription_id, rows);
  }
  const canManageCatalog = ["super_admin", "admin"].includes(role);
  const canReceive = ["super_admin", "admin", "pharmacist", "accountant"].includes(role);
  const canDispense = ["super_admin", "admin", "pharmacist"].includes(role);

  return (
    <main className="patients-page pharmacy-page">
      <header className="patients-topbar"><Link className="patients-brand" href="/">✚ <b>cliniccare<span>pro</span></b></Link><nav><Link href="/">Overview</Link><span>/</span><strong>Pharmacy</strong></nav><div className="patients-user"><Link href="/">{String(claimsData.claims.email ?? "Clinic account")}</Link><form action={signOut}><button>Sign out</button></form></div></header>
      <div className="patients-content">
        <div className="patients-title-row"><div><p className="patients-eyebrow">OPERATIONS / PHARMACY</p><h1>Pharmacy</h1><p>{clinicResult.data?.name ?? "Your clinic"} · Inventory, lot tracking, and prescriptions</p></div><span className="appointment-count"><Pill size={15} /> {products.filter((product) => product.active).length} active products</span></div>
        {params.product && <div className="patient-alert success" role="status">Product added to the pharmacy catalog.</div>}
        {(params.received || params.dispensed) && <div className="patient-alert success" role="status">Pharmacy record saved successfully.</div>}
        {params.error && messages[params.error] && <div className="patient-alert error" role="alert">{messages[params.error]}</div>}

        <section className="patients-table-card">
          <div className="patients-table-heading"><div><h2>Current inventory</h2><p>Stock totals exclude expired lots. Lot and expiry details stay available below.</p></div><Boxes size={18} color="#377ae0" /></div>
          {productResult.error || lotResult.error ? <div className="patients-empty"><b>Unable to load pharmacy inventory</b><p>Check that the pharmacy migration is installed and your role has access.</p></div> : products.length ? <div className="patients-table-scroll"><table className="patients-table"><thead><tr><th>Product</th><th>Form</th><th>Available</th><th>Reorder at</th><th>Sale price</th><th>Stock lots</th></tr></thead><tbody>{products.map((product) => {
            const available = stockByProduct.get(product.id) ?? 0;
            const lots = (lotResult.data ?? []).filter((lot) => lot.product_id === product.id);
            return <tr key={product.id}><td><b>{product.name}</b><small>{[product.generic_name, product.strength, product.code].filter(Boolean).join(" · ")}</small></td><td>{product.dosage_form}</td><td className={available <= Number(product.reorder_level) ? "billing-due" : ""}>{available} {product.unit_label}{available <= Number(product.reorder_level) && <small>Reorder level reached</small>}</td><td>{product.reorder_level} {product.unit_label}</td><td>{money(product.sale_price)}</td><td>{lots.length ? lots.map((lot) => <small key={lot.id}>{lot.batch_number} · {lot.quantity_remaining} · exp {lot.expires_on}</small>) : <span className="not-available">No unexpired stock</span>}</td></tr>;
          })}</tbody></table></div> : <div className="patients-empty"><span><Pill size={18} /></span><b>No pharmacy products yet</b><p>Create a product in the catalog to begin tracking stock.</p></div>}
        </section>

        {canReceive && <section className="patient-form-card" id="receive">
          <div className="patient-form-heading"><span><PackagePlus size={17} /></span><div><h2>Receive stock</h2><p>Each receipt creates a tracked batch and stock movement. Dispensing uses first-expiring stock.</p></div></div>
          {products.some((product) => product.active) ? <form action={receiveStock} className="patient-form pharmacy-form">
            <label>Product *<select name="productId" required defaultValue=""><option value="" disabled>Select product</option>{products.filter((product) => product.active).map((product) => <option key={product.id} value={product.id}>{product.name} · {product.strength ?? product.code}</option>)}</select></label>
            <label>Batch number *<input name="batch" required maxLength={80} /></label>
            <label>Expiry date *<input name="expiry" type="date" min={new Date().toISOString().slice(0, 10)} required /></label>
            <label>Quantity *<input name="quantity" type="number" min="0.01" max="10000000" step="0.01" required /></label>
            <label>Purchase unit cost *<input name="unitCost" type="number" min="0" max="10000000" step="0.01" required /></label>
            <div className="patient-form-actions"><span>Expired lots cannot be dispensed.</span><button type="submit">Receive stock</button></div>
          </form> : <div className="patients-empty compact-empty"><b>Add a product first</b><p>Product catalog setup is available to clinic administrators.</p></div>}
        </section>}

        <section className="patients-table-card">
          <div className="patients-table-heading"><div><h2>Prescriptions awaiting dispense</h2><p>Latest active prescriptions; dispensing is recorded against the original clinician order.</p></div><ReceiptText size={18} color="#377ae0" /></div>
          {prescriptionResult.error || rxItemsResult.error ? <div className="patients-empty"><b>Unable to load prescriptions</b><p>Check pharmacy and prescription access policies.</p></div> : prescriptionResult.data?.length ? <div className="pharmacy-rx-list">{prescriptionResult.data.map((rx) => {
            return <article className="pharmacy-rx-card" key={rx.id}><header><div><b>{patientsById.get(rx.patient_id) ?? "Patient record"}</b><small>Dr. {doctorsById.get(rx.doctor_id) ?? "Clinic doctor"} · {new Intl.DateTimeFormat("en-PK", { dateStyle: "medium", timeZone: "Asia/Karachi" }).format(new Date(rx.prescribed_at))}</small></div><span className={`status-pill status-${rx.status}`}>{rx.status.replaceAll("_", " ")}</span></header>
              {(itemsByRx.get(rx.id) ?? []).map((item) => {
                const dispensed = dispensedByItem.get(item.id) ?? 0;
                const outstanding = Math.max(0, Number(item.quantity) - dispensed);
                return <div className="pharmacy-rx-item" key={item.id}><div><b>{item.product_name_snapshot} {item.strength_snapshot ?? ""}</b><small>{item.dose} · {item.frequency} · {item.duration_days} days · prescribed {item.quantity}</small>{item.instructions && <small>{item.instructions}</small>}<small>Dispensed {dispensed}; remaining {outstanding}</small></div>
                  {outstanding > 0 && canDispense && <form action={dispensePrescriptionItem}><input type="hidden" name="itemId" value={item.id} /><label>Qty<input type="number" name="quantity" min="0.01" max={outstanding} step="0.01" defaultValue={outstanding} required /></label><button type="submit">Dispense</button></form>}
                </div>;
              })}
            </article>;
          })}</div> : <div className="patients-empty"><span><ReceiptText size={18} /></span><b>No active prescriptions</b><p>Prescriptions written during a clinical encounter will show here.</p><Link href="/appointments">Go to appointments →</Link></div>}
        </section>

        {canManageCatalog && <section className="patient-form-card" id="catalog">
          <div className="patient-form-heading"><span><Pill size={17} /></span><div><h2>Product catalog</h2><p>Set product details, sale price, and low-stock threshold.</p></div></div>
          <form action={createProduct} className="patient-form pharmacy-form">
            <label>Code *<input name="code" required minLength={2} maxLength={40} pattern="[A-Za-z0-9._-]+" /></label><label>Name *<input name="name" required minLength={2} maxLength={160} /></label>
            <label>Generic name<input name="genericName" maxLength={160} /></label><label>Strength<input name="strength" maxLength={80} placeholder="e.g. 500 mg" /></label>
            <label>Dosage form *<input name="dosageForm" required minLength={2} maxLength={80} placeholder="Tablet, syrup..." /></label><label>Stock unit *<input name="unit" required defaultValue="unit" maxLength={30} /></label>
            <label>Sale price (PKR) *<input name="salePrice" type="number" min="0" max="1000000" step="0.01" required /></label><label>Reorder level *<input name="reorderLevel" type="number" min="0" max="100000000" step="0.01" required defaultValue="0" /></label>
            <div className="patient-form-actions"><span>Catalog changes do not rewrite existing prescriptions.</span><button type="submit">Add product</button></div>
          </form>
        </section>}
      </div>
    </main>
  );
}
