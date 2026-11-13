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
