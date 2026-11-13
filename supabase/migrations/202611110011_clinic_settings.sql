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
