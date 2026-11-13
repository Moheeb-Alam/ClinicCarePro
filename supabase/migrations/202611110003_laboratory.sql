-- Laboratory catalog, orders, specimen chain-of-custody, and versioned results.

create type public.lab_order_status as enum (
  'ordered', 'sample_collected', 'processing', 'completed', 'verified', 'delivered', 'cancelled'
);
create type public.lab_item_status as enum (
  'ordered', 'sample_collected', 'processing', 'completed', 'verified', 'delivered', 'cancelled'
);
create type public.lab_sample_status as enum ('awaiting_collection', 'collected', 'processing', 'rejected', 'completed');
create type public.lab_verification_level as enum ('technician_verified', 'doctor_verified', 'rejected');

create table public.lab_categories (
  id uuid primary key default gen_random_uuid(),
  clinic_id uuid not null references public.clinics(id) on delete restrict,
  name text not null check (length(trim(name)) between 2 and 100),
  sort_order smallint not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (clinic_id, id),
  unique (clinic_id, name)
);

create table public.lab_tests (
  id uuid primary key default gen_random_uuid(),
  clinic_id uuid not null references public.clinics(id) on delete restrict,
  category_id uuid not null,
  code text not null,
  name text not null check (length(trim(name)) between 2 and 160),
  description text,
  price numeric(12,2) not null default 0 check (price >= 0),
  turnaround_minutes integer check (turnaround_minutes is null or turnaround_minutes between 1 and 43200),
  result_schema jsonb not null default '[]'::jsonb check (jsonb_typeof(result_schema) = 'array'),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (clinic_id, category_id) references public.lab_categories(clinic_id, id),
  unique (clinic_id, id),
  unique (clinic_id, code)
);
create index lab_tests_catalog_idx on public.lab_tests(clinic_id, category_id, name) where active;

create table public.lab_orders (
  id uuid primary key default gen_random_uuid(),
  clinic_id uuid not null references public.clinics(id) on delete restrict,
  patient_id uuid not null,
  ordered_by_doctor_id uuid not null,
  created_by uuid references public.profiles(id) on delete set null,
  priority text not null default 'routine' check (priority in ('routine', 'urgent', 'stat')),
  status public.lab_order_status not null default 'ordered',
  clinical_notes text,
  ordered_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (clinic_id, patient_id) references public.patients(clinic_id, id),
  foreign key (clinic_id, ordered_by_doctor_id) references public.doctors(clinic_id, id),
  unique (clinic_id, id)
);
create index lab_orders_clinic_time_idx on public.lab_orders(clinic_id, ordered_at desc, status);
create index lab_orders_patient_idx on public.lab_orders(clinic_id, patient_id, ordered_at desc);

create table public.lab_order_items (
  id uuid primary key default gen_random_uuid(),
  clinic_id uuid not null,
  order_id uuid not null,
  test_id uuid not null,
  test_name_snapshot text not null,
  price_snapshot numeric(12,2) not null check (price_snapshot >= 0),
  status public.lab_item_status not null default 'ordered',
  assigned_technician_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  foreign key (clinic_id, order_id) references public.lab_orders(clinic_id, id),
  foreign key (clinic_id, test_id) references public.lab_tests(clinic_id, id),
  unique (clinic_id, id),
  unique (clinic_id, order_id, test_id)
);
create index lab_order_items_status_idx on public.lab_order_items(clinic_id, status, created_at desc);

create table public.lab_samples (
  id uuid primary key default gen_random_uuid(),
  clinic_id uuid not null,
  order_item_id uuid not null,
  sample_number text not null,
  sample_type text,
  status public.lab_sample_status not null default 'awaiting_collection',
  collected_by uuid references public.profiles(id) on delete set null,
  collected_at timestamptz,
  rejected_by uuid references public.profiles(id) on delete set null,
  rejected_at timestamptz,
  rejection_reason text,
  created_at timestamptz not null default now(),
  foreign key (clinic_id, order_item_id) references public.lab_order_items(clinic_id, id),
  unique (clinic_id, id),
  unique (clinic_id, sample_number),
  check ((status <> 'rejected') or (rejection_reason is not null and length(trim(rejection_reason)) > 0))
);
create index lab_samples_item_idx on public.lab_samples(clinic_id, order_item_id, created_at desc);

