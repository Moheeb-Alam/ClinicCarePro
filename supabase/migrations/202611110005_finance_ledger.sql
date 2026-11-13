-- Billing and append-only double-entry ledger. Client input never supplies sale prices.

create type public.bill_item_kind as enum ('consultation', 'laboratory', 'imaging', 'pharmacy', 'service', 'other');
create type public.payment_method as enum ('cash', 'card', 'bank_transfer', 'online');
create type public.payment_entry_type as enum ('payment', 'reversal');

create table public.service_catalog (
  id uuid primary key default gen_random_uuid(),
  clinic_id uuid not null references public.clinics(id) on delete restrict,
  code text not null,
  name text not null check (length(trim(name)) between 2 and 160),
  kind public.bill_item_kind not null,
  unit_price numeric(12,2) not null check (unit_price >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (clinic_id, id),
  unique (clinic_id, code)
);

create table public.invoice_counters (
  clinic_id uuid not null references public.clinics(id) on delete restrict,
  invoice_year smallint not null,
  last_number bigint not null check (last_number > 0),
  primary key (clinic_id, invoice_year)
);
alter table public.invoice_counters enable row level security;
revoke all on public.invoice_counters from anon, authenticated;

create table public.bills (
  id uuid primary key default gen_random_uuid(),
  clinic_id uuid not null references public.clinics(id) on delete restrict,
  patient_id uuid not null,
  invoice_number text not null,
  issued_at timestamptz,
  issued_by uuid references public.profiles(id) on delete set null,
  created_by uuid not null references public.profiles(id) on delete restrict,
  notes text,
  created_at timestamptz not null default now(),
  foreign key (clinic_id, patient_id) references public.patients(clinic_id, id),
  unique (clinic_id, id),
  unique (clinic_id, invoice_number)
);
create index bills_clinic_date_idx on public.bills(clinic_id, created_at desc);
create index bills_patient_date_idx on public.bills(clinic_id, patient_id, created_at desc);

create table public.bill_items (
  id uuid primary key default gen_random_uuid(),
  clinic_id uuid not null,
  bill_id uuid not null,
  service_id uuid,
  kind public.bill_item_kind not null,
  description_snapshot text not null check (length(trim(description_snapshot)) between 1 and 200),
  quantity numeric(10,2) not null check (quantity > 0 and quantity <= 100000),
  unit_price_snapshot numeric(12,2) not null check (unit_price_snapshot >= 0),
  discount_amount numeric(12,2) not null default 0 check (discount_amount >= 0),
  tax_amount numeric(12,2) not null default 0 check (tax_amount >= 0),
  line_total numeric(14,2) generated always as (round(quantity * unit_price_snapshot - discount_amount + tax_amount, 2)) stored,
  created_at timestamptz not null default now(),
  foreign key (clinic_id, bill_id) references public.bills(clinic_id, id),
  foreign key (clinic_id, service_id) references public.service_catalog(clinic_id, id),
  unique (clinic_id, id),
  check (discount_amount <= quantity * unit_price_snapshot)
);
create index bill_items_bill_idx on public.bill_items(clinic_id, bill_id);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  clinic_id uuid not null,
  bill_id uuid not null,
  entry_type public.payment_entry_type not null,
  amount numeric(12,2) not null check (amount > 0),
  method public.payment_method not null,
  reference text,
  idempotency_key uuid not null,
  reverses_payment_id uuid,
  reason text,
  received_by uuid not null references public.profiles(id) on delete restrict,
  occurred_at timestamptz not null default now(),
  foreign key (clinic_id, bill_id) references public.bills(clinic_id, id),
  foreign key (clinic_id, reverses_payment_id) references public.payments(clinic_id, id),
  unique (clinic_id, id),
  unique (clinic_id, idempotency_key),
  unique (clinic_id, reverses_payment_id),
  check ((entry_type = 'payment' and reverses_payment_id is null and reason is null)
    or (entry_type = 'reversal' and reverses_payment_id is not null and length(trim(coalesce(reason, ''))) >= 5))
);
create index payments_bill_date_idx on public.payments(clinic_id, bill_id, occurred_at desc);

