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