-- Each correction is a new result version. A verified version cannot be silently changed.
create table public.lab_results (
  id uuid primary key default gen_random_uuid(),
  clinic_id uuid not null,
  order_item_id uuid not null,
  version integer not null check (version > 0),
  result_values jsonb not null check (jsonb_typeof(result_values) = 'object'),
  reference_snapshot jsonb not null default '{}'::jsonb check (jsonb_typeof(reference_snapshot) = 'object'),
  abnormal_fields text[] not null default '{}',
  critical boolean not null default false,
  entered_by uuid not null references public.profiles(id) on delete restrict,
  entered_at timestamptz not null default now(),
  correction_reason text,
  supersedes_result_id uuid,
  foreign key (clinic_id, order_item_id) references public.lab_order_items(clinic_id, id),
  foreign key (clinic_id, supersedes_result_id) references public.lab_results(clinic_id, id),
  unique (clinic_id, id),
  unique (clinic_id, order_item_id, version),
  check ((version = 1 and supersedes_result_id is null) or
         (version > 1 and supersedes_result_id is not null and length(trim(coalesce(correction_reason, ''))) > 0))
);
create index lab_results_item_version_idx on public.lab_results(clinic_id, order_item_id, version desc);

create table public.lab_result_verifications (
  id uuid primary key default gen_random_uuid(),
  clinic_id uuid not null,
  result_id uuid not null,
  level public.lab_verification_level not null,
  verified_by uuid not null references public.profiles(id) on delete restrict,
  notes text,
  verified_at timestamptz not null default now(),
  foreign key (clinic_id, result_id) references public.lab_results(clinic_id, id),
  unique (clinic_id, id),
  unique (clinic_id, result_id, level)
);
create index lab_verifications_result_idx on public.lab_result_verifications(clinic_id, result_id, verified_at);

create or replace function public.reject_verified_lab_mutation()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  raise exception 'Lab result versions are immutable; add a corrected version instead.';
end;
$$;
create trigger lab_results_immutable
before update or delete on public.lab_results
for each row execute function public.reject_verified_lab_mutation();
create trigger lab_verifications_immutable
before update or delete on public.lab_result_verifications
for each row execute function public.reject_verified_lab_mutation();

create or replace function public.validate_lab_result_version()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  previous_version integer;
  previous_item uuid;
begin
  if new.version = 1 then return new; end if;
  select r.version, r.order_item_id into previous_version, previous_item
  from public.lab_results r where r.clinic_id = new.clinic_id and r.id = new.supersedes_result_id;
  if previous_version is null or previous_item <> new.order_item_id or previous_version + 1 <> new.version then
    raise exception 'A corrected result must supersede the prior version of the same ordered test.' using errcode = '23514';
  end if;
  return new;
end;
$$;
create trigger lab_results_validate_version before insert on public.lab_results
for each row execute function public.validate_lab_result_version();