create table public.ledger_journals (
  id uuid primary key default gen_random_uuid(),
  clinic_id uuid not null references public.clinics(id) on delete restrict,
  source_type text not null check (source_type in ('payment', 'payment_reversal')),
  source_id uuid not null,
  actor_id uuid not null references public.profiles(id) on delete restrict,
  occurred_at timestamptz not null default now(),
  unique (clinic_id, id),
  unique (clinic_id, source_type, source_id)
);

create table public.ledger_entries (
  id bigint generated always as identity primary key,
  clinic_id uuid not null,
  journal_id uuid not null,
  account_code text not null check (account_code in ('cash', 'bank', 'accounts_receivable')),
  debit numeric(14,2) not null default 0 check (debit >= 0),
  credit numeric(14,2) not null default 0 check (credit >= 0),
  created_at timestamptz not null default now(),
  foreign key (clinic_id, journal_id) references public.ledger_journals(clinic_id, id),
  check ((debit > 0 and credit = 0) or (credit > 0 and debit = 0))
);
create index ledger_entries_clinic_account_idx on public.ledger_entries(clinic_id, account_code, created_at desc);

create table public.expenses (
  id uuid primary key default gen_random_uuid(),
  clinic_id uuid not null references public.clinics(id) on delete restrict,
  category text not null check (length(trim(category)) between 2 and 100),
  description text not null check (length(trim(description)) between 2 and 500),
  amount numeric(12,2) not null check (amount > 0),
  spent_at date not null,
  recorded_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (clinic_id, id)
);
create index expenses_clinic_date_idx on public.expenses(clinic_id, spent_at desc);

create or replace function public.guard_bill_item_mutation()
returns trigger language plpgsql set search_path = ''
as $$
declare issued timestamptz;
begin
  select b.issued_at into issued from public.bills b
  where b.clinic_id = coalesce(new.clinic_id, old.clinic_id)
    and b.id = coalesce(new.bill_id, old.bill_id) for update;
  if issued is not null then
    raise exception 'Issued bill items are immutable; use a financial adjustment.' using errcode = '23514';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;
create trigger bill_items_guard_mutation before update or delete on public.bill_items
for each row execute function public.guard_bill_item_mutation();

create or replace function public.reject_ledger_mutation()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  raise exception 'Financial ledger records are append-only; use a reversal or adjustment event.';
end;
$$;
create trigger payments_immutable before update or delete on public.payments
for each row execute function public.reject_ledger_mutation();
create trigger journals_immutable before update or delete on public.ledger_journals
for each row execute function public.reject_ledger_mutation();
create trigger ledger_entries_immutable before update or delete on public.ledger_entries
for each row execute function public.reject_ledger_mutation();

