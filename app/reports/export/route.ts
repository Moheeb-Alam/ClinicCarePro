import { createClient } from "@/lib/supabase/server";

function validDate(value: string | null) {
  if (!value || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const date = new Date(`${value}T00:00:00.000Z`);
  return !Number.isNaN(date.getTime()) && date.toISOString().slice(0, 10) === value;
}

export async function GET(request: Request) {
  const supabase = await createClient();
  const { data: claims, error: claimsError } = await supabase.auth.getClaims();
  if (!claims?.claims || claimsError) return new Response("Unauthorized", { status: 401 });
  const userId = String(claims.claims.sub ?? "");
  const { data: membership } = await supabase.from("clinic_memberships").select("clinic_id, role")
    .eq("user_id", userId).eq("active", true).order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (!membership || !["super_admin", "admin", "accountant", "auditor"].includes(membership.role)) return new Response("Forbidden", { status: 403 });
  const url = new URL(request.url);
  const start = url.searchParams.get("start");
  const end = url.searchParams.get("end");
  if (!validDate(start) || !validDate(end) || start! > end! || Date.parse(`${end}T00:00:00Z`) - Date.parse(`${start}T00:00:00Z`) > 365 * 86400000) {
    return new Response("Invalid report date range", { status: 400 });
  }
  const [year, month, day] = end!.split("-").map(Number);
  const exclusiveEnd = new Date(Date.UTC(year, month - 1, day + 1)).toISOString().slice(0, 10);
  const { data, error } = await supabase.rpc("clinic_daily_financial_report", {
    target_clinic: membership.clinic_id, target_start: start!, target_end: exclusiveEnd,
  });
  if (error) return new Response("Report could not be generated", { status: 500 });
  const reportRows = (data ?? []) as { report_date: string; billed_amount: number | string; collected_amount: number | string; expense_amount: number | string }[];
  const rows = ["date,billed_amount_pkr,collected_amount_pkr,expenses_pkr,net_cash_pkr", ...reportRows.map((row) => `${row.report_date},${Number(row.billed_amount).toFixed(2)},${Number(row.collected_amount).toFixed(2)},${Number(row.expense_amount).toFixed(2)},${(Number(row.collected_amount) - Number(row.expense_amount)).toFixed(2)}`)];
  return new Response(rows.join("\r\n"), {
    headers: {
      "content-type": "text/csv; charset=utf-8",
      "content-disposition": `attachment; filename="clinic-finance-${start}-${end}.csv"`,
      "cache-control": "private, no-store",
    },
  });
}
