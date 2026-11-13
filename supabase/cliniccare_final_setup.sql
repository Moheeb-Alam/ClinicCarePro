-- ClinicCare Pro complete setup for Supabase SQL Editor.
-- DESTRUCTIVE: this script drops and recreates the entire public schema.
-- All data and objects in public will be permanently deleted. Supabase auth users are not dropped.
-- Run only on a new/disposable project or after taking a verified backup.
-- This is a one-time full setup file. Do not run after later adding production data.

drop schema if exists public cascade;
create schema public;
grant all on schema public to postgres;
grant usage on schema public to anon, authenticated, service_role;


-- >>> BEGIN supabase\migrations\202611110001_clinic_foundation.sql
-- ClinicCare Pro foundation: multi-clinic identity, patient care, scheduling, and audit.
-- Apply with Supabase CLI after reviewing the deployment notes in README.md.

create extension if not exists pgcrypto;

create type public.clinic_role as enum (
  'super_admin', 'admin', 'receptionist', 'doctor', 'lab_technician',
  'radiology_technician', 'radiologist', 'pharmacist', 'accountant', 'auditor'
);
create type public.patient_gender as enum ('female', 'male', 'other', 'unknown');
create type public.appointment_status as enum (
  'scheduled', 'confirmed', 'checked_in', 'in_consultation',
  'completed', 'cancelled', 'no_show'
);

