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