create or replace function public.create_lab_order(
  target_clinic uuid,
  target_patient uuid,
  target_doctor uuid,
  target_test_ids uuid[],
  target_priority text default 'routine',
  target_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := (select auth.uid());
  actor_role public.clinic_role;
  created_order uuid;
  selected_count integer;
begin
  select m.role into actor_role from public.clinic_memberships m
  where m.clinic_id = target_clinic and m.user_id = actor and m.active limit 1;
  if actor_role not in ('super_admin', 'admin', 'receptionist', 'doctor')
     or not public.has_clinic_role(target_clinic, array['super_admin','admin','receptionist','doctor']::public.clinic_role[]) then
    raise exception 'Not authorized to create lab orders.' using errcode = '42501';
  end if;
  if target_priority not in ('routine', 'urgent', 'stat') then
    raise exception 'Invalid order priority.' using errcode = '22023';
  end if;
  if target_test_ids is null or cardinality(target_test_ids) < 1 or cardinality(target_test_ids) > 20
     or cardinality(target_test_ids) <> (select count(distinct test_id) from unnest(target_test_ids) as items(test_id)) then
    raise exception 'Select between one and twenty distinct tests.' using errcode = '22023';
  end if;
  if actor_role = 'doctor' and not exists (
    select 1 from public.doctors d where d.clinic_id = target_clinic
      and d.id = target_doctor and d.profile_id = actor and d.active
  ) then
    raise exception 'Doctors may only order under their own clinical identity.' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.doctors d
    where d.clinic_id = target_clinic and d.id = target_doctor and d.active
  ) then
    raise exception 'An active doctor is required for a lab order.' using errcode = '23503';
  end if;
  if not exists (select 1 from public.patients p where p.clinic_id = target_clinic and p.id = target_patient and p.archived_at is null) then
    raise exception 'Patient is unavailable in this clinic.' using errcode = '23503';
  end if;
  select count(*) into selected_count from public.lab_tests t
    where t.clinic_id = target_clinic and t.id = any(target_test_ids) and t.active;
  if selected_count <> cardinality(target_test_ids) then
    raise exception 'One or more tests are unavailable.' using errcode = '23503';
  end if;

  insert into public.lab_orders (clinic_id, patient_id, ordered_by_doctor_id, created_by, priority, clinical_notes)
  values (target_clinic, target_patient, target_doctor, actor, target_priority, nullif(left(trim(coalesce(target_notes, '')), 500), ''))
  returning id into created_order;
  insert into public.lab_order_items (clinic_id, order_id, test_id, test_name_snapshot, price_snapshot)
  select target_clinic, created_order, t.id, t.name, t.price
    from public.lab_tests t where t.clinic_id = target_clinic and t.id = any(target_test_ids) and t.active;
  return created_order;
end;
$$;
revoke all on function public.create_lab_order(uuid, uuid, uuid, uuid[], text, text) from public;
grant execute on function public.create_lab_order(uuid, uuid, uuid, uuid[], text, text) to authenticated;

create or replace function public.transition_lab_item_status(target_item uuid, target_status public.lab_item_status)
returns public.lab_item_status
language plpgsql
security definer
set search_path = ''
as $$
declare
  item_row public.lab_order_items%rowtype;
  actor uuid := (select auth.uid());
  actor_role public.clinic_role;
  latest_result uuid;
  total_items integer;
  active_items integer;
  delivered_items integer;
  verified_items integer;
  completed_items integer;
  processing_items integer;
  collected_items integer;
  parent_status public.lab_order_status;
