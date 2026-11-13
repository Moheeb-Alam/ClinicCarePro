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