create table public.clinics (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 2 and 180),
  slug text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  timezone text not null default 'Asia/Karachi',
  phone text,
  email text,
  address text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.profiles (
  id uuid primary key references auth.users(id) on delete restrict,
  full_name text not null check (length(trim(full_name)) between 2 and 160),
  phone text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.clinic_memberships (
  id uuid primary key default gen_random_uuid(),
  clinic_id uuid not null references public.clinics(id) on delete restrict,
  user_id uuid not null references public.profiles(id) on delete restrict,
  role public.clinic_role not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (clinic_id, user_id)
);
create index clinic_memberships_user_idx on public.clinic_memberships(user_id, clinic_id) where active;

create table public.departments (
  id uuid primary key default gen_random_uuid(),
  clinic_id uuid not null references public.clinics(id) on delete restrict,
  name text not null check (length(trim(name)) between 2 and 100),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (clinic_id, name),
  unique (clinic_id, id)
);

create table public.patients (
  id uuid primary key default gen_random_uuid(),
  clinic_id uuid not null references public.clinics(id) on delete restrict,
  mr_number text not null,
  full_name text not null check (length(trim(full_name)) between 2 and 160),
  father_name text,
  gender public.patient_gender not null default 'unknown',
  date_of_birth date,
  phone text,
  email text,
  address text,
  blood_group text check (blood_group is null or blood_group in ('A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-')),
  emergency_contact_name text,
  emergency_contact_phone text,
  registration_date date not null default current_date,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz,
  unique (clinic_id, mr_number),
  unique (clinic_id, id)
);
create index patients_clinic_name_idx on public.patients(clinic_id, lower(full_name)) where archived_at is null;
create index patients_clinic_phone_idx on public.patients(clinic_id, phone) where archived_at is null;

create table public.doctors (
  id uuid primary key default gen_random_uuid(),
  clinic_id uuid not null references public.clinics(id) on delete restrict,
  profile_id uuid references public.profiles(id) on delete restrict,
  department_id uuid,
  full_name text not null check (length(trim(full_name)) between 2 and 160),
  specialization text not null,
  qualification text,
  experience_years smallint check (experience_years is null or experience_years between 0 and 80),
  consultation_fee numeric(12,2) not null default 0 check (consultation_fee >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (clinic_id, id),
  foreign key (clinic_id, department_id) references public.departments(clinic_id, id),
  unique (clinic_id, profile_id)
);
create index doctors_clinic_active_idx on public.doctors(clinic_id, full_name) where active;

create table public.appointments (
  id uuid primary key default gen_random_uuid(),
  clinic_id uuid not null references public.clinics(id) on delete restrict,
  patient_id uuid not null,
  doctor_id uuid not null,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  token_number integer check (token_number is null or token_number > 0),
  status public.appointment_status not null default 'scheduled',
  reason text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  cancelled_at timestamptz,
  check (ends_at > starts_at),
  foreign key (clinic_id, patient_id) references public.patients(clinic_id, id),
  foreign key (clinic_id, doctor_id) references public.doctors(clinic_id, id),
  unique (clinic_id, id)
);
create index appointments_clinic_time_idx on public.appointments(clinic_id, starts_at, status);
create index appointments_patient_time_idx on public.appointments(clinic_id, patient_id, starts_at desc);
create index appointments_doctor_time_idx on public.appointments(clinic_id, doctor_id, starts_at);

-- Prevent concurrent active bookings for a clinician in the same time interval.
create extension if not exists btree_gist;
alter table public.appointments
  add constraint appointments_doctor_no_overlap
  exclude using gist (
    clinic_id with =,
    doctor_id with =,
    tstzrange(starts_at, ends_at, '[)') with &&
  ) where (status not in ('cancelled', 'no_show'));

create table public.encounters (
  id uuid primary key default gen_random_uuid(),
  clinic_id uuid not null references public.clinics(id) on delete restrict,
  patient_id uuid not null,
  appointment_id uuid,
  doctor_id uuid not null,
  started_at timestamptz not null default now(),
  finalized_at timestamptz,
  created_at timestamptz not null default now(),
  foreign key (clinic_id, patient_id) references public.patients(clinic_id, id),
  foreign key (clinic_id, doctor_id) references public.doctors(clinic_id, id),
  foreign key (clinic_id, appointment_id) references public.appointments(clinic_id, id),
  unique (clinic_id, id)
);
create index encounters_patient_time_idx on public.encounters(clinic_id, patient_id, started_at desc);

create table public.vitals (
  id uuid primary key default gen_random_uuid(),
  clinic_id uuid not null,
  encounter_id uuid not null,
  recorded_by uuid references public.profiles(id) on delete set null,
  systolic_bp smallint check (systolic_bp is null or systolic_bp between 40 and 300),
  diastolic_bp smallint check (diastolic_bp is null or diastolic_bp between 20 and 200),
  temperature_c numeric(4,1) check (temperature_c is null or temperature_c between 25 and 45),
  pulse_bpm smallint check (pulse_bpm is null or pulse_bpm between 20 and 250),
  weight_kg numeric(6,2) check (weight_kg is null or weight_kg between 0.2 and 500),
  height_cm numeric(6,2) check (height_cm is null or height_cm between 20 and 260),
  recorded_at timestamptz not null default now(),
  foreign key (clinic_id, encounter_id) references public.encounters(clinic_id, id)
);
create index vitals_encounter_idx on public.vitals(clinic_id, encounter_id, recorded_at desc);

create table public.audit_logs (
  id bigint generated always as identity primary key,
  clinic_id uuid references public.clinics(id) on delete restrict,
  actor_id uuid references public.profiles(id) on delete set null,
  action text not null check (length(action) between 1 and 100),
  module text not null check (length(module) between 1 and 80),
  record_id text,
  reason text,
  previous_values jsonb,
  new_values jsonb,
  request_reference text,
  ip_address inet,
  occurred_at timestamptz not null default now()
);
create index audit_logs_clinic_time_idx on public.audit_logs(clinic_id, occurred_at desc);

create or replace function public.has_clinic_role(target_clinic uuid, allowed_roles public.clinic_role[] default null)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.clinic_memberships m
    where m.clinic_id = target_clinic
      and m.user_id = (select auth.uid())
      and m.active
      and (allowed_roles is null or m.role = any(allowed_roles))
  );
$$;

revoke all on function public.has_clinic_role(uuid, public.clinic_role[]) from public;
grant execute on function public.has_clinic_role(uuid, public.clinic_role[]) to authenticated;

alter table public.clinics enable row level security;
alter table public.profiles enable row level security;
alter table public.clinic_memberships enable row level security;
alter table public.departments enable row level security;
alter table public.patients enable row level security;
alter table public.doctors enable row level security;
alter table public.appointments enable row level security;
alter table public.encounters enable row level security;
alter table public.vitals enable row level security;
alter table public.audit_logs enable row level security;

create policy clinic_member_read on public.clinics for select to authenticated
using (public.has_clinic_role(id));
create policy profile_self_read on public.profiles for select to authenticated
using (id = (select auth.uid()));
create policy profile_self_update on public.profiles for update to authenticated
using (id = (select auth.uid())) with check (id = (select auth.uid()));
create policy memberships_clinic_admin_read on public.clinic_memberships for select to authenticated
using (public.has_clinic_role(clinic_id, array['super_admin','admin','auditor']::public.clinic_role[]) or user_id = (select auth.uid()));
create policy department_read on public.departments for select to authenticated
using (public.has_clinic_role(clinic_id));
create policy department_admin_write on public.departments for all to authenticated
using (public.has_clinic_role(clinic_id, array['super_admin','admin']::public.clinic_role[]))
with check (public.has_clinic_role(clinic_id, array['super_admin','admin']::public.clinic_role[]));

create policy patient_clinical_read on public.patients for select to authenticated
using (public.has_clinic_role(clinic_id, array['super_admin','admin','receptionist','doctor','lab_technician','radiology_technician','radiologist','pharmacist','accountant','auditor']::public.clinic_role[]));
create policy patient_frontdesk_insert on public.patients for insert to authenticated
with check (public.has_clinic_role(clinic_id, array['super_admin','admin','receptionist']::public.clinic_role[]));
create policy patient_admin_frontdesk_update on public.patients for update to authenticated
using (public.has_clinic_role(clinic_id, array['super_admin','admin','receptionist']::public.clinic_role[]))
with check (public.has_clinic_role(clinic_id, array['super_admin','admin','receptionist']::public.clinic_role[]));

create policy doctor_clinic_read on public.doctors for select to authenticated
using (public.has_clinic_role(clinic_id));
create policy doctor_admin_write on public.doctors for all to authenticated
using (public.has_clinic_role(clinic_id, array['super_admin','admin']::public.clinic_role[]))
with check (public.has_clinic_role(clinic_id, array['super_admin','admin']::public.clinic_role[]));

create policy appointment_clinic_read on public.appointments for select to authenticated
using (public.has_clinic_role(clinic_id));
create policy appointment_frontdesk_insert on public.appointments for insert to authenticated
with check (public.has_clinic_role(clinic_id, array['super_admin','admin','receptionist']::public.clinic_role[]));
create policy appointment_frontdesk_update on public.appointments for update to authenticated
using (public.has_clinic_role(clinic_id, array['super_admin','admin','receptionist']::public.clinic_role[]))
with check (public.has_clinic_role(clinic_id, array['super_admin','admin','receptionist']::public.clinic_role[]));

create policy encounter_clinic_read on public.encounters for select to authenticated
using (public.has_clinic_role(clinic_id, array['super_admin','admin','doctor','auditor']::public.clinic_role[]));
create policy encounter_doctor_write on public.encounters for insert to authenticated
with check (public.has_clinic_role(clinic_id, array['super_admin','admin','doctor']::public.clinic_role[]));
create policy vitals_clinical_read on public.vitals for select to authenticated
using (public.has_clinic_role(clinic_id, array['super_admin','admin','doctor','auditor']::public.clinic_role[]));
create policy vitals_clinical_insert on public.vitals for insert to authenticated
with check (public.has_clinic_role(clinic_id, array['super_admin','admin','doctor','receptionist']::public.clinic_role[]));

create policy audit_clinic_read on public.audit_logs for select to authenticated
using (public.has_clinic_role(clinic_id, array['super_admin','admin','auditor']::public.clinic_role[]));
create policy audit_actor_insert on public.audit_logs for insert to authenticated
with check (actor_id = (select auth.uid()) and public.has_clinic_role(clinic_id));
revoke update, delete, truncate on public.audit_logs from anon, authenticated;

create or replace function public.reject_audit_mutation()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  raise exception 'Audit records are append-only; create a correction event instead.';
end;
$$;
create trigger audit_logs_immutable
before update or delete on public.audit_logs
for each row execute function public.reject_audit_mutation();

grant select on public.clinics, public.profiles, public.clinic_memberships,
  public.departments, public.patients, public.doctors, public.appointments,
  public.encounters, public.vitals, public.audit_logs to authenticated;
grant insert, update on public.departments, public.patients, public.doctors, public.appointments to authenticated;
grant insert on public.encounters, public.vitals, public.audit_logs to authenticated;
-- Least-privilege API grants. RLS controls rows; these grants control operations.
revoke all on public.clinics, public.profiles, public.clinic_memberships,
  public.departments, public.patients, public.doctors, public.appointments,
  public.encounters, public.vitals, public.audit_logs from anon, authenticated;

-- Users may read their profile. Profile activation and role changes are admin-only.
grant select on public.profiles to authenticated;
grant select on public.clinics, public.clinic_memberships, public.departments,
  public.patients, public.doctors, public.appointments, public.encounters,
  public.vitals, public.audit_logs to authenticated;
grant insert, update on public.departments, public.patients, public.doctors, public.appointments to authenticated;
grant insert on public.encounters, public.vitals, public.audit_logs to authenticated;

create or replace function public.set_updated_at()
returns trigger language plpgsql set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger clinics_set_updated_at before update on public.clinics
for each row execute function public.set_updated_at();
create trigger profiles_set_updated_at before update on public.profiles
for each row execute function public.set_updated_at();
create trigger patients_set_updated_at before update on public.patients
for each row execute function public.set_updated_at();
create trigger doctors_set_updated_at before update on public.doctors
for each row execute function public.set_updated_at();
create trigger appointments_set_updated_at before update on public.appointments
for each row execute function public.set_updated_at();

-- <<< END supabase\migrations\202611110001_clinic_foundation.sql


-- >>> BEGIN supabase\migrations\202611110002_audit_and_patient_access.sql
-- Tighten patient data access and write audit events from database triggers.
-- This migration intentionally does not allow clients to insert audit entries directly.

drop policy if exists patient_clinical_read on public.patients;
create policy patient_clinical_read on public.patients for select to authenticated
using (public.has_clinic_role(clinic_id, array[
  'super_admin','admin','receptionist','doctor','lab_technician',
  'radiology_technician','radiologist'
]::public.clinic_role[]));

drop policy if exists appointment_clinic_read on public.appointments;
create policy appointment_frontdesk_read on public.appointments for select to authenticated
using (public.has_clinic_role(clinic_id, array['super_admin','admin','receptionist']::public.clinic_role[]));
create policy appointment_assigned_doctor_read on public.appointments for select to authenticated
using (
  public.has_clinic_role(clinic_id, array['doctor']::public.clinic_role[])
  and exists (
    select 1 from public.doctors d
    where d.clinic_id = appointments.clinic_id
      and d.id = appointments.doctor_id
      and d.profile_id = (select auth.uid())
  )
);

alter table public.audit_logs add column actor_role public.clinic_role;
drop policy if exists audit_actor_insert on public.audit_logs;
revoke insert on public.audit_logs from anon, authenticated;

-- Daily tokens are allocated atomically so simultaneous walk-ins cannot collide.
create table public.appointment_token_counters (
  clinic_id uuid not null references public.clinics(id) on delete restrict,
  service_date date not null,
  last_token integer not null check (last_token > 0),
  primary key (clinic_id, service_date)
);
alter table public.appointment_token_counters enable row level security;
revoke all on public.appointment_token_counters from anon, authenticated;

create table public.patient_mr_counters (
  clinic_id uuid primary key references public.clinics(id) on delete restrict,
  last_number bigint not null check (last_number > 0)
);
alter table public.patient_mr_counters enable row level security;
revoke all on public.patient_mr_counters from anon, authenticated;

create or replace function public.next_appointment_token(target_clinic uuid, target_service_date date)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  allocated integer;
begin
  if not public.has_clinic_role(target_clinic, array[
    'super_admin','admin','receptionist'
  ]::public.clinic_role[]) then
    raise exception 'Not authorized to allocate an appointment token.' using errcode = '42501';
  end if;

  insert into public.appointment_token_counters (clinic_id, service_date, last_token)
  values (target_clinic, target_service_date, 1)
  on conflict (clinic_id, service_date) do update
    set last_token = public.appointment_token_counters.last_token + 1
  returning last_token into allocated;
  return allocated;
end;
$$;
revoke all on function public.next_appointment_token(uuid, date) from public;
revoke all on function public.next_appointment_token(uuid, date) from anon, authenticated;

create or replace function public.register_patient(
  target_clinic uuid,
  target_full_name text,
  target_gender public.patient_gender,
  target_father_name text default null,
  target_date_of_birth date default null,
  target_phone text default null,
  target_email text default null,
  target_address text default null,
  target_blood_group text default null,
  target_emergency_contact_name text default null,
  target_emergency_contact_phone text default null
)
returns table(patient_id uuid, mr_number text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := (select auth.uid());
  timezone_name text;
  patient_number bigint;
  generated_mr text;
begin
  if not public.has_clinic_role(target_clinic, array['super_admin','admin','receptionist']::public.clinic_role[]) then
    raise exception 'Not authorized to register patients.' using errcode = '42501';
  end if;
  select c.timezone into timezone_name from public.clinics c where c.id = target_clinic and c.active;
  if timezone_name is null then raise exception 'Clinic is unavailable.' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(target_clinic::text || ':patient-registration', 0));
  if length(trim(coalesce(target_full_name, ''))) not between 2 and 160
     or length(coalesce(target_father_name, '')) > 160
     or length(coalesce(target_address, '')) > 500
     or length(coalesce(target_emergency_contact_name, '')) > 160
     or length(coalesce(target_emergency_contact_phone, '')) > 32
     or (target_date_of_birth is not null and target_date_of_birth > (now() at time zone timezone_name)::date)
     or (target_phone is not null and target_phone !~ '^\+?[0-9]{7,15}$')
     or (target_emergency_contact_phone is not null and target_emergency_contact_phone !~ '^\+?[0-9]{7,15}$')
     or (target_email is not null and (length(target_email) > 254 or target_email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$')) then
    raise exception 'Patient details are invalid.' using errcode = '22023';
  end if;
  if target_phone is not null and exists (
    select 1 from public.patients p where p.clinic_id = target_clinic
      and p.phone = target_phone and p.archived_at is null
  ) then raise exception 'A patient with this phone already exists.' using errcode = '23505'; end if;
  if target_date_of_birth is not null and exists (
    select 1 from public.patients p where p.clinic_id = target_clinic
      and lower(p.full_name) = lower(trim(target_full_name))
      and p.date_of_birth = target_date_of_birth and p.archived_at is null
  ) then raise exception 'A patient with this name and date of birth already exists.' using errcode = '23505'; end if;

  insert into public.patient_mr_counters (clinic_id, last_number) values (target_clinic, 1)
  on conflict (clinic_id) do update set last_number = public.patient_mr_counters.last_number + 1
  returning last_number into patient_number;
  generated_mr := 'CC-' || to_char((now() at time zone timezone_name)::date, 'YYYY') || '-' || lpad(patient_number::text, 7, '0');

  insert into public.patients as patient (
    clinic_id, mr_number, full_name, father_name, gender, date_of_birth, phone, email,
    address, blood_group, emergency_contact_name, emergency_contact_phone,
    registration_date, created_by
  ) values (
    target_clinic, generated_mr, trim(target_full_name), nullif(trim(coalesce(target_father_name, '')), ''),
    target_gender, target_date_of_birth, nullif(trim(coalesce(target_phone, '')), ''),
    nullif(lower(trim(coalesce(target_email, ''))), ''), nullif(trim(coalesce(target_address, '')), ''),
    nullif(target_blood_group, ''), nullif(trim(coalesce(target_emergency_contact_name, '')), ''),
    nullif(trim(coalesce(target_emergency_contact_phone, '')), ''),
    (now() at time zone timezone_name)::date, actor
  ) returning patient.id, patient.mr_number into patient_id, mr_number;
  return next;
end;
$$;
revoke all on function public.register_patient(uuid, text, public.patient_gender, text, date, text, text, text, text, text, text) from public;
grant execute on function public.register_patient(uuid, text, public.patient_gender, text, date, text, text, text, text, text, text) to authenticated;

revoke update on public.appointments from authenticated;
grant update (status) on public.appointments to authenticated;
revoke insert on public.appointments from anon, authenticated;
drop policy if exists appointment_frontdesk_update on public.appointments;
create policy appointment_staff_update on public.appointments for update to authenticated
using (
  public.has_clinic_role(clinic_id, array['super_admin','admin','receptionist']::public.clinic_role[])
  or (
    public.has_clinic_role(clinic_id, array['doctor']::public.clinic_role[])
    and exists (
      select 1 from public.doctors d
      where d.clinic_id = appointments.clinic_id
        and d.id = appointments.doctor_id
        and d.profile_id = (select auth.uid())
    )
  )
)
with check (
  public.has_clinic_role(clinic_id, array['super_admin','admin','receptionist']::public.clinic_role[])
  or (
    public.has_clinic_role(clinic_id, array['doctor']::public.clinic_role[])
    and exists (
      select 1 from public.doctors d
      where d.clinic_id = appointments.clinic_id
        and d.id = appointments.doctor_id
        and d.profile_id = (select auth.uid())
    )
  )
);

create or replace function public.book_appointment(
  target_clinic uuid,
  target_patient uuid,
  target_doctor uuid,
  target_starts_at timestamptz,
  target_ends_at timestamptz,
  target_reason text default null
)
returns table(appointment_id uuid, token_number integer)
language plpgsql
security definer
set search_path = ''
as $$
declare
  service_day date;
  generated_token integer;
  new_appointment uuid;
  clinic_timezone text;
begin
  if not public.has_clinic_role(target_clinic, array['super_admin','admin','receptionist']::public.clinic_role[]) then
    raise exception 'Not authorized to book appointments.' using errcode = '42501';
  end if;
  if target_starts_at <= now() or target_starts_at > now() + interval '365 days'
     or target_ends_at <= target_starts_at or target_ends_at > target_starts_at + interval '90 minutes' then
    raise exception 'Appointment time or duration is invalid.' using errcode = '22023';
  end if;
  if not exists (select 1 from public.patients p where p.clinic_id = target_clinic and p.id = target_patient and p.archived_at is null)
     or not exists (select 1 from public.doctors d where d.clinic_id = target_clinic and d.id = target_doctor and d.active) then
    raise exception 'Patient or doctor is unavailable.' using errcode = '23503';
  end if;
  select c.timezone into clinic_timezone from public.clinics c where c.id = target_clinic and c.active;
  if clinic_timezone is null then raise exception 'Clinic is unavailable.' using errcode = '42501'; end if;
  service_day := (target_starts_at at time zone clinic_timezone)::date;
  insert into public.appointment_token_counters (clinic_id, service_date, last_token)
  values (target_clinic, service_day, 1)
  on conflict (clinic_id, service_date) do update set last_token = public.appointment_token_counters.last_token + 1
  returning last_token into generated_token;

  insert into public.appointments (clinic_id, patient_id, doctor_id, starts_at, ends_at, token_number, reason, created_by)
  values (target_clinic, target_patient, target_doctor, target_starts_at, target_ends_at, generated_token,
    nullif(left(trim(coalesce(target_reason, '')), 240), ''), (select auth.uid()))
  returning id into new_appointment;
  return query select new_appointment, generated_token;
end;
$$;
revoke all on function public.book_appointment(uuid, uuid, uuid, timestamptz, timestamptz, text) from public;
grant execute on function public.book_appointment(uuid, uuid, uuid, timestamptz, timestamptz, text) to authenticated;

revoke update on public.patients from authenticated;
revoke insert on public.patients from anon, authenticated;
grant update (full_name, father_name, gender, date_of_birth, phone, email, address,
  blood_group, emergency_contact_name, emergency_contact_phone) on public.patients to authenticated;
revoke update on public.doctors from authenticated;
grant update (department_id, profile_id, full_name, specialization, qualification,
  experience_years, consultation_fee, active) on public.doctors to authenticated;

create or replace function public.guard_appointment_status_transition()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_role public.clinic_role;
  allowed boolean := false;
begin
  if new.status = old.status then return new; end if;

  select m.role into actor_role
  from public.clinic_memberships m
  where m.clinic_id = new.clinic_id
    and m.user_id = (select auth.uid())
    and m.active
  limit 1;

  if actor_role = 'doctor' then
    allowed := (old.status = 'checked_in' and new.status = 'in_consultation')
      or (old.status = 'in_consultation' and new.status = 'completed');
  else
    allowed := (old.status = 'scheduled' and new.status in ('confirmed', 'cancelled', 'no_show'))
      or (old.status = 'confirmed' and new.status in ('checked_in', 'cancelled', 'no_show'))
      or (old.status = 'checked_in' and new.status in ('cancelled', 'no_show'));
  end if;

  if not allowed then
    raise exception 'Invalid appointment status transition.' using errcode = '23514';
  end if;
  if new.status = 'cancelled' then new.cancelled_at = now(); end if;
  return new;
end;
$$;
create trigger appointments_guard_status
before update of status on public.appointments
for each row execute function public.guard_appointment_status_transition();

create or replace function public.audit_row_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  row_before jsonb;
  row_after jsonb;
  target_clinic uuid;
  target_record text;
  action_name text;
  actor_role public.clinic_role;
begin
  if tg_op = 'DELETE' then
    row_before := to_jsonb(old);
    target_clinic := (row_before ->> 'clinic_id')::uuid;
    target_record := row_before ->> 'id';
    action_name := 'delete';
  elsif tg_op = 'UPDATE' then
    row_before := to_jsonb(old);
    row_after := to_jsonb(new);
    target_clinic := (row_after ->> 'clinic_id')::uuid;
    target_record := row_after ->> 'id';
    action_name := 'update';
  else
    row_after := to_jsonb(new);
    target_clinic := (row_after ->> 'clinic_id')::uuid;
    target_record := row_after ->> 'id';
    action_name := 'insert';
  end if;

  select m.role into actor_role
  from public.clinic_memberships as m
  where m.clinic_id = target_clinic
    and m.user_id = (select auth.uid())
    and m.active
  limit 1;

  insert into public.audit_logs (
    clinic_id, actor_id, actor_role, action, module, record_id,
    previous_values, new_values
  ) values (
    target_clinic, (select auth.uid()), actor_role, action_name, tg_table_name,
    target_record, row_before, row_after
  );

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

create trigger patients_audit_change
after insert or update or delete on public.patients
for each row execute function public.audit_row_change();
create trigger doctors_audit_change
after insert or update or delete on public.doctors
for each row execute function public.audit_row_change();
create trigger appointments_audit_change
after insert or update or delete on public.appointments
for each row execute function public.audit_row_change();
create trigger encounters_audit_change
after insert or update or delete on public.encounters
for each row execute function public.audit_row_change();
create trigger vitals_audit_change
after insert or update or delete on public.vitals
for each row execute function public.audit_row_change();

create or replace function public.has_clinic_role(target_clinic uuid, allowed_roles public.clinic_role[] default null)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.clinic_memberships m
    join public.clinics c on c.id = m.clinic_id and c.active
    join public.profiles p on p.id = m.user_id and p.active
    where m.clinic_id = target_clinic
      and m.user_id = (select auth.uid())
      and m.active
      and (allowed_roles is null or m.role = any(allowed_roles))
  );
$$;
-- <<< END supabase\migrations\202611110002_audit_and_patient_access.sql


-- >>> BEGIN supabase\migrations\202611110003_laboratory.sql
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
-- <<< END supabase\migrations\202611110003_laboratory.sql


-- >>> BEGIN supabase\migrations\202611110004_imaging.sql
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
-- <<< END supabase\migrations\202611110004_imaging.sql


-- >>> BEGIN supabase\migrations\202611110005_finance_ledger.sql
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
-- <<< END supabase\migrations\202611110005_finance_ledger.sql


-- >>> BEGIN supabase\migrations\202611110006_pharmacy.sql
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
-- <<< END supabase\migrations\202611110006_pharmacy.sql


-- >>> BEGIN supabase\migrations\202611110007_clinical_encounters.sql
-- Clinical encounter workflow: structured notes, diagnoses, vitals, and clinician sign-off.

create type public.encounter_note_kind as enum ('chief_complaint','history','examination','assessment','plan','follow_up');

create table public.encounter_notes (
  id uuid primary key default gen_random_uuid(),
  clinic_id uuid not null,
  encounter_id uuid not null,
  kind public.encounter_note_kind not null,
  content text not null check (length(trim(content)) between 1 and 8000),
  author_id uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  foreign key (clinic_id, encounter_id) references public.encounters(clinic_id, id),
  unique (clinic_id, id)
);
create index encounter_notes_time_idx on public.encounter_notes(clinic_id, encounter_id, created_at);

create table public.encounter_diagnoses (
  id uuid primary key default gen_random_uuid(),
  clinic_id uuid not null,
  encounter_id uuid not null,
  code text,
  description text not null check (length(trim(description)) between 2 and 240),
  is_primary boolean not null default false,
  recorded_by uuid not null references public.profiles(id) on delete restrict,
  recorded_at timestamptz not null default now(),
  foreign key (clinic_id, encounter_id) references public.encounters(clinic_id, id),
  unique (clinic_id, id)
);
create index encounter_diagnoses_idx on public.encounter_diagnoses(clinic_id, encounter_id, recorded_at);

create unique index encounters_one_per_appointment_idx on public.encounters(clinic_id, appointment_id)
where appointment_id is not null;

create or replace function public.guard_appointment_status_transition()
returns trigger language plpgsql security definer set search_path = '' as $$
declare actor_role public.clinic_role; allowed boolean := false;
begin
  if new.status = old.status then return new; end if;
  select m.role into actor_role from public.clinic_memberships m
    where m.clinic_id = new.clinic_id and m.user_id = (select auth.uid()) and m.active limit 1;
  if actor_role = 'doctor' then
    allowed := (old.status = 'checked_in' and new.status = 'in_consultation')
      or (old.status = 'in_consultation' and new.status = 'completed');
  elsif actor_role in ('super_admin','admin') then
    allowed := (old.status = 'scheduled' and new.status in ('confirmed','cancelled','no_show'))
      or (old.status = 'confirmed' and new.status in ('checked_in','cancelled','no_show'))
      or (old.status = 'checked_in' and new.status in ('cancelled','no_show','in_consultation'))
      or (old.status = 'in_consultation' and new.status = 'completed');
  else
    allowed := (old.status = 'scheduled' and new.status in ('confirmed','cancelled','no_show'))
      or (old.status = 'confirmed' and new.status in ('checked_in','cancelled','no_show'))
      or (old.status = 'checked_in' and new.status in ('cancelled','no_show'));
  end if;
  if not allowed then raise exception 'Invalid appointment status transition.' using errcode = '23514'; end if;
  if new.status = 'cancelled' then new.cancelled_at = now(); end if;
  return new;
end;
$$;

create or replace function public.start_clinical_encounter(target_appointment uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  appointment_row public.appointments%rowtype;
  actor uuid := (select auth.uid());
  new_encounter uuid;
begin
  select a.* into appointment_row from public.appointments a where a.id = target_appointment for update;
  if appointment_row.id is null or appointment_row.status not in ('checked_in','in_consultation')
    or not public.has_clinic_role(appointment_row.clinic_id, array['super_admin','doctor']::public.clinic_role[]) then
    raise exception 'A checked-in appointment and clinician access are required.' using errcode = '42501';
  end if;
  if public.has_clinic_role(appointment_row.clinic_id, array['doctor']::public.clinic_role[])
    and not exists (select 1 from public.doctors d where d.clinic_id = appointment_row.clinic_id
      and d.id = appointment_row.doctor_id and d.profile_id = actor) then
    raise exception 'Only the assigned doctor can open this encounter.' using errcode = '42501';
  end if;
  select e.id into new_encounter from public.encounters e
    where e.clinic_id = appointment_row.clinic_id and e.appointment_id = appointment_row.id;
  if new_encounter is not null then
    update public.appointments set status = 'in_consultation'
      where id = appointment_row.id and status = 'checked_in';
    return new_encounter;
  end if;
  insert into public.encounters (clinic_id, patient_id, appointment_id, doctor_id)
  values (appointment_row.clinic_id, appointment_row.patient_id, appointment_row.id, appointment_row.doctor_id)
  on conflict (clinic_id, appointment_id) where appointment_id is not null do nothing
  returning id into new_encounter;
  if new_encounter is null then
    select e.id into new_encounter from public.encounters e
      where e.clinic_id = appointment_row.clinic_id and e.appointment_id = appointment_row.id;
  end if;
  update public.appointments set status = 'in_consultation'
    where id = appointment_row.id and status = 'checked_in';
  return new_encounter;
end;
$$;
revoke all on function public.start_clinical_encounter(uuid) from public;
grant execute on function public.start_clinical_encounter(uuid) to authenticated;

create or replace function public.add_encounter_note(target_encounter uuid, target_kind public.encounter_note_kind, target_content text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  e public.encounters%rowtype;
  actor uuid := (select auth.uid());
  note_id uuid;
begin
  select x.* into e from public.encounters x where x.id = target_encounter for update;
  if e.id is null or e.finalized_at is not null or length(trim(coalesce(target_content,''))) not between 1 and 8000
    or not public.has_clinic_role(e.clinic_id, array['super_admin','doctor']::public.clinic_role[])
    or (public.has_clinic_role(e.clinic_id, array['doctor']::public.clinic_role[]) and not exists (
      select 1 from public.doctors d where d.clinic_id = e.clinic_id and d.id = e.doctor_id and d.profile_id = actor
    )) then raise exception 'Encounter is unavailable, finalized, or unauthorized.' using errcode = '42501'; end if;
  insert into public.encounter_notes (clinic_id, encounter_id, kind, content, author_id)
  values (e.clinic_id, e.id, target_kind, trim(target_content), actor) returning id into note_id;
  return note_id;
end;
$$;
revoke all on function public.add_encounter_note(uuid, public.encounter_note_kind, text) from public;
grant execute on function public.add_encounter_note(uuid, public.encounter_note_kind, text) to authenticated;

create or replace function public.add_encounter_diagnosis(target_encounter uuid, target_code text, target_description text, primary_diagnosis boolean default false)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  e public.encounters%rowtype;
  actor uuid := (select auth.uid());
  diagnosis_id uuid;
begin
  select x.* into e from public.encounters x where x.id = target_encounter for update;
  if e.id is null or e.finalized_at is not null or length(trim(coalesce(target_description,''))) not between 2 and 240
    or length(coalesce(target_code,'')) > 32
    or not public.has_clinic_role(e.clinic_id, array['super_admin','doctor']::public.clinic_role[])
    or (public.has_clinic_role(e.clinic_id, array['doctor']::public.clinic_role[]) and not exists (
      select 1 from public.doctors d where d.clinic_id = e.clinic_id and d.id = e.doctor_id and d.profile_id = actor
    )) then raise exception 'Encounter is unavailable, finalized, or unauthorized.' using errcode = '42501'; end if;
  insert into public.encounter_diagnoses (clinic_id, encounter_id, code, description, is_primary, recorded_by)
  values (e.clinic_id, e.id, nullif(trim(coalesce(target_code,'')), ''), trim(target_description), primary_diagnosis, actor)
  returning id into diagnosis_id;
  return diagnosis_id;
end;
$$;
revoke all on function public.add_encounter_diagnosis(uuid, text, text, boolean) from public;
grant execute on function public.add_encounter_diagnosis(uuid, text, text, boolean) to authenticated;

create or replace function public.record_encounter_vitals(target_encounter uuid,
  target_systolic smallint default null, target_diastolic smallint default null,
  target_temperature numeric default null, target_pulse smallint default null,
  target_weight numeric default null, target_height numeric default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  e public.encounters%rowtype;
  actor uuid := (select auth.uid());
  vital_id uuid;
begin
  select x.* into e from public.encounters x where x.id = target_encounter for update;
  if e.id is null or e.finalized_at is not null
    or not public.has_clinic_role(e.clinic_id, array['super_admin','doctor']::public.clinic_role[])
    or (public.has_clinic_role(e.clinic_id, array['doctor']::public.clinic_role[]) and not exists (
      select 1 from public.doctors d where d.clinic_id = e.clinic_id and d.id = e.doctor_id and d.profile_id = actor
    )) then raise exception 'Encounter is unavailable, finalized, or unauthorized.' using errcode = '42501'; end if;
  insert into public.vitals (clinic_id, encounter_id, recorded_by, systolic_bp, diastolic_bp, temperature_c, pulse_bpm, weight_kg, height_cm)
  values (e.clinic_id, e.id, actor, target_systolic, target_diastolic, target_temperature, target_pulse, target_weight, target_height)
  returning id into vital_id;
  return vital_id;
end;
$$;
revoke all on function public.record_encounter_vitals(uuid, smallint, smallint, numeric, smallint, numeric, numeric) from public;
grant execute on function public.record_encounter_vitals(uuid, smallint, smallint, numeric, smallint, numeric, numeric) to authenticated;

create or replace function public.finalize_clinical_encounter(target_encounter uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  e public.encounters%rowtype;
  actor uuid := (select auth.uid());
begin
  select x.* into e from public.encounters x where x.id = target_encounter for update;
  if e.id is null or e.finalized_at is not null
    or not public.has_clinic_role(e.clinic_id, array['super_admin','doctor']::public.clinic_role[])
    or (public.has_clinic_role(e.clinic_id, array['doctor']::public.clinic_role[]) and not exists (
      select 1 from public.doctors d where d.clinic_id = e.clinic_id and d.id = e.doctor_id and d.profile_id = actor
    )) then raise exception 'Encounter is unavailable, already finalized, or unauthorized.' using errcode = '42501'; end if;
  if not exists (select 1 from public.encounter_notes n where n.clinic_id = e.clinic_id and n.encounter_id = e.id and n.kind = 'assessment') then
    raise exception 'Add an assessment before signing the encounter.' using errcode = '23514';
  end if;
  update public.encounters set finalized_at = now() where clinic_id = e.clinic_id and id = e.id;
  if e.appointment_id is not null then
    update public.appointments set status = 'completed'
      where clinic_id = e.clinic_id and id = e.appointment_id and status = 'in_consultation';
  end if;
end;
$$;
revoke all on function public.finalize_clinical_encounter(uuid) from public;
grant execute on function public.finalize_clinical_encounter(uuid) to authenticated;

alter table public.encounter_notes enable row level security;
alter table public.encounter_diagnoses enable row level security;
drop policy if exists encounter_clinic_read on public.encounters;
create policy encounter_admin_auditor_read on public.encounters for select to authenticated
  using (public.has_clinic_role(clinic_id, array['super_admin','admin','auditor']::public.clinic_role[]));
create policy encounter_assigned_doctor_read on public.encounters for select to authenticated
  using (public.has_clinic_role(clinic_id, array['doctor']::public.clinic_role[]) and exists (
    select 1 from public.doctors d where d.clinic_id = encounters.clinic_id
      and d.id = encounters.doctor_id and d.profile_id = (select auth.uid())
  ));
create policy encounter_notes_admin_auditor_read on public.encounter_notes for select to authenticated
  using (public.has_clinic_role(clinic_id, array['super_admin','admin','auditor']::public.clinic_role[]));
create policy encounter_notes_assigned_doctor_read on public.encounter_notes for select to authenticated
  using (public.has_clinic_role(clinic_id, array['doctor']::public.clinic_role[]) and exists (
    select 1 from public.encounters e join public.doctors d on d.clinic_id = e.clinic_id and d.id = e.doctor_id
    where e.clinic_id = encounter_notes.clinic_id and e.id = encounter_notes.encounter_id and d.profile_id = (select auth.uid())
  ));
create policy encounter_diagnoses_admin_auditor_read on public.encounter_diagnoses for select to authenticated
  using (public.has_clinic_role(clinic_id, array['super_admin','admin','auditor']::public.clinic_role[]));
create policy encounter_diagnoses_assigned_doctor_read on public.encounter_diagnoses for select to authenticated
  using (public.has_clinic_role(clinic_id, array['doctor']::public.clinic_role[]) and exists (
    select 1 from public.encounters e join public.doctors d on d.clinic_id = e.clinic_id and d.id = e.doctor_id
    where e.clinic_id = encounter_diagnoses.clinic_id and e.id = encounter_diagnoses.encounter_id and d.profile_id = (select auth.uid())
  ));
drop policy if exists vitals_clinical_read on public.vitals;
create policy vitals_admin_auditor_read on public.vitals for select to authenticated
  using (public.has_clinic_role(clinic_id, array['super_admin','admin','auditor']::public.clinic_role[]));
create policy vitals_assigned_doctor_read on public.vitals for select to authenticated
  using (public.has_clinic_role(clinic_id, array['doctor']::public.clinic_role[]) and exists (
    select 1 from public.encounters e join public.doctors d on d.clinic_id = e.clinic_id and d.id = e.doctor_id
    where e.clinic_id = vitals.clinic_id and e.id = vitals.encounter_id and d.profile_id = (select auth.uid())
  ));
revoke all on public.encounter_notes, public.encounter_diagnoses from anon, authenticated;
grant select on public.encounter_notes, public.encounter_diagnoses to authenticated;
revoke insert, update, delete on public.encounters, public.vitals from anon, authenticated;
grant select on public.encounters, public.vitals to authenticated;

create or replace function public.reject_clinical_record_mutation()
returns trigger language plpgsql security definer set search_path = '' as $$
begin raise exception 'Clinical notes and diagnoses are append-only; add a correction note.'; end;
$$;
create trigger encounter_notes_immutable before update or delete on public.encounter_notes
for each row execute function public.reject_clinical_record_mutation();
create trigger encounter_diagnoses_immutable before update or delete on public.encounter_diagnoses
for each row execute function public.reject_clinical_record_mutation();
create trigger encounter_notes_audit after insert on public.encounter_notes
for each row execute function public.audit_row_change();
create trigger encounter_diagnoses_audit after insert on public.encounter_diagnoses
for each row execute function public.audit_row_change();
-- <<< END supabase\migrations\202611110007_clinical_encounters.sql


-- >>> BEGIN supabase\migrations\202611110008_notifications.sql
-- In-app, user-scoped operational notifications. Delivery is inside the app only.

create table public.clinic_notifications (
  id uuid primary key default gen_random_uuid(),
  clinic_id uuid not null references public.clinics(id) on delete restrict,
  recipient_id uuid not null references public.profiles(id) on delete restrict,
  kind text not null check (length(kind) between 1 and 60),
  title text not null check (length(trim(title)) between 1 and 160),
  message text not null check (length(trim(message)) between 1 and 500),
  href text not null check (href ~ '^/[a-zA-Z0-9/_?=&.-]*$'),
  source_table text not null check (length(source_table) between 1 and 80),
  source_id uuid not null,
  created_at timestamptz not null default now(),
  read_at timestamptz,
  foreign key (clinic_id, recipient_id) references public.clinic_memberships(clinic_id, user_id),
  unique (clinic_id, recipient_id, source_table, source_id)
);
create index clinic_notifications_inbox_idx on public.clinic_notifications(recipient_id, created_at desc) where read_at is null;
alter table public.clinic_notifications enable row level security;
create policy notifications_recipient_read on public.clinic_notifications for select to authenticated
  using (recipient_id = (select auth.uid()) and public.has_clinic_role(clinic_id));
revoke all on public.clinic_notifications from anon, authenticated;
grant select on public.clinic_notifications to authenticated;

create or replace function public.mark_notification_read(target_notification uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.clinic_notifications n set read_at = now()
  where n.id = target_notification and n.recipient_id = (select auth.uid())
    and n.read_at is null and public.has_clinic_role(n.clinic_id);
end;
$$;
revoke all on function public.mark_notification_read(uuid) from public;
grant execute on function public.mark_notification_read(uuid) to authenticated;

create or replace function public.mark_all_notifications_read()
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.clinic_notifications n set read_at = now()
  where n.recipient_id = (select auth.uid()) and n.read_at is null and public.has_clinic_role(n.clinic_id);
end;
$$;
revoke all on function public.mark_all_notifications_read() from public;
grant execute on function public.mark_all_notifications_read() to authenticated;

create or replace function public.notify_clinic_members(target_clinic uuid, target_roles public.clinic_role[], target_kind text,
  target_title text, target_message text, target_href text, target_table text, target_source uuid, excluded_user uuid default null)
returns void language sql security definer set search_path = '' as $$
  insert into public.clinic_notifications (clinic_id, recipient_id, kind, title, message, href, source_table, source_id)
  select target_clinic, m.user_id, target_kind, target_title, target_message, target_href, target_table, target_source
  from public.clinic_memberships m join public.profiles p on p.id = m.user_id and p.active
  where m.clinic_id = target_clinic and m.active and m.role = any(target_roles)
    and (excluded_user is null or m.user_id <> excluded_user)
  on conflict (clinic_id, recipient_id, source_table, source_id) do nothing;
$$;
revoke all on function public.notify_clinic_members(uuid, public.clinic_role[], text, text, text, text, text, uuid, uuid) from public, anon, authenticated;

create or replace function public.notify_appointment_booking()
returns trigger language plpgsql security definer set search_path = '' as $$
declare doctor_profile uuid;
begin
  perform public.notify_clinic_members(new.clinic_id, array['super_admin','admin','receptionist']::public.clinic_role[],
    'appointment', 'Appointment booked', 'A new appointment was added to the clinic schedule.', '/appointments', 'appointments', new.id, new.created_by);
  select d.profile_id into doctor_profile from public.doctors d where d.clinic_id = new.clinic_id and d.id = new.doctor_id;
  if doctor_profile is not null and doctor_profile is distinct from new.created_by and exists (
    select 1 from public.clinic_memberships m join public.profiles p on p.id = m.user_id and p.active
      where m.clinic_id = new.clinic_id and m.user_id = doctor_profile and m.active
  ) then
    insert into public.clinic_notifications (clinic_id, recipient_id, kind, title, message, href, source_table, source_id)
    values (new.clinic_id, doctor_profile, 'appointment', 'Appointment assigned',
      'An appointment was added to your schedule.', '/appointments', 'appointments', new.id)
    on conflict (clinic_id, recipient_id, source_table, source_id) do nothing;
  end if;
  return new;
end;
$$;
create trigger appointment_notify_after_insert after insert on public.appointments
for each row execute function public.notify_appointment_booking();

create or replace function public.notify_lab_order_created()
returns trigger language plpgsql security definer set search_path = '' as $$
declare doctor_profile uuid;
begin
  perform public.notify_clinic_members(new.clinic_id, array['super_admin','admin','lab_technician']::public.clinic_role[],
    'laboratory', 'New laboratory order', 'A laboratory order is waiting for processing.', '/laboratory', 'lab_orders', new.id, new.created_by);
  select d.profile_id into doctor_profile from public.doctors d
    where d.clinic_id = new.clinic_id and d.id = new.ordered_by_doctor_id;
  if doctor_profile is not null and exists (
    select 1 from public.clinic_memberships m join public.profiles p on p.id = m.user_id and p.active
      where m.clinic_id = new.clinic_id and m.user_id = doctor_profile and m.active
  ) then
    insert into public.clinic_notifications (clinic_id, recipient_id, kind, title, message, href, source_table, source_id)
    values (new.clinic_id, doctor_profile, 'laboratory', 'Laboratory order placed',
      'Your requested laboratory order was recorded.', '/laboratory', 'lab_orders', new.id)
    on conflict (clinic_id, recipient_id, source_table, source_id) do nothing;
  end if;
  return new;
end;
$$;
create trigger lab_order_notify_after_insert after insert on public.lab_orders
for each row execute function public.notify_lab_order_created();

create or replace function public.notify_imaging_order_created()
returns trigger language plpgsql security definer set search_path = '' as $$
declare doctor_profile uuid;
begin
  perform public.notify_clinic_members(new.clinic_id, array['super_admin','admin','radiology_technician','radiologist']::public.clinic_role[],
    'imaging', 'New imaging order', 'An imaging order is waiting to be scheduled.', '/imaging', 'imaging_orders', new.id, new.created_by);
  select d.profile_id into doctor_profile from public.doctors d
    where d.clinic_id = new.clinic_id and d.id = new.ordered_by_doctor_id;
  if doctor_profile is not null and exists (
    select 1 from public.clinic_memberships m join public.profiles p on p.id = m.user_id and p.active
      where m.clinic_id = new.clinic_id and m.user_id = doctor_profile and m.active
  ) then
    insert into public.clinic_notifications (clinic_id, recipient_id, kind, title, message, href, source_table, source_id)
    values (new.clinic_id, doctor_profile, 'imaging', 'Imaging order placed',
      'Your requested imaging order was recorded.', '/imaging', 'imaging_orders', new.id)
    on conflict (clinic_id, recipient_id, source_table, source_id) do nothing;
  end if;
  return new;
end;
$$;
create trigger imaging_order_notify_after_insert after insert on public.imaging_orders
for each row execute function public.notify_imaging_order_created();

create trigger clinic_notifications_audit after insert or update on public.clinic_notifications
for each row execute function public.audit_row_change();
-- <<< END supabase\migrations\202611110008_notifications.sql


-- >>> BEGIN supabase\migrations\202611110009_staff_administration.sql
-- Clinic-scoped role administration for already provisioned Auth users.

create policy profile_clinic_admin_read on public.profiles for select to authenticated
  using (exists (
    select 1 from public.clinic_memberships m
    where m.user_id = profiles.id and m.active
      and public.has_clinic_role(m.clinic_id, array['super_admin','admin']::public.clinic_role[])
  ));

create or replace function public.manage_clinic_membership(target_clinic uuid, target_user uuid,
  target_role public.clinic_role, target_active boolean)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := (select auth.uid());
  actor_role public.clinic_role;
  current_role public.clinic_role;
  current_active boolean;
  membership_id uuid;
  elevated_count integer;
begin
  select m.role into actor_role from public.clinic_memberships m
    where m.clinic_id = target_clinic and m.user_id = actor and m.active limit 1;
  if actor_role is null or actor_role not in ('super_admin','admin') or not exists (
    select 1 from public.clinics c where c.id = target_clinic and c.active
  ) then raise exception 'Clinic administrator access required.' using errcode = '42501'; end if;
  if not exists (select 1 from public.profiles p where p.id = target_user and p.active) then
    raise exception 'An active staff profile is required. Create the Auth user and profile before assigning clinic access.' using errcode = '23503';
  end if;
  if actor_role = 'admin' and target_role in ('super_admin','admin') then
    raise exception 'Only a super administrator can assign administrator roles.' using errcode = '42501';
  end if;
  select m.id, m.role, m.active into membership_id, current_role, current_active
    from public.clinic_memberships m where m.clinic_id = target_clinic and m.user_id = target_user for update;
  if current_role in ('super_admin','admin') and (not target_active or target_role not in ('super_admin','admin')) then
    select count(*) into elevated_count from public.clinic_memberships m
      where m.clinic_id = target_clinic and m.active and m.role in ('super_admin','admin')
        and m.user_id <> target_user;
    if elevated_count < 1 then raise exception 'The clinic must keep at least one active administrator.' using errcode = '23514'; end if;
  end if;
  if membership_id is null then
    insert into public.clinic_memberships (clinic_id, user_id, role, active)
      values (target_clinic, target_user, target_role, target_active) returning id into membership_id;
  else
    update public.clinic_memberships set role = target_role, active = target_active where id = membership_id;
  end if;
  return membership_id;
end;
$$;
revoke all on function public.manage_clinic_membership(uuid, uuid, public.clinic_role, boolean) from public;
grant execute on function public.manage_clinic_membership(uuid, uuid, public.clinic_role, boolean) to authenticated;

create trigger clinic_memberships_audit after insert or update on public.clinic_memberships
for each row execute function public.audit_row_change();
-- <<< END supabase\migrations\202611110009_staff_administration.sql


-- >>> BEGIN supabase\migrations\202611110010_reports.sql
-- Aggregated clinic reports. Results contain counts and totals, not patient identifiers.

create or replace function public.clinic_report_summary(target_clinic uuid, target_start date, target_end date)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  clinic_tz text;
  result jsonb;
begin
  if not public.has_clinic_role(target_clinic, array['super_admin','admin','accountant','auditor']::public.clinic_role[])
    or target_start is null or target_end is null or target_end <= target_start or target_end - target_start > 366 then
    raise exception 'Report access or date range is invalid.' using errcode = '42501';
  end if;
  select c.timezone into clinic_tz from public.clinics c where c.id = target_clinic and c.active;
  if clinic_tz is null then raise exception 'Clinic is unavailable.' using errcode = '42501'; end if;
  select jsonb_build_object(
    'appointments', (select count(*) from public.appointments a where a.clinic_id = target_clinic
      and (a.starts_at at time zone clinic_tz)::date >= target_start and (a.starts_at at time zone clinic_tz)::date < target_end),
    'patients_registered', (select count(*) from public.patients p where p.clinic_id = target_clinic
      and p.registration_date >= target_start and p.registration_date < target_end and p.archived_at is null),
    'lab_orders', (select count(*) from public.lab_orders l where l.clinic_id = target_clinic
      and (l.ordered_at at time zone clinic_tz)::date >= target_start and (l.ordered_at at time zone clinic_tz)::date < target_end),
    'imaging_orders', (select count(*) from public.imaging_orders i where i.clinic_id = target_clinic
      and (i.ordered_at at time zone clinic_tz)::date >= target_start and (i.ordered_at at time zone clinic_tz)::date < target_end),
    'billed_amount', (select coalesce(sum(b.total_amount),0) from public.bill_balances b
      where b.clinic_id = target_clinic and b.issued_at is not null
        and (b.issued_at at time zone clinic_tz)::date >= target_start and (b.issued_at at time zone clinic_tz)::date < target_end),
    'collected_amount', (select coalesce(sum(case when p.entry_type = 'payment' then p.amount else -p.amount end),0)
      from public.payments p where p.clinic_id = target_clinic
        and (p.occurred_at at time zone clinic_tz)::date >= target_start and (p.occurred_at at time zone clinic_tz)::date < target_end),
    'outstanding_amount', (select coalesce(sum(b.balance_due),0) from public.bill_balances b
      where b.clinic_id = target_clinic and b.issued_at is not null
        and (b.issued_at at time zone clinic_tz)::date >= target_start and (b.issued_at at time zone clinic_tz)::date < target_end),
    'expenses_amount', (select coalesce(sum(e.amount),0) from public.expenses e
      where e.clinic_id = target_clinic and e.spent_at >= target_start and e.spent_at < target_end)
  ) into result;
  return result;
end;
$$;
revoke all on function public.clinic_report_summary(uuid, date, date) from public;
grant execute on function public.clinic_report_summary(uuid, date, date) to authenticated;

create or replace function public.clinic_daily_financial_report(target_clinic uuid, target_start date, target_end date)
returns table(report_date date, billed_amount numeric, collected_amount numeric, expense_amount numeric)
language plpgsql security definer set search_path = '' as $$
declare clinic_tz text;
begin
  if not public.has_clinic_role(target_clinic, array['super_admin','admin','accountant','auditor']::public.clinic_role[])
    or target_start is null or target_end is null or target_end <= target_start or target_end - target_start > 366 then
    raise exception 'Report access or date range is invalid.' using errcode = '42501';
  end if;
  select c.timezone into clinic_tz from public.clinics c where c.id = target_clinic and c.active;
  if clinic_tz is null then raise exception 'Clinic is unavailable.' using errcode = '42501'; end if;
  return query
  with days as (
    select day_value::date as d
    from generate_series(target_start::timestamp, (target_end - 1)::timestamp, interval '1 day') as series(day_value)
  ), billed as (
    select (b.issued_at at time zone clinic_tz)::date as d, sum(b.total_amount)::numeric as amount
    from public.bill_balances b where b.clinic_id = target_clinic and b.issued_at is not null
      and (b.issued_at at time zone clinic_tz)::date >= target_start and (b.issued_at at time zone clinic_tz)::date < target_end
    group by 1
  ), collected as (
    select (p.occurred_at at time zone clinic_tz)::date as d,
      sum(case when p.entry_type = 'payment' then p.amount else -p.amount end)::numeric as amount
    from public.payments p where p.clinic_id = target_clinic
      and (p.occurred_at at time zone clinic_tz)::date >= target_start and (p.occurred_at at time zone clinic_tz)::date < target_end
    group by 1
  ), expenses as (
    select e.spent_at as d, sum(e.amount)::numeric as amount
    from public.expenses e where e.clinic_id = target_clinic and e.spent_at >= target_start and e.spent_at < target_end
    group by 1
  )
  select days.d, coalesce(billed.amount,0), coalesce(collected.amount,0), coalesce(expenses.amount,0)
  from days left join billed on billed.d = days.d left join collected on collected.d = days.d
    left join expenses on expenses.d = days.d order by days.d;
end;
$$;
revoke all on function public.clinic_daily_financial_report(uuid, date, date) from public;
grant execute on function public.clinic_daily_financial_report(uuid, date, date) to authenticated;
-- <<< END supabase\migrations\202611110010_reports.sql


-- >>> BEGIN supabase\migrations\202611110011_clinic_settings.sql
-- Clinic identity and department configuration with explicit administrator RPC.

create or replace function public.update_clinic_settings(target_clinic uuid, target_name text, target_slug text,
  target_timezone text, target_phone text default null, target_email text default null, target_address text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.has_clinic_role(target_clinic, array['super_admin','admin']::public.clinic_role[])
    or length(trim(coalesce(target_name,''))) not between 2 and 180
    or target_slug is null or target_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$'
    or target_timezone is null or not exists (select 1 from pg_catalog.pg_timezone_names z where z.name = target_timezone)
    or length(coalesce(target_phone,'')) > 32 or length(coalesce(target_email,'')) > 254
    or length(coalesce(target_address,'')) > 500 then
    raise exception 'Clinic settings are invalid or you are not authorized.' using errcode = '42501';
  end if;
  update public.clinics set name = trim(target_name), slug = target_slug, timezone = target_timezone,
    phone = nullif(trim(coalesce(target_phone,'')),''), email = nullif(lower(trim(coalesce(target_email,''))),''),
    address = nullif(trim(coalesce(target_address,'')),'')
  where id = target_clinic;
end;
$$;
revoke all on function public.update_clinic_settings(uuid, text, text, text, text, text, text) from public;
grant execute on function public.update_clinic_settings(uuid, text, text, text, text, text, text) to authenticated;

create or replace function public.audit_clinic_settings()
returns trigger language plpgsql security definer set search_path = '' as $$
declare actor_role public.clinic_role;
begin
  select m.role into actor_role from public.clinic_memberships m
    where m.clinic_id = new.id and m.user_id = (select auth.uid()) and m.active limit 1;
  insert into public.audit_logs (clinic_id, actor_id, actor_role, action, module, record_id, previous_values, new_values)
  values (new.id, (select auth.uid()), actor_role, 'update', 'clinics', new.id::text,
    jsonb_build_object('name',old.name,'slug',old.slug,'timezone',old.timezone,'phone',old.phone,'email',old.email,'address',old.address),
    jsonb_build_object('name',new.name,'slug',new.slug,'timezone',new.timezone,'phone',new.phone,'email',new.email,'address',new.address));
  return new;
end;
$$;
create trigger clinics_audit_settings after update of name, slug, timezone, phone, email, address on public.clinics
for each row execute function public.audit_clinic_settings();

create trigger departments_audit_settings after insert or update or delete on public.departments
for each row execute function public.audit_row_change();
revoke insert, update on public.departments from authenticated;
grant insert (clinic_id, name, active), update (name, active) on public.departments to authenticated;
-- <<< END supabase\migrations\202611110011_clinic_settings.sql