create or replace function public.create_bill(
  target_clinic uuid,
  target_patient uuid,
  target_service_ids uuid[],
  target_quantities numeric[],
  target_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := (select auth.uid());
  clinic_timezone text;
  invoice_year smallint;
  invoice_counter bigint;
  invoice_number text;
  created_bill uuid;
  service_count integer;
begin
  if not public.has_clinic_role(target_clinic, array['super_admin','admin','receptionist','accountant']::public.clinic_role[]) then
    raise exception 'Not authorized to create bills.' using errcode = '42501';
  end if;
  if target_service_ids is null or target_quantities is null or cardinality(target_service_ids) < 1
    or cardinality(target_service_ids) > 50 or cardinality(target_service_ids) <> cardinality(target_quantities)
    or cardinality(target_service_ids) <> (select count(distinct service_id) from unnest(target_service_ids) as items(service_id))
    or exists (select 1 from unnest(target_quantities) as quantities(quantity) where quantity <= 0 or quantity > 100000) then
    raise exception 'Bill items are invalid.' using errcode = '22023';
  end if;
  if not exists (select 1 from public.patients p where p.clinic_id = target_clinic and p.id = target_patient and p.archived_at is null) then
    raise exception 'Patient is unavailable in this clinic.' using errcode = '23503';
  end if;
  select c.timezone into clinic_timezone from public.clinics c where c.id = target_clinic and c.active;
  if clinic_timezone is null then raise exception 'Clinic is unavailable.' using errcode = '42501'; end if;
  select count(*) into service_count from public.service_catalog s
    where s.clinic_id = target_clinic and s.id = any(target_service_ids) and s.active;
  if service_count <> cardinality(target_service_ids) then raise exception 'One or more services are unavailable.' using errcode = '23503'; end if;

  invoice_year := extract(year from (now() at time zone clinic_timezone))::smallint;
  insert into public.invoice_counters (clinic_id, invoice_year, last_number)
  values (target_clinic, invoice_year, 1)
  on conflict (clinic_id, invoice_year) do update set last_number = public.invoice_counters.last_number + 1
  returning last_number into invoice_counter;
  invoice_number := 'INV-' || invoice_year::text || '-' || lpad(invoice_counter::text, 7, '0');
  insert into public.bills (clinic_id, patient_id, invoice_number, created_by, notes)
  values (target_clinic, target_patient, invoice_number, actor, nullif(left(trim(coalesce(target_notes, '')), 500), ''))
  returning id into created_bill;
  insert into public.bill_items (clinic_id, bill_id, service_id, kind, description_snapshot, quantity, unit_price_snapshot)
  select target_clinic, created_bill, s.id, s.kind, s.name, quantities.quantity, s.unit_price
  from public.service_catalog s
  join unnest(target_service_ids, target_quantities) as items(service_id, quantity) on items.service_id = s.id
  where s.clinic_id = target_clinic and s.active;
  return created_bill;
end;
$$;
revoke all on function public.create_bill(uuid, uuid, uuid[], numeric[], text) from public;
grant execute on function public.create_bill(uuid, uuid, uuid[], numeric[], text) to authenticated;

create or replace function public.issue_bill(target_bill uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  bill_row public.bills%rowtype;
  total_due numeric(14,2);
begin
  select b.* into bill_row from public.bills b where b.id = target_bill for update;
  if bill_row.id is null or not public.has_clinic_role(bill_row.clinic_id, array['super_admin','admin','accountant']::public.clinic_role[])
    then raise exception 'Accountant access required to issue a bill.' using errcode = '42501'; end if;
  if bill_row.issued_at is not null then raise exception 'Bill is already issued.' using errcode = '23514'; end if;
  select coalesce(sum(i.line_total), 0) into total_due from public.bill_items i
    where i.clinic_id = bill_row.clinic_id and i.bill_id = bill_row.id;
  if total_due <= 0 then raise exception 'A bill must contain a positive total.' using errcode = '23514'; end if;
  update public.bills set issued_at = now(), issued_by = (select auth.uid()) where id = bill_row.id;
end;
$$;
revoke all on function public.issue_bill(uuid) from public;
grant execute on function public.issue_bill(uuid) to authenticated;

create or replace function public.record_payment(
  target_bill uuid,
  target_amount numeric,
  target_method public.payment_method,
  target_idempotency_key uuid,
  target_reference text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  bill_row public.bills%rowtype;
  actor uuid := (select auth.uid());
  total_due numeric(14,2);
  net_paid numeric(14,2);
  payment_id uuid;
  journal_id uuid;
  cash_account text;
begin
  select b.* into bill_row from public.bills b where b.id = target_bill for update;
  if bill_row.id is null or not public.has_clinic_role(bill_row.clinic_id, array['super_admin','admin','receptionist','accountant']::public.clinic_role[])
    then raise exception 'Not authorized to accept payment.' using errcode = '42501'; end if;
  if bill_row.issued_at is null then raise exception 'Issue the bill before accepting payment.' using errcode = '23514'; end if;
  if target_amount is null or target_amount <= 0 or target_amount > 100000000 then raise exception 'Invalid payment amount.' using errcode = '22023'; end if;
  if exists (select 1 from public.payments p where p.clinic_id = bill_row.clinic_id and p.idempotency_key = target_idempotency_key) then
    select p.id into payment_id from public.payments p where p.clinic_id = bill_row.clinic_id
      and p.idempotency_key = target_idempotency_key and p.bill_id = bill_row.id
      and p.entry_type = 'payment' and p.amount = round(target_amount, 2) and p.method = target_method;
    if payment_id is null then raise exception 'Idempotency key was already used for a different payment.' using errcode = '23505'; end if;
    return payment_id;
  end if;
  select coalesce(sum(i.line_total), 0) into total_due from public.bill_items i
    where i.clinic_id = bill_row.clinic_id and i.bill_id = bill_row.id;
  select coalesce(sum(case when p.entry_type = 'payment' then p.amount else -p.amount end), 0)
    into net_paid from public.payments p where p.clinic_id = bill_row.clinic_id and p.bill_id = bill_row.id;
  if target_amount > total_due - net_paid then raise exception 'Payment exceeds the outstanding balance.' using errcode = '23514'; end if;

  insert into public.payments (clinic_id, bill_id, entry_type, amount, method, reference, idempotency_key, received_by)
  values (bill_row.clinic_id, bill_row.id, 'payment', round(target_amount, 2), target_method,
    nullif(left(trim(coalesce(target_reference, '')), 120), ''), target_idempotency_key, actor)
  returning id into payment_id;
  insert into public.ledger_journals (clinic_id, source_type, source_id, actor_id)
  values (bill_row.clinic_id, 'payment', payment_id, actor) returning id into journal_id;
  cash_account := case when target_method = 'cash' then 'cash' else 'bank' end;
  insert into public.ledger_entries (clinic_id, journal_id, account_code, debit, credit)
    values (bill_row.clinic_id, journal_id, cash_account, round(target_amount, 2), 0),
           (bill_row.clinic_id, journal_id, 'accounts_receivable', 0, round(target_amount, 2));
  return payment_id;
end;
$$;
revoke all on function public.record_payment(uuid, numeric, public.payment_method, uuid, text) from public;
grant execute on function public.record_payment(uuid, numeric, public.payment_method, uuid, text) to authenticated;

create or replace function public.reverse_payment(target_payment uuid, target_reason text, target_idempotency_key uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  original public.payments%rowtype;
  actor uuid := (select auth.uid());
  reversal_id uuid;
  journal_id uuid;
  cash_account text;
begin
  select p.* into original from public.payments p where p.id = target_payment for update;
  if original.id is null or original.entry_type <> 'payment'
    or not public.has_clinic_role(original.clinic_id, array['super_admin','admin','accountant']::public.clinic_role[]) then
    raise exception 'Accountant access required to reverse a payment.' using errcode = '42501';
  end if;
  if length(trim(coalesce(target_reason, ''))) < 5 then raise exception 'A reversal reason is required.' using errcode = '22023'; end if;
  if exists (select 1 from public.payments p where p.clinic_id = original.clinic_id and p.idempotency_key = target_idempotency_key) then
    select p.id into reversal_id from public.payments p where p.clinic_id = original.clinic_id
      and p.idempotency_key = target_idempotency_key and p.entry_type = 'reversal'
      and p.reverses_payment_id = original.id;
    if reversal_id is null then raise exception 'Idempotency key was already used for a different payment event.' using errcode = '23505'; end if;
    return reversal_id;
  end if;
  if exists (select 1 from public.payments p where p.clinic_id = original.clinic_id and p.reverses_payment_id = original.id) then
    raise exception 'This payment was already reversed.' using errcode = '23505';
  end if;
  insert into public.payments (clinic_id, bill_id, entry_type, amount, method, idempotency_key, reverses_payment_id, reason, received_by)
  values (original.clinic_id, original.bill_id, 'reversal', original.amount, original.method,
    target_idempotency_key, original.id, left(trim(target_reason), 500), actor)
  returning id into reversal_id;
  insert into public.ledger_journals (clinic_id, source_type, source_id, actor_id)
  values (original.clinic_id, 'payment_reversal', reversal_id, actor) returning id into journal_id;
  cash_account := case when original.method = 'cash' then 'cash' else 'bank' end;
  insert into public.ledger_entries (clinic_id, journal_id, account_code, debit, credit)
    values (original.clinic_id, journal_id, 'accounts_receivable', original.amount, 0),
           (original.clinic_id, journal_id, cash_account, 0, original.amount);
  return reversal_id;
end;
$$;
revoke all on function public.reverse_payment(uuid, text, uuid) from public;
grant execute on function public.reverse_payment(uuid, text, uuid) to authenticated;

create view public.bill_balances with (security_invoker = true) as
select b.id, b.clinic_id, b.patient_id, b.invoice_number, b.issued_at, b.created_at,
  coalesce(items.total, 0)::numeric(14,2) as total_amount,
  coalesce(payments.paid, 0)::numeric(14,2) as amount_paid,
  (coalesce(items.total, 0) - coalesce(payments.paid, 0))::numeric(14,2) as balance_due,
  case when b.issued_at is null then 'draft'
    when coalesce(items.total, 0) <= coalesce(payments.paid, 0) then 'paid'
    when coalesce(payments.paid, 0) > 0 then 'partially_paid'
    else 'unpaid' end as status
from public.bills b
left join lateral (select sum(i.line_total) as total from public.bill_items i where i.clinic_id = b.clinic_id and i.bill_id = b.id) items on true
left join lateral (select sum(case when p.entry_type = 'payment' then p.amount else -p.amount end) as paid
  from public.payments p where p.clinic_id = b.clinic_id and p.bill_id = b.id) payments on true;

alter table public.service_catalog enable row level security;
alter table public.bills enable row level security;
alter table public.bill_items enable row level security;
alter table public.payments enable row level security;
alter table public.ledger_journals enable row level security;
alter table public.ledger_entries enable row level security;
alter table public.expenses enable row level security;

create policy service_catalog_read on public.service_catalog for select to authenticated using (public.has_clinic_role(clinic_id));
create policy service_catalog_admin_write on public.service_catalog for all to authenticated
  using (public.has_clinic_role(clinic_id, array['super_admin','admin']::public.clinic_role[]))
  with check (public.has_clinic_role(clinic_id, array['super_admin','admin']::public.clinic_role[]));
create policy bills_finance_read on public.bills for select to authenticated
  using (public.has_clinic_role(clinic_id, array['super_admin','admin','receptionist','accountant','auditor']::public.clinic_role[]));
create policy bill_items_finance_read on public.bill_items for select to authenticated
  using (public.has_clinic_role(clinic_id, array['super_admin','admin','receptionist','accountant','auditor']::public.clinic_role[]));
create policy payments_finance_read on public.payments for select to authenticated
  using (public.has_clinic_role(clinic_id, array['super_admin','admin','receptionist','accountant','auditor']::public.clinic_role[]));
create policy journals_finance_read on public.ledger_journals for select to authenticated
  using (public.has_clinic_role(clinic_id, array['super_admin','admin','accountant','auditor']::public.clinic_role[]));
create policy entries_finance_read on public.ledger_entries for select to authenticated
  using (public.has_clinic_role(clinic_id, array['super_admin','admin','accountant','auditor']::public.clinic_role[]));
create policy expenses_finance_read on public.expenses for select to authenticated
  using (public.has_clinic_role(clinic_id, array['super_admin','admin','accountant','auditor']::public.clinic_role[]));
create policy expenses_finance_insert on public.expenses for insert to authenticated
  with check (recorded_by = (select auth.uid()) and public.has_clinic_role(clinic_id, array['super_admin','admin','accountant']::public.clinic_role[]));

revoke all on public.service_catalog, public.bills, public.bill_items, public.payments,
  public.ledger_journals, public.ledger_entries, public.expenses, public.bill_balances from anon, authenticated;
grant select on public.service_catalog, public.bills, public.bill_items, public.payments,
  public.ledger_journals, public.ledger_entries, public.expenses, public.bill_balances to authenticated;
grant insert, update on public.service_catalog to authenticated;
grant insert on public.expenses to authenticated;

create trigger service_catalog_set_updated_at before update on public.service_catalog
for each row execute function public.set_updated_at();
create trigger service_catalog_audit_change after insert or update or delete on public.service_catalog
for each row execute function public.audit_row_change();
create trigger bills_audit_change after insert or update or delete on public.bills
for each row execute function public.audit_row_change();
create trigger bill_items_audit_change after insert or update or delete on public.bill_items
for each row execute function public.audit_row_change();
create trigger payments_audit_change after insert or update or delete on public.payments
for each row execute function public.audit_row_change();
create trigger ledger_journals_audit_change after insert or update or delete on public.ledger_journals
for each row execute function public.audit_row_change();
create trigger ledger_entries_audit_change after insert or update or delete on public.ledger_entries
for each row execute function public.audit_row_change();
create trigger expenses_audit_change after insert or update or delete on public.expenses
for each row execute function public.audit_row_change();
