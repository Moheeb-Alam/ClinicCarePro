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