begin
  select i.* into item_row from public.lab_order_items i where i.id = target_item for update;
  if item_row.id is null then raise exception 'Lab order item not found.' using errcode = 'P0002'; end if;
  select m.role into actor_role from public.clinic_memberships m
    where m.clinic_id = item_row.clinic_id and m.user_id = actor and m.active limit 1;
  if not public.has_clinic_role(item_row.clinic_id) then
    raise exception 'Not authorized to update this lab order.' using errcode = '42501';
  end if;

  if item_row.status = target_status then return target_status; end if;
  if item_row.status = 'ordered' and target_status = 'sample_collected' then
    if actor_role not in ('super_admin','lab_technician') or not exists (
      select 1 from public.lab_samples s where s.clinic_id = item_row.clinic_id
        and s.order_item_id = item_row.id and s.status = 'collected'
    ) then raise exception 'A collected specimen is required.' using errcode = '23514'; end if;
  elsif item_row.status = 'sample_collected' and target_status = 'processing' then
    if actor_role not in ('super_admin','lab_technician') then raise exception 'Lab technician access required.' using errcode = '42501'; end if;
  elsif item_row.status = 'processing' and target_status = 'completed' then
    if actor_role not in ('super_admin','lab_technician') or not exists (
      select 1 from public.lab_results r where r.clinic_id = item_row.clinic_id and r.order_item_id = item_row.id
    ) then raise exception 'A test result is required before completion.' using errcode = '23514'; end if;
  elsif item_row.status = 'completed' and target_status = 'verified' then
    if actor_role not in ('super_admin','doctor') then raise exception 'Authorized doctor verification required.' using errcode = '42501'; end if;
    select r.id into latest_result from public.lab_results r
      where r.clinic_id = item_row.clinic_id and r.order_item_id = item_row.id
      order by r.version desc limit 1;
    if latest_result is null or not exists (
      select 1 from public.lab_result_verifications v where v.clinic_id = item_row.clinic_id
        and v.result_id = latest_result and v.level = 'technician_verified'
    ) or not exists (
      select 1 from public.lab_result_verifications v where v.clinic_id = item_row.clinic_id
        and v.result_id = latest_result and v.level = 'doctor_verified'
    ) then raise exception 'Both technician and doctor verification are required.' using errcode = '23514'; end if;
  elsif item_row.status = 'verified' and target_status = 'delivered' then
    if actor_role not in ('super_admin','admin','receptionist','doctor') then raise exception 'Report delivery access required.' using errcode = '42501'; end if;
  elsif target_status = 'cancelled' and item_row.status in ('ordered','sample_collected','processing') then
    if actor_role not in ('super_admin','admin','receptionist','lab_technician') then raise exception 'Cancellation access required.' using errcode = '42501'; end if;
  else
    raise exception 'Invalid laboratory workflow transition.' using errcode = '23514';
  end if;

  update public.lab_order_items set status = target_status where id = item_row.id;
  select count(*), count(*) filter (where status <> 'cancelled'),
    count(*) filter (where status = 'delivered'), count(*) filter (where status in ('verified','delivered')),
    count(*) filter (where status in ('completed','verified','delivered')),
    count(*) filter (where status = 'processing'), count(*) filter (where status = 'sample_collected')
  into total_items, active_items, delivered_items, verified_items, completed_items, processing_items, collected_items
  from public.lab_order_items where clinic_id = item_row.clinic_id and order_id = item_row.order_id;

  parent_status := case
    when active_items = 0 then 'cancelled'::public.lab_order_status
    when delivered_items = active_items then 'delivered'::public.lab_order_status
    when verified_items = active_items then 'verified'::public.lab_order_status
    when completed_items = active_items then 'completed'::public.lab_order_status
    when processing_items > 0 then 'processing'::public.lab_order_status
    when collected_items > 0 then 'sample_collected'::public.lab_order_status
    else 'ordered'::public.lab_order_status
  end;
  update public.lab_orders set status = parent_status, updated_at = now() where id = item_row.order_id;
  return target_status;
end;
$$;
revoke all on function public.transition_lab_item_status(uuid, public.lab_item_status) from public;
grant execute on function public.transition_lab_item_status(uuid, public.lab_item_status) to authenticated;

