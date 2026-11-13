-- Imaging orders and radiology reports. Image bytes remain in a private PACS/DICOM store.

create type public.imaging_modality as enum ('xray', 'ct', 'mri');
create type public.imaging_order_status as enum (
  'ordered', 'scheduled', 'in_progress', 'image_acquired', 'report_draft', 'verified', 'delivered', 'cancelled'
);

create table public.imaging_services (
  id uuid primary key default gen_random_uuid(),
  clinic_id uuid not null references public.clinics(id) on delete restrict,
  modality public.imaging_modality not null,
  code text not null,
  name text not null check (length(trim(name)) between 2 and 160),
  body_region text,
  price numeric(12,2) not null default 0 check (price >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (clinic_id, id),
  unique (clinic_id, code)
);
create index imaging_services_catalog_idx on public.imaging_services(clinic_id, modality, name) where active;

create table public.imaging_orders (
  id uuid primary key default gen_random_uuid(),
  clinic_id uuid not null references public.clinics(id) on delete restrict,
  patient_id uuid not null,
  ordered_by_doctor_id uuid not null,
  service_id uuid not null,
  service_name_snapshot text not null,
  modality public.imaging_modality not null,
  price_snapshot numeric(12,2) not null check (price_snapshot >= 0),
  priority text not null default 'routine' check (priority in ('routine', 'urgent', 'stat')),
  status public.imaging_order_status not null default 'ordered',
  clinical_question text,
  created_by uuid references public.profiles(id) on delete set null,
  ordered_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (clinic_id, patient_id) references public.patients(clinic_id, id),
  foreign key (clinic_id, ordered_by_doctor_id) references public.doctors(clinic_id, id),
  foreign key (clinic_id, service_id) references public.imaging_services(clinic_id, id),
  unique (clinic_id, id)
);
create index imaging_orders_status_time_idx on public.imaging_orders(clinic_id, status, ordered_at desc);
create index imaging_orders_patient_idx on public.imaging_orders(clinic_id, patient_id, ordered_at desc);

create table public.imaging_studies (
  id uuid primary key default gen_random_uuid(),
  clinic_id uuid not null,
  order_id uuid not null,
  accession_number text not null,
  modality public.imaging_modality not null,
  dicom_study_uid text,
  pacs_study_id text,
  performed_by uuid references public.profiles(id) on delete set null,
  performed_at timestamptz,
  created_at timestamptz not null default now(),
  foreign key (clinic_id, order_id) references public.imaging_orders(clinic_id, id),
  unique (clinic_id, id),
  unique (clinic_id, order_id),
  unique (dicom_study_uid)
);
create index imaging_studies_accession_idx on public.imaging_studies(clinic_id, accession_number);

create table public.imaging_accession_counters (
  clinic_id uuid not null references public.clinics(id) on delete restrict,
  service_date date not null,
  last_number integer not null check (last_number > 0),
  primary key (clinic_id, service_date)
);
alter table public.imaging_accession_counters enable row level security;
revoke all on public.imaging_accession_counters from anon, authenticated;

create or replace function public.begin_imaging_study(target_order uuid)
returns table(study_id uuid, accession_number text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  order_row public.imaging_orders%rowtype;
  actor uuid := (select auth.uid());
  actor_role public.clinic_role;
  clinic_timezone text;
  service_day date;
  sequence_number integer;
  accession text;
  new_study uuid;
begin
  select o.* into order_row from public.imaging_orders o where o.id = target_order for update;
  if order_row.id is null or order_row.status <> 'scheduled' then
    raise exception 'Only a scheduled imaging order can start.' using errcode = '23514';
  end if;
  select m.role into actor_role from public.clinic_memberships m
    where m.clinic_id = order_row.clinic_id and m.user_id = actor and m.active limit 1;
  if actor_role not in ('super_admin','radiology_technician') or not public.has_clinic_role(
    order_row.clinic_id, array['super_admin','radiology_technician']::public.clinic_role[]
  ) then raise exception 'Radiology technician access required.' using errcode = '42501'; end if;
  select c.timezone into clinic_timezone from public.clinics c where c.id = order_row.clinic_id and c.active;
  if clinic_timezone is null then raise exception 'Clinic is unavailable.' using errcode = '42501'; end if;
  service_day := (now() at time zone clinic_timezone)::date;
  insert into public.imaging_accession_counters (clinic_id, service_date, last_number)
  values (order_row.clinic_id, service_day, 1)
  on conflict (clinic_id, service_date) do update set last_number = public.imaging_accession_counters.last_number + 1
  returning last_number into sequence_number;
  accession := 'IMG-' || to_char(service_day, 'YYYYMMDD') || '-' || lpad(sequence_number::text, 5, '0');
  insert into public.imaging_studies (clinic_id, order_id, accession_number, modality)
  values (order_row.clinic_id, order_row.id, accession, order_row.modality)
  returning id into new_study;
  update public.imaging_orders set status = 'in_progress' where id = order_row.id;
  return query select new_study, accession;
end;
$$;
revoke all on function public.begin_imaging_study(uuid) from public;
grant execute on function public.begin_imaging_study(uuid) to authenticated;

-- This table stores private object paths and checksums only, never a public image URL.
create table public.imaging_files (
  id uuid primary key default gen_random_uuid(),
  clinic_id uuid not null,
  study_id uuid not null,
  storage_bucket text not null check (storage_bucket <> 'public'),
  storage_object_path text not null check (storage_object_path !~ '^https?://'),
  mime_type text not null check (mime_type in ('application/dicom', 'application/octet-stream')),
  byte_size bigint not null check (byte_size between 1 and 2147483648),
  sha256_hex text not null check (sha256_hex ~ '^[a-fA-F0-9]{64}$'),
  dicom_metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(dicom_metadata) = 'object'),
  uploaded_by uuid references public.profiles(id) on delete set null,
  uploaded_at timestamptz not null default now(),
  foreign key (clinic_id, study_id) references public.imaging_studies(clinic_id, id),
  unique (clinic_id, id),
  unique (storage_bucket, storage_object_path)
);
create index imaging_files_study_idx on public.imaging_files(clinic_id, study_id, uploaded_at);

create table public.radiology_reports (
  id uuid primary key default gen_random_uuid(),
  clinic_id uuid not null,
  study_id uuid not null,
  version integer not null check (version > 0),
  findings text not null check (length(trim(findings)) between 1 and 20000),
  impression text not null check (length(trim(impression)) between 1 and 5000),
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  signed_by uuid not null references public.profiles(id) on delete restrict,
  signed_at timestamptz not null default now(),
  correction_reason text,
  supersedes_report_id uuid,
  foreign key (clinic_id, study_id) references public.imaging_studies(clinic_id, id),
  foreign key (clinic_id, supersedes_report_id) references public.radiology_reports(clinic_id, id),
  unique (clinic_id, id),
  unique (clinic_id, study_id, version),
  check ((version = 1 and supersedes_report_id is null) or
    (version > 1 and supersedes_report_id is not null and length(trim(coalesce(correction_reason, ''))) > 0))
);
create index radiology_reports_study_version_idx on public.radiology_reports(clinic_id, study_id, version desc);

create or replace function public.reject_radiology_report_mutation()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  raise exception 'Radiology reports are immutable; create a correction version instead.';
end;
$$;
create trigger radiology_reports_immutable before update or delete on public.radiology_reports
for each row execute function public.reject_radiology_report_mutation();

create or replace function public.create_imaging_order(
  target_clinic uuid,
  target_patient uuid,
  target_doctor uuid,
  target_service uuid,
  target_priority text default 'routine',
  target_question text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := (select auth.uid());
  actor_role public.clinic_role;
  service_row public.imaging_services%rowtype;
  new_order uuid;
begin
  select m.role into actor_role from public.clinic_memberships m
    where m.clinic_id = target_clinic and m.user_id = actor and m.active limit 1;
  if actor_role not in ('super_admin','admin','receptionist','doctor')
     or not public.has_clinic_role(target_clinic, array['super_admin','admin','receptionist','doctor']::public.clinic_role[]) then
    raise exception 'Not authorized to create imaging orders.' using errcode = '42501';
  end if;
  if actor_role = 'doctor' and not exists (
    select 1 from public.doctors d where d.clinic_id = target_clinic and d.id = target_doctor and d.profile_id = actor and d.active
  ) then raise exception 'Doctors may only order under their own clinical identity.' using errcode = '42501'; end if;
  if not exists (select 1 from public.patients p where p.clinic_id = target_clinic and p.id = target_patient and p.archived_at is null)
    then raise exception 'Patient is unavailable in this clinic.' using errcode = '23503'; end if;
  if not exists (select 1 from public.doctors d where d.clinic_id = target_clinic and d.id = target_doctor and d.active)
    then raise exception 'An active doctor is required for imaging orders.' using errcode = '23503'; end if;
  if target_priority not in ('routine','urgent','stat') then raise exception 'Invalid order priority.' using errcode = '22023'; end if;
  select s.* into service_row from public.imaging_services s
    where s.clinic_id = target_clinic and s.id = target_service and s.active;
  if service_row.id is null then raise exception 'Imaging service is unavailable.' using errcode = '23503'; end if;

  insert into public.imaging_orders (
    clinic_id, patient_id, ordered_by_doctor_id, service_id, service_name_snapshot,
    modality, price_snapshot, priority, clinical_question, created_by
  ) values (
    target_clinic, target_patient, target_doctor, service_row.id, service_row.name,
    service_row.modality, service_row.price, target_priority,
    nullif(left(trim(coalesce(target_question, '')), 1000), ''), actor
  ) returning id into new_order;
  return new_order;
end;
$$;
revoke all on function public.create_imaging_order(uuid, uuid, uuid, uuid, text, text) from public;
grant execute on function public.create_imaging_order(uuid, uuid, uuid, uuid, text, text) to authenticated;

create or replace function public.create_radiology_report(
  target_study uuid,
  target_findings text,
  target_impression text,
  target_supersedes uuid default null,
  target_correction_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  study_row public.imaging_studies%rowtype;
  actor uuid := (select auth.uid());
  new_version integer;
  new_report uuid;
  previous_version integer;
  order_status public.imaging_order_status;
begin
  select s.* into study_row from public.imaging_studies s where s.id = target_study;
  if study_row.id is null or not public.has_clinic_role(study_row.clinic_id, array['super_admin','radiologist']::public.clinic_role[])
    then raise exception 'Authorized radiologist access required.' using errcode = '42501'; end if;
  if length(trim(coalesce(target_findings, ''))) not between 1 and 20000
    or length(trim(coalesce(target_impression, ''))) not between 1 and 5000 then
    raise exception 'Report content is invalid.' using errcode = '22023';
  end if;
  select o.status into order_status from public.imaging_orders o where o.clinic_id = study_row.clinic_id and o.id = study_row.order_id;
  if order_status not in ('image_acquired','report_draft','verified') then
    raise exception 'Images must be acquired before a report is signed.' using errcode = '23514';
  end if;
  if study_row.dicom_study_uid is null and study_row.pacs_study_id is null then
    raise exception 'The PACS study has not been linked to this order.' using errcode = '23514';
  end if;
  select r.version into previous_version from public.radiology_reports r
    where r.clinic_id = study_row.clinic_id and r.study_id = study_row.id
    order by r.version desc limit 1;
  if previous_version is null then
    if target_supersedes is not null then raise exception 'Initial report cannot supersede another report.' using errcode = '23514'; end if;
    new_version := 1;
  else
    if target_supersedes is null or length(trim(coalesce(target_correction_reason, ''))) < 5 then
      raise exception 'A report correction must identify the prior report and include a reason.' using errcode = '23514';
    end if;
    if not exists (select 1 from public.radiology_reports r where r.clinic_id = study_row.clinic_id
      and r.study_id = study_row.id and r.id = target_supersedes and r.version = previous_version) then
      raise exception 'Only the latest report version can be corrected.' using errcode = '23514';
    end if;
    new_version := previous_version + 1;
  end if;
  insert into public.radiology_reports (
    clinic_id, study_id, version, findings, impression, created_by, signed_by, signed_at,
    correction_reason, supersedes_report_id
  ) values (
    study_row.clinic_id, study_row.id, new_version, trim(target_findings), trim(target_impression),
    actor, actor, now(), nullif(left(trim(coalesce(target_correction_reason, '')), 500), ''), target_supersedes
  ) returning id into new_report;
  if order_status = 'image_acquired' then
    update public.imaging_orders set status = 'report_draft' where id = study_row.order_id;
  end if;
  update public.imaging_orders set status = 'verified' where id = study_row.order_id;
  return new_report;
end;
$$;
revoke all on function public.create_radiology_report(uuid, text, text, uuid, text) from public;
grant execute on function public.create_radiology_report(uuid, text, text, uuid, text) to authenticated;

create or replace function public.guard_imaging_status_transition()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare actor_role public.clinic_role;
begin
  if new.status = old.status then return new; end if;
  select m.role into actor_role from public.clinic_memberships m
    where m.clinic_id = new.clinic_id and m.user_id = (select auth.uid()) and m.active limit 1;
  if actor_role in ('super_admin','radiology_technician') then
    if not ((old.status = 'ordered' and new.status in ('scheduled','cancelled'))
      or (old.status = 'scheduled' and new.status in ('in_progress','cancelled'))
      or (old.status = 'in_progress' and new.status = 'image_acquired')) then
      raise exception 'Invalid imaging workflow transition.' using errcode = '23514';
    end if;
    if new.status = 'image_acquired' and not exists (
      select 1 from public.imaging_studies s where s.clinic_id = new.clinic_id
        and s.order_id = new.id and (s.dicom_study_uid is not null or s.pacs_study_id is not null)
    ) then raise exception 'A linked PACS study is required before image acquisition can be completed.' using errcode = '23514'; end if;
    if new.status = 'image_acquired' then
      update public.imaging_studies set performed_by = (select auth.uid()), performed_at = now()
        where clinic_id = new.clinic_id and order_id = new.id;
    end if;
  elsif actor_role = 'radiologist' then
    if not ((old.status = 'image_acquired' and new.status = 'report_draft')
      or (old.status = 'report_draft' and new.status = 'verified')) then
      raise exception 'Radiologist workflow transition required.' using errcode = '23514';
    end if;
    if new.status = 'verified' and not exists (
      select 1 from public.radiology_reports r
      join public.imaging_studies s on s.clinic_id = r.clinic_id and s.id = r.study_id
      where s.clinic_id = new.clinic_id and s.order_id = new.id
    ) then raise exception 'A signed radiology report is required.' using errcode = '23514'; end if;
  elsif actor_role in ('admin','receptionist') and old.status = 'verified' and new.status = 'delivered' then
    null;
  else
    raise exception 'Not authorized to update this imaging order.' using errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger imaging_orders_guard_status before update of status on public.imaging_orders
for each row execute function public.guard_imaging_status_transition();

alter table public.imaging_services enable row level security;
alter table public.imaging_orders enable row level security;
alter table public.imaging_studies enable row level security;
alter table public.imaging_files enable row level security;
alter table public.radiology_reports enable row level security;

create policy imaging_services_read on public.imaging_services for select to authenticated using (public.has_clinic_role(clinic_id));
create policy imaging_services_admin_write on public.imaging_services for all to authenticated
  using (public.has_clinic_role(clinic_id, array['super_admin','admin']::public.clinic_role[]))
  with check (public.has_clinic_role(clinic_id, array['super_admin','admin']::public.clinic_role[]));
create policy imaging_orders_staff_read on public.imaging_orders for select to authenticated
  using (public.has_clinic_role(clinic_id, array['super_admin','admin','receptionist','radiology_technician','radiologist','auditor']::public.clinic_role[]));
create policy imaging_orders_ordering_doctor_read on public.imaging_orders for select to authenticated
  using (
    public.has_clinic_role(clinic_id, array['doctor']::public.clinic_role[])
    and exists (select 1 from public.doctors d where d.clinic_id = imaging_orders.clinic_id
      and d.id = imaging_orders.ordered_by_doctor_id and d.profile_id = (select auth.uid()))
  );
create policy imaging_studies_read on public.imaging_studies for select to authenticated
  using (
    public.has_clinic_role(clinic_id, array['super_admin','admin','radiology_technician','radiologist','auditor']::public.clinic_role[])
    or (public.has_clinic_role(clinic_id, array['doctor']::public.clinic_role[]) and exists (
      select 1 from public.imaging_orders o join public.doctors d
        on d.clinic_id = o.clinic_id and d.id = o.ordered_by_doctor_id
      where o.clinic_id = imaging_studies.clinic_id and o.id = imaging_studies.order_id and d.profile_id = (select auth.uid())
    ))
  );
create policy imaging_files_read on public.imaging_files for select to authenticated
  using (
    public.has_clinic_role(clinic_id, array['super_admin','admin','radiology_technician','radiologist']::public.clinic_role[])
    or (public.has_clinic_role(clinic_id, array['doctor']::public.clinic_role[]) and exists (
      select 1 from public.imaging_studies s join public.imaging_orders o
        on o.clinic_id = s.clinic_id and o.id = s.order_id
      join public.doctors d on d.clinic_id = o.clinic_id and d.id = o.ordered_by_doctor_id
      where s.clinic_id = imaging_files.clinic_id and s.id = imaging_files.study_id and d.profile_id = (select auth.uid())
    ))
  );
create policy imaging_reports_read on public.radiology_reports for select to authenticated
  using (
    public.has_clinic_role(clinic_id, array['super_admin','admin','radiologist','auditor']::public.clinic_role[])
    or (public.has_clinic_role(clinic_id, array['doctor']::public.clinic_role[]) and exists (
      select 1 from public.imaging_studies s join public.imaging_orders o
        on o.clinic_id = s.clinic_id and o.id = s.order_id
      join public.doctors d on d.clinic_id = o.clinic_id and d.id = o.ordered_by_doctor_id
      where s.clinic_id = radiology_reports.clinic_id and s.id = radiology_reports.study_id and d.profile_id = (select auth.uid())
    ))
  );
create policy imaging_order_status_update on public.imaging_orders for update to authenticated
  using (public.has_clinic_role(clinic_id, array['super_admin','admin','receptionist','radiology_technician','radiologist']::public.clinic_role[]))
  with check (public.has_clinic_role(clinic_id, array['super_admin','admin','receptionist','radiology_technician','radiologist']::public.clinic_role[]));

revoke all on public.imaging_services, public.imaging_orders, public.imaging_studies,
  public.imaging_files, public.radiology_reports from anon, authenticated;
grant select on public.imaging_services, public.imaging_orders, public.imaging_studies,
  public.imaging_files, public.radiology_reports to authenticated;
grant insert, update on public.imaging_services to authenticated;
grant update (status) on public.imaging_orders to authenticated;

create trigger imaging_services_set_updated_at before update on public.imaging_services
for each row execute function public.set_updated_at();
create trigger imaging_orders_set_updated_at before update on public.imaging_orders
for each row execute function public.set_updated_at();
create trigger imaging_services_audit_change after insert or update or delete on public.imaging_services
for each row execute function public.audit_row_change();
create trigger imaging_orders_audit_change after insert or update or delete on public.imaging_orders
for each row execute function public.audit_row_change();
create trigger imaging_studies_audit_change after insert or update or delete on public.imaging_studies
for each row execute function public.audit_row_change();
create trigger imaging_files_audit_change after insert or update or delete on public.imaging_files
for each row execute function public.audit_row_change();
create trigger radiology_reports_audit_change after insert or update or delete on public.radiology_reports
for each row execute function public.audit_row_change();
