-- Pharmacy catalog, lot-based inventory, prescriptions, and auditable dispensing.

create type public.prescription_status as enum ('active', 'partially_dispensed', 'dispensed', 'cancelled');

create table public.pharmacy_products (
  id uuid primary key default gen_random_uuid(),
  clinic_id uuid not null references public.clinics(id) on delete restrict,
  code text not null,
  name text not null check (length(trim(name)) between 2 and 160),
  generic_name text,
  strength text,
  dosage_form text not null check (length(trim(dosage_form)) between 2 and 80),
  unit_label text not null default 'unit' check (length(trim(unit_label)) between 1 and 30),
  sale_price numeric(12,2) not null default 0 check (sale_price >= 0),
  reorder_level numeric(12,2) not null default 0 check (reorder_level >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (clinic_id, id),
  unique (clinic_id, code)
);
create index pharmacy_products_name_idx on public.pharmacy_products(clinic_id, name) where active;

create table public.pharmacy_stock_lots (
  id uuid primary key default gen_random_uuid(),
  clinic_id uuid not null,
  product_id uuid not null,
  batch_number text not null,
  expires_on date not null,
  quantity_received numeric(12,2) not null check (quantity_received > 0),
  quantity_remaining numeric(12,2) not null check (quantity_remaining >= 0 and quantity_remaining <= quantity_received),
  purchase_unit_cost numeric(12,2) not null check (purchase_unit_cost >= 0),
  received_by uuid not null references public.profiles(id) on delete restrict,
  received_at timestamptz not null default now(),
  foreign key (clinic_id, product_id) references public.pharmacy_products(clinic_id, id),
  unique (clinic_id, id),
  unique (clinic_id, product_id, batch_number, expires_on)
);
create index pharmacy_lots_fefo_idx on public.pharmacy_stock_lots(clinic_id, product_id, expires_on, received_at) where quantity_remaining > 0;

create table public.prescriptions (
  id uuid primary key default gen_random_uuid(),
  clinic_id uuid not null,
  encounter_id uuid not null,
  patient_id uuid not null,
  doctor_id uuid not null,
  status public.prescription_status not null default 'active',
  prescribed_by uuid not null references public.profiles(id) on delete restrict,
  prescribed_at timestamptz not null default now(),
  foreign key (clinic_id, encounter_id) references public.encounters(clinic_id, id),
  foreign key (clinic_id, patient_id) references public.patients(clinic_id, id),
  foreign key (clinic_id, doctor_id) references public.doctors(clinic_id, id),
  unique (clinic_id, id)
);
create index prescriptions_patient_date_idx on public.prescriptions(clinic_id, patient_id, prescribed_at desc);

create table public.prescription_items (
  id uuid primary key default gen_random_uuid(),
  clinic_id uuid not null,
  prescription_id uuid not null,
  product_id uuid not null,
  product_name_snapshot text not null,
  strength_snapshot text,
  dosage_form_snapshot text not null,
  dose text not null check (length(trim(dose)) between 1 and 120),
  frequency text not null check (length(trim(frequency)) between 1 and 120),
  duration_days smallint not null check (duration_days between 1 and 365),
  quantity numeric(12,2) not null check (quantity > 0),
  instructions text,
  created_at timestamptz not null default now(),
  foreign key (clinic_id, prescription_id) references public.prescriptions(clinic_id, id),
  foreign key (clinic_id, product_id) references public.pharmacy_products(clinic_id, id),
  unique (clinic_id, id)
);
create index prescription_items_rx_idx on public.prescription_items(clinic_id, prescription_id);

create table public.pharmacy_dispenses (
  id uuid primary key default gen_random_uuid(),
  clinic_id uuid not null,
  prescription_item_id uuid not null,
  quantity numeric(12,2) not null check (quantity > 0),
  idempotency_key uuid not null,
  dispensed_by uuid not null references public.profiles(id) on delete restrict,
  dispensed_at timestamptz not null default now(),
  foreign key (clinic_id, prescription_item_id) references public.prescription_items(clinic_id, id),
  unique (clinic_id, id),
  unique (clinic_id, idempotency_key)
);

create table public.pharmacy_stock_movements (
  id uuid primary key default gen_random_uuid(),
  clinic_id uuid not null,
  product_id uuid not null,
  lot_id uuid,
  movement_type text not null check (movement_type in ('receipt', 'dispense')),
  quantity numeric(12,2) not null check (quantity > 0),
  source_id uuid not null,
  actor_id uuid not null references public.profiles(id) on delete restrict,
  occurred_at timestamptz not null default now(),
  foreign key (clinic_id, product_id) references public.pharmacy_products(clinic_id, id),
  foreign key (clinic_id, lot_id) references public.pharmacy_stock_lots(clinic_id, id),
  check ((movement_type = 'receipt' and lot_id is not null) or movement_type = 'dispense'),
  unique (clinic_id, id)
);
create index pharmacy_movements_date_idx on public.pharmacy_stock_movements(clinic_id, occurred_at desc);

create or replace function public.create_prescription(target_encounter uuid, target_items jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  encounter_row public.encounters%rowtype;
  actor uuid := (select auth.uid());
  created_prescription uuid;
  item jsonb;
  product_row public.pharmacy_products%rowtype;
begin
  select e.* into encounter_row from public.encounters e where e.id = target_encounter for update;
  if encounter_row.id is null or encounter_row.finalized_at is not null
    or not public.has_clinic_role(encounter_row.clinic_id, array['super_admin','doctor']::public.clinic_role[]) then
    raise exception 'An active clinical encounter and clinician access are required.' using errcode = '42501';
  end if;
  if public.has_clinic_role(encounter_row.clinic_id, array['doctor']::public.clinic_role[])
    and not exists (select 1 from public.doctors d where d.clinic_id = encounter_row.clinic_id and d.id = encounter_row.doctor_id and d.profile_id = actor) then
    raise exception 'Only the assigned doctor can prescribe for this encounter.' using errcode = '42501';
  end if;
  if target_items is null or jsonb_typeof(target_items) <> 'array' or jsonb_array_length(target_items) not between 1 and 30 then
    raise exception 'Prescription items are invalid.' using errcode = '22023';
  end if;
  insert into public.prescriptions (clinic_id, encounter_id, patient_id, doctor_id, prescribed_by)
  values (encounter_row.clinic_id, encounter_row.id, encounter_row.patient_id, encounter_row.doctor_id, actor)
  returning id into created_prescription;
  for item in select value from jsonb_array_elements(target_items) loop
    if (item->>'product_id') is null or (item->>'duration_days') is null or (item->>'quantity') is null
      or (item->>'duration_days') !~ '^[0-9]{1,3}$'
      or (item->>'quantity') !~ '^[0-9]+(\.[0-9]{1,2})?$'
      or length(trim(coalesce(item->>'dose', ''))) not between 1 and 120
      or length(trim(coalesce(item->>'frequency', ''))) not between 1 and 120 then
      raise exception 'Prescription item details are invalid.' using errcode = '22023';
    end if;
    select p.* into product_row from public.pharmacy_products p
      where p.clinic_id = encounter_row.clinic_id and p.id = (item->>'product_id')::uuid and p.active;
    if product_row.id is null then raise exception 'A prescribed product is unavailable.' using errcode = '23503'; end if;
    insert into public.prescription_items (clinic_id, prescription_id, product_id, product_name_snapshot,
      strength_snapshot, dosage_form_snapshot, dose, frequency, duration_days, quantity, instructions)
    values (encounter_row.clinic_id, created_prescription, product_row.id, product_row.name,
      product_row.strength, product_row.dosage_form, trim(item->>'dose'), trim(item->>'frequency'),
      (item->>'duration_days')::smallint, (item->>'quantity')::numeric,
      nullif(left(trim(coalesce(item->>'instructions', '')), 500), ''));
  end loop;
  return created_prescription;
end;
$$;
revoke all on function public.create_prescription(uuid, jsonb) from public;
grant execute on function public.create_prescription(uuid, jsonb) to authenticated;

create or replace function public.receive_pharmacy_stock(target_clinic uuid, target_product uuid,
  target_batch text, target_expiry date, target_quantity numeric, target_unit_cost numeric)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := (select auth.uid());
  lot_id uuid;
begin
  if not public.has_clinic_role(target_clinic, array['super_admin','admin','pharmacist','accountant']::public.clinic_role[])
    or target_quantity is null or target_quantity <= 0 or target_quantity > 10000000
    or target_unit_cost is null or target_unit_cost < 0 or target_unit_cost > 10000000
    or length(trim(coalesce(target_batch, ''))) not between 1 and 80 or target_expiry < current_date then
    raise exception 'Stock receipt is invalid or not authorized.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.pharmacy_products p where p.clinic_id = target_clinic and p.id = target_product and p.active) then
    raise exception 'Product is unavailable.' using errcode = '23503';
  end if;
  insert into public.pharmacy_stock_lots (clinic_id, product_id, batch_number, expires_on,
    quantity_received, quantity_remaining, purchase_unit_cost, received_by)
  values (target_clinic, target_product, trim(target_batch), target_expiry,
    target_quantity, target_quantity, target_unit_cost, actor)
  returning id into lot_id;
  insert into public.pharmacy_stock_movements (clinic_id, product_id, lot_id, movement_type, quantity, source_id, actor_id)
  values (target_clinic, target_product, lot_id, 'receipt', target_quantity, lot_id, actor);
  return lot_id;
end;
$$;
revoke all on function public.receive_pharmacy_stock(uuid, uuid, text, date, numeric, numeric) from public;
grant execute on function public.receive_pharmacy_stock(uuid, uuid, text, date, numeric, numeric) to authenticated;

create or replace function public.dispense_prescription_item(target_item uuid, target_quantity numeric, target_idempotency_key uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  item_row public.prescription_items%rowtype;
  actor uuid := (select auth.uid());
  dispensed_before numeric(12,2);
  remaining numeric(12,2);
  dispense_id uuid;
  lot_row record;
  take_quantity numeric(12,2);
begin
  select i.* into item_row from public.prescription_items i where i.id = target_item for update;
  if item_row.id is null or not public.has_clinic_role(item_row.clinic_id, array['super_admin','admin','pharmacist']::public.clinic_role[])
    or target_quantity is null or target_quantity <= 0 then
    raise exception 'Dispense request is invalid or not authorized.' using errcode = '42501';
  end if;
  if exists (select 1 from public.pharmacy_dispenses d where d.clinic_id = item_row.clinic_id and d.idempotency_key = target_idempotency_key) then
    select d.id into dispense_id from public.pharmacy_dispenses d where d.clinic_id = item_row.clinic_id
      and d.idempotency_key = target_idempotency_key and d.prescription_item_id = item_row.id and d.quantity = target_quantity;
    if dispense_id is null then raise exception 'Idempotency key was used for a different dispense.' using errcode = '23505'; end if;
    return dispense_id;
  end if;
  if not exists (select 1 from public.prescriptions r where r.clinic_id = item_row.clinic_id and r.id = item_row.prescription_id and r.status in ('active','partially_dispensed')) then
    raise exception 'Prescription is not active.' using errcode = '23514';
  end if;
  select coalesce(sum(d.quantity), 0) into dispensed_before from public.pharmacy_dispenses d
    where d.clinic_id = item_row.clinic_id and d.prescription_item_id = item_row.id;
  remaining := item_row.quantity - dispensed_before;
  if target_quantity > remaining then raise exception 'Dispense exceeds the prescribed remaining quantity.' using errcode = '23514'; end if;
  insert into public.pharmacy_dispenses (clinic_id, prescription_item_id, quantity, idempotency_key, dispensed_by)
  values (item_row.clinic_id, item_row.id, target_quantity, target_idempotency_key, actor) returning id into dispense_id;
  remaining := target_quantity;
  for lot_row in select l.* from public.pharmacy_stock_lots l
    where l.clinic_id = item_row.clinic_id and l.product_id = item_row.product_id
      and l.quantity_remaining > 0 and l.expires_on >= current_date
    order by l.expires_on, l.received_at for update
  loop
    exit when remaining <= 0;
    take_quantity := least(remaining, lot_row.quantity_remaining);
    update public.pharmacy_stock_lots set quantity_remaining = quantity_remaining - take_quantity where id = lot_row.id;
    insert into public.pharmacy_stock_movements (clinic_id, product_id, lot_id, movement_type, quantity, source_id, actor_id)
    values (item_row.clinic_id, item_row.product_id, lot_row.id, 'dispense', take_quantity, dispense_id, actor);
    remaining := remaining - take_quantity;
  end loop;
  if remaining > 0 then raise exception 'Insufficient unexpired stock.' using errcode = '23514'; end if;
  update public.prescriptions r set status = case
    when not exists (select 1 from public.prescription_items i where i.clinic_id = r.clinic_id and i.prescription_id = r.id
      and i.quantity > coalesce((select sum(d.quantity) from public.pharmacy_dispenses d where d.clinic_id = i.clinic_id and d.prescription_item_id = i.id), 0))
      then 'dispensed'::public.prescription_status else 'partially_dispensed'::public.prescription_status end
    where r.clinic_id = item_row.clinic_id and r.id = item_row.prescription_id;
  return dispense_id;
end;
$$;
revoke all on function public.dispense_prescription_item(uuid, numeric, uuid) from public;
grant execute on function public.dispense_prescription_item(uuid, numeric, uuid) to authenticated;

alter table public.pharmacy_products enable row level security;
alter table public.pharmacy_stock_lots enable row level security;
alter table public.prescriptions enable row level security;
alter table public.prescription_items enable row level security;
alter table public.pharmacy_dispenses enable row level security;
alter table public.pharmacy_stock_movements enable row level security;

create policy pharmacy_catalog_read on public.pharmacy_products for select to authenticated using (public.has_clinic_role(clinic_id));
create policy pharmacy_catalog_admin_write on public.pharmacy_products for all to authenticated
  using (public.has_clinic_role(clinic_id, array['super_admin','admin']::public.clinic_role[]))
  with check (public.has_clinic_role(clinic_id, array['super_admin','admin']::public.clinic_role[]));
create policy pharmacy_stock_read on public.pharmacy_stock_lots for select to authenticated
  using (public.has_clinic_role(clinic_id, array['super_admin','admin','pharmacist','accountant','auditor']::public.clinic_role[]));
create policy prescriptions_staff_read on public.prescriptions for select to authenticated
  using (public.has_clinic_role(clinic_id, array['super_admin','admin','pharmacist','auditor']::public.clinic_role[]));
create policy prescriptions_assigned_doctor_read on public.prescriptions for select to authenticated
  using (public.has_clinic_role(clinic_id, array['doctor']::public.clinic_role[]) and exists (
    select 1 from public.doctors d where d.clinic_id = prescriptions.clinic_id
      and d.id = prescriptions.doctor_id and d.profile_id = (select auth.uid())
  ));
create policy prescription_items_staff_read on public.prescription_items for select to authenticated
  using (public.has_clinic_role(clinic_id, array['super_admin','admin','pharmacist','auditor']::public.clinic_role[]));
create policy prescription_items_assigned_doctor_read on public.prescription_items for select to authenticated
  using (public.has_clinic_role(clinic_id, array['doctor']::public.clinic_role[]) and exists (
    select 1 from public.prescriptions r join public.doctors d
      on d.clinic_id = r.clinic_id and d.id = r.doctor_id
    where r.clinic_id = prescription_items.clinic_id and r.id = prescription_items.prescription_id
      and d.profile_id = (select auth.uid())
  ));
create policy pharmacy_dispenses_read on public.pharmacy_dispenses for select to authenticated
  using (public.has_clinic_role(clinic_id, array['super_admin','admin','pharmacist','accountant','auditor']::public.clinic_role[]));
create policy pharmacy_movements_read on public.pharmacy_stock_movements for select to authenticated
  using (public.has_clinic_role(clinic_id, array['super_admin','admin','pharmacist','accountant','auditor']::public.clinic_role[]));

revoke all on public.pharmacy_products, public.pharmacy_stock_lots, public.prescriptions,
  public.prescription_items, public.pharmacy_dispenses, public.pharmacy_stock_movements from anon, authenticated;
grant select on public.pharmacy_products, public.pharmacy_stock_lots, public.prescriptions,
  public.prescription_items, public.pharmacy_dispenses, public.pharmacy_stock_movements to authenticated;
grant insert on public.pharmacy_products to authenticated;
revoke update on public.pharmacy_products from anon, authenticated;
grant update (code, name, generic_name, strength, dosage_form, unit_label, sale_price, reorder_level, active)
  on public.pharmacy_products to authenticated;

create policy patient_pharmacy_read on public.patients for select to authenticated
  using (public.has_clinic_role(clinic_id, array['pharmacist']::public.clinic_role[]));

create trigger pharmacy_products_set_updated_at before update on public.pharmacy_products
for each row execute function public.set_updated_at();
create trigger pharmacy_products_audit after insert or update or delete on public.pharmacy_products
for each row execute function public.audit_row_change();
create trigger pharmacy_lots_audit after insert on public.pharmacy_stock_lots
for each row execute function public.audit_row_change();
create trigger prescriptions_audit after insert or update on public.prescriptions
for each row execute function public.audit_row_change();
create trigger prescription_items_audit after insert on public.prescription_items
for each row execute function public.audit_row_change();
create trigger pharmacy_dispenses_audit after insert on public.pharmacy_dispenses
for each row execute function public.audit_row_change();
create trigger pharmacy_movements_audit after insert on public.pharmacy_stock_movements
for each row execute function public.audit_row_change();