create or replace function public.collect_lab_sample(target_item uuid, target_sample_number text, target_sample_type text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  item_row public.lab_order_items%rowtype;
  sample_id uuid;
begin
  select i.* into item_row from public.lab_order_items i where i.id = target_item for update;
  if item_row.id is null or item_row.status <> 'ordered' then
    raise exception 'This test is not awaiting sample collection.' using errcode = '23514';
  end if;
  if not public.has_clinic_role(item_row.clinic_id, array['super_admin','lab_technician']::public.clinic_role[]) then
    raise exception 'Lab technician access required.' using errcode = '42501';
  end if;
  if length(trim(coalesce(target_sample_number, ''))) < 6 or length(target_sample_number) > 48 then
    raise exception 'Invalid sample identifier.' using errcode = '22023';
  end if;
  insert into public.lab_samples (clinic_id, order_item_id, sample_number, sample_type, status, collected_by, collected_at)
  values (item_row.clinic_id, item_row.id, target_sample_number, nullif(left(trim(coalesce(target_sample_type, '')), 80), ''), 'collected', (select auth.uid()), now())
  returning id into sample_id;
  perform public.transition_lab_item_status(item_row.id, 'sample_collected');
  return sample_id;
end;
$$;
revoke all on function public.collect_lab_sample(uuid, text, text) from public;
grant execute on function public.collect_lab_sample(uuid, text, text) to authenticated;

create or replace function public.reject_lab_sample(target_sample uuid, rejection_note text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  sample_row public.lab_samples%rowtype;
begin
  select s.* into sample_row from public.lab_samples s where s.id = target_sample for update;
  if sample_row.id is null or sample_row.status <> 'collected' then
    raise exception 'Only a collected sample can be rejected.' using errcode = '23514';
  end if;
  if not public.has_clinic_role(sample_row.clinic_id, array['super_admin','lab_technician']::public.clinic_role[])
     or length(trim(coalesce(rejection_note, ''))) < 5 then
    raise exception 'A lab technician and a rejection reason are required.' using errcode = '42501';
  end if;
  update public.lab_samples set status = 'rejected', rejected_by = (select auth.uid()),
    rejected_at = now(), rejection_reason = left(trim(rejection_note), 500)
  where id = sample_row.id;
  perform public.transition_lab_item_status(sample_row.order_item_id, 'cancelled');
end;
$$;
revoke all on function public.reject_lab_sample(uuid, text) from public;
grant execute on function public.reject_lab_sample(uuid, text) to authenticated;

create or replace function public.record_lab_result(target_item uuid, target_values jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  item_row public.lab_order_items%rowtype;
  test_schema jsonb;
  field jsonb;
  field_key text;
  field_type text;
  numeric_value numeric;
  abnormal text[] := '{}';
  is_critical boolean := false;
  result_id uuid;
  field_count integer;
begin
  select i.* into item_row from public.lab_order_items i where i.id = target_item for update;
  if item_row.id is null or item_row.status <> 'processing' then
    raise exception 'The test must be processing before results are entered.' using errcode = '23514';
  end if;
  if not public.has_clinic_role(item_row.clinic_id, array['super_admin','lab_technician']::public.clinic_role[]) then
    raise exception 'Lab technician access required.' using errcode = '42501';
  end if;
  select t.result_schema into test_schema from public.lab_tests t
    where t.clinic_id = item_row.clinic_id and t.id = item_row.test_id and t.active;
  if test_schema is null or jsonb_typeof(target_values) <> 'object' then
    raise exception 'Invalid test result data.' using errcode = '22023';
  end if;
  select count(*) into field_count from jsonb_array_elements(test_schema);
  if field_count = 0 or jsonb_object_length(target_values) <> field_count then
    raise exception 'Result fields do not match this test configuration.' using errcode = '22023';
  end if;

  for field in select value from jsonb_array_elements(test_schema) loop
    field_key := field ->> 'key';
    field_type := field ->> 'type';
    if field_key is null or not (target_values ? field_key) then
      raise exception 'A configured result field is missing.' using errcode = '22023';
    end if;
    if field_type = 'number' then
      if jsonb_typeof(target_values -> field_key) <> 'number' then
        raise exception 'A numeric result contains an invalid value.' using errcode = '22023';
      end if;
      numeric_value := (target_values ->> field_key)::numeric;
      if (field ? 'referenceMin' and numeric_value < (field ->> 'referenceMin')::numeric)
        or (field ? 'referenceMax' and numeric_value > (field ->> 'referenceMax')::numeric) then
        abnormal := array_append(abnormal, field_key);
      end if;
      if (field ? 'criticalMin' and numeric_value < (field ->> 'criticalMin')::numeric)
        or (field ? 'criticalMax' and numeric_value > (field ->> 'criticalMax')::numeric) then
        is_critical := true;
      end if;
    elsif field_type = 'text' then
      if jsonb_typeof(target_values -> field_key) <> 'string' or length(target_values ->> field_key) > 4000 then
        raise exception 'A text result contains an invalid value.' using errcode = '22023';
      end if;
    elsif field_type = 'boolean' then
      if jsonb_typeof(target_values -> field_key) <> 'boolean' then
        raise exception 'A boolean result contains an invalid value.' using errcode = '22023';
      end if;
    else
      raise exception 'The configured result field type is unsupported.' using errcode = '22023';
    end if;
  end loop;

  insert into public.lab_results (
    clinic_id, order_item_id, version, result_values, reference_snapshot,
    abnormal_fields, critical, entered_by
  ) values (
    item_row.clinic_id, item_row.id, 1, target_values,
    jsonb_build_object('fields', test_schema), abnormal, is_critical, (select auth.uid())
  ) returning id into result_id;
  perform public.transition_lab_item_status(item_row.id, 'completed');
  return result_id;
end;
$$;
revoke all on function public.record_lab_result(uuid, jsonb) from public;
grant execute on function public.record_lab_result(uuid, jsonb) to authenticated;

create or replace function public.verify_lab_result(target_result uuid, target_level public.lab_verification_level, target_notes text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  result_row public.lab_results%rowtype;
  actor_role public.clinic_role;
  verification_id uuid;
begin
  select r.* into result_row from public.lab_results r where r.id = target_result;
  if result_row.id is null then raise exception 'Lab result not found.' using errcode = 'P0002'; end if;
  select m.role into actor_role from public.clinic_memberships m
    where m.clinic_id = result_row.clinic_id and m.user_id = (select auth.uid()) and m.active limit 1;
  if not public.has_clinic_role(result_row.clinic_id) then
    raise exception 'Not authorized to verify this result.' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.lab_order_items i where i.clinic_id = result_row.clinic_id
      and i.id = result_row.order_item_id and i.status = 'completed'
  ) or exists (
    select 1 from public.lab_results newer where newer.clinic_id = result_row.clinic_id
      and newer.order_item_id = result_row.order_item_id and newer.version > result_row.version
  ) then raise exception 'Only the current completed result can be verified.' using errcode = '23514'; end if;

  if target_level = 'technician_verified' and actor_role not in ('super_admin','lab_technician') then
    raise exception 'Lab technician verification required.' using errcode = '42501';
  elsif target_level = 'doctor_verified' and actor_role not in ('super_admin','doctor') then
    raise exception 'Authorized doctor verification required.' using errcode = '42501';
  elsif target_level = 'rejected' then
    raise exception 'Use a correction version with a documented reason.' using errcode = '22023';
  end if;
  if target_level = 'doctor_verified' and not public.lab_verification_chain_allowed(target_result) then
    raise exception 'Technician verification is required first.' using errcode = '23514';
  end if;
  if target_level = 'doctor_verified' and actor_role = 'doctor' and not exists (
    select 1 from public.lab_order_items i
    join public.lab_orders o on o.clinic_id = i.clinic_id and o.id = i.order_id
    join public.doctors d on d.clinic_id = o.clinic_id and d.id = o.ordered_by_doctor_id
    where i.clinic_id = result_row.clinic_id and i.id = result_row.order_item_id and d.profile_id = actor
  ) then raise exception 'Only the ordering doctor may authorize this result.' using errcode = '42501'; end if;

  insert into public.lab_result_verifications (clinic_id, result_id, level, verified_by, notes)
  values (result_row.clinic_id, target_result, target_level, (select auth.uid()), nullif(left(trim(coalesce(target_notes, '')), 500), ''))
  returning id into verification_id;
  if target_level = 'doctor_verified' then
    perform public.transition_lab_item_status(result_row.order_item_id, 'verified');
  end if;
  return verification_id;
end;
$$;
revoke all on function public.verify_lab_result(uuid, public.lab_verification_level, text) from public;
grant execute on function public.verify_lab_result(uuid, public.lab_verification_level, text) to authenticated;

alter table public.lab_categories enable row level security;
alter table public.lab_tests enable row level security;
alter table public.lab_orders enable row level security;
alter table public.lab_order_items enable row level security;
alter table public.lab_samples enable row level security;
alter table public.lab_results enable row level security;
alter table public.lab_result_verifications enable row level security;

create or replace function public.lab_verification_chain_allowed(target_result uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.lab_result_verifications v
    where v.result_id = target_result and v.level = 'technician_verified'
  );
$$;
revoke all on function public.lab_verification_chain_allowed(uuid) from public;
grant execute on function public.lab_verification_chain_allowed(uuid) to authenticated;

create policy lab_categories_read on public.lab_categories for select to authenticated using (public.has_clinic_role(clinic_id));
create policy lab_categories_admin_write on public.lab_categories for all to authenticated
  using (public.has_clinic_role(clinic_id, array['super_admin','admin']::public.clinic_role[]))
  with check (public.has_clinic_role(clinic_id, array['super_admin','admin']::public.clinic_role[]));
create policy lab_tests_read on public.lab_tests for select to authenticated using (public.has_clinic_role(clinic_id));
create policy lab_tests_admin_write on public.lab_tests for all to authenticated
  using (public.has_clinic_role(clinic_id, array['super_admin','admin']::public.clinic_role[]))
  with check (public.has_clinic_role(clinic_id, array['super_admin','admin']::public.clinic_role[]));

create policy lab_orders_clinical_read on public.lab_orders for select to authenticated
  using (public.has_clinic_role(clinic_id, array['super_admin','admin','receptionist','doctor','lab_technician','auditor']::public.clinic_role[]));
create policy lab_items_clinical_read on public.lab_order_items for select to authenticated
  using (public.has_clinic_role(clinic_id, array['super_admin','admin','receptionist','doctor','lab_technician','auditor']::public.clinic_role[]));
create policy lab_samples_clinical_read on public.lab_samples for select to authenticated
  using (public.has_clinic_role(clinic_id, array['super_admin','admin','receptionist','doctor','lab_technician','auditor']::public.clinic_role[]));
create policy lab_samples_tech_insert on public.lab_samples for insert to authenticated
  with check (public.has_clinic_role(clinic_id, array['super_admin','lab_technician']::public.clinic_role[]));
create policy lab_results_clinical_read on public.lab_results for select to authenticated
  using (public.has_clinic_role(clinic_id, array['super_admin','admin','doctor','lab_technician','auditor']::public.clinic_role[]));
create policy lab_verifications_clinical_read on public.lab_result_verifications for select to authenticated
  using (public.has_clinic_role(clinic_id, array['super_admin','admin','doctor','lab_technician','auditor']::public.clinic_role[]));
create policy lab_verification_insert_via_rpc on public.lab_result_verifications for insert to authenticated
  with check (false);

revoke all on public.lab_categories, public.lab_tests, public.lab_orders, public.lab_order_items,
  public.lab_samples, public.lab_results, public.lab_result_verifications from anon, authenticated;
grant select on public.lab_categories, public.lab_tests, public.lab_orders, public.lab_order_items,
  public.lab_samples, public.lab_results, public.lab_result_verifications to authenticated;
grant insert, update on public.lab_categories, public.lab_tests to authenticated;
revoke insert, update on public.lab_samples from authenticated;
revoke insert on public.lab_results, public.lab_result_verifications from authenticated;

create trigger lab_orders_set_updated_at before update on public.lab_orders
for each row execute function public.set_updated_at();

create trigger lab_categories_audit_change after insert or update or delete on public.lab_categories
for each row execute function public.audit_row_change();
create trigger lab_tests_audit_change after insert or update or delete on public.lab_tests
for each row execute function public.audit_row_change();
create trigger lab_orders_audit_change after insert or update or delete on public.lab_orders
for each row execute function public.audit_row_change();
create trigger lab_order_items_audit_change after insert or update or delete on public.lab_order_items
for each row execute function public.audit_row_change();
create trigger lab_samples_audit_change after insert or update or delete on public.lab_samples
for each row execute function public.audit_row_change();
create trigger lab_results_audit_change after insert or update or delete on public.lab_results
for each row execute function public.audit_row_change();
