-- ClinicCare Pro custom application authentication foundation.
-- Additive and data-preserving. Apply only after the matching application
-- auth/RLS refactor is deployed; this migration alone does not switch the UI.

begin;

create extension if not exists pgcrypto;

create table if not exists public.app_users (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  password_hash text,
  full_name text not null check (length(trim(full_name)) between 2 and 160),
  phone text,
  active boolean not null default true,
  must_reset_password boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint app_users_email_normalized check (email = lower(trim(email))),
  constraint app_users_email_valid check (email ~* '^[A-Z0-9.!#$%&''*+/=?^_`{|}~-]+@[A-Z0-9.-]+\.[A-Z]{2,}$')
);

create unique index if not exists app_users_email_unique on public.app_users (email);

-- Preserve existing account/profile UUIDs so clinic memberships remain valid.
-- Existing Auth password hashes are intentionally not copied; they are not
-- readable from auth.users. Those accounts must set a new app password.
insert into public.app_users (id, email, full_name, phone, active, must_reset_password)
select u.id,
       lower(trim(u.email)),
       coalesce(nullif(trim(p.full_name), ''), nullif(trim(u.raw_user_meta_data ->> 'full_name'), ''), 'Clinic user'),
       p.phone,
       coalesce(p.active, true),
       true
from auth.users u
left join public.profiles p on p.id = u.id
where u.email is not null
on conflict (id) do update
set email = excluded.email,
    full_name = excluded.full_name,
    phone = excluded.phone,
    active = excluded.active,
    must_reset_password = true,
    updated_at = now();

-- Move the profile identity FK from Supabase Auth to the application user table.
do $$
declare fk record;
begin
  for fk in
    select conname
    from pg_constraint
    where conrelid = 'public.profiles'::regclass
      and contype = 'f'
      and confrelid = 'auth.users'::regclass
  loop
    execute format('alter table public.profiles drop constraint %I', fk.conname);
  end loop;
end;
$$;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.profiles'::regclass
      and conname = 'profiles_app_users_id_fkey'
  ) then
    alter table public.profiles
      add constraint profiles_app_users_id_fkey
      foreign key (id) references public.app_users(id) on delete restrict;
  end if;
end;
$$;

create table if not exists public.app_sessions (
  token_hash text primary key check (token_hash ~ '^[0-9a-f]{64}$'),
  user_id uuid not null references public.app_users(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  last_seen_at timestamptz not null default now(),
  check (expires_at > created_at)
);
create index if not exists app_sessions_user_active_idx
  on public.app_sessions(user_id, expires_at) where revoked_at is null;

create table if not exists public.app_login_attempts (
  id bigint generated always as identity primary key,
  email text not null,
  attempted_at timestamptz not null default now(),
  succeeded boolean not null default false
);
create index if not exists app_login_attempts_email_time_idx
  on public.app_login_attempts(email, attempted_at desc);

alter table public.app_users enable row level security;
alter table public.app_sessions enable row level security;
alter table public.app_login_attempts enable row level security;
revoke all on public.app_users, public.app_sessions, public.app_login_attempts from public, anon, authenticated;

create or replace function public.current_app_user_id()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  request_headers jsonb;
  raw_token text;
  result uuid;
begin
  request_headers := coalesce(nullif(current_setting('request.headers', true), ''), '{}')::jsonb;
  raw_token := request_headers ->> 'x-clinic-session';
  if raw_token is null or length(raw_token) <> 64 or raw_token !~ '^[0-9a-f]{64}$' then
    return null;
  end if;
  select s.user_id into result
  from public.app_sessions s
  join public.app_users u on u.id = s.user_id and u.active
  join public.profiles p on p.id = u.id and p.active
  where s.token_hash = encode(public.digest(raw_token, 'sha256'), 'hex')
    and s.revoked_at is null
    and s.expires_at > now();
  return result;
exception when others then
  return null;
end;
$$;

create or replace function public.app_login(login_email text, login_password text)
returns table (session_token text, user_id uuid, user_email text, user_full_name text, force_password_reset boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  normalized_email text := lower(trim(coalesce(login_email, '')));
  account public.app_users%rowtype;
  failures integer;
  token_value text;
begin
  if length(normalized_email) > 254 or length(coalesce(login_password, '')) > 128 then
    raise exception 'Invalid email or password.' using errcode = '28000';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(normalized_email, 0));
  delete from public.app_login_attempts where attempted_at < now() - interval '1 day';
  select count(*) into failures
  from public.app_login_attempts
  where email = normalized_email and not succeeded
    and attempted_at > now() - interval '15 minutes';
  if failures >= 8 then
    raise exception 'Too many login attempts. Try again later.' using errcode = '28000';
  end if;

  select * into account from public.app_users where email = normalized_email and active;
  if account.id is null or account.password_hash is null
     or public.crypt(login_password, account.password_hash) <> account.password_hash
     or not exists (select 1 from public.profiles p where p.id = account.id and p.active) then
    insert into public.app_login_attempts(email, succeeded) values (normalized_email, false);
    raise exception 'Invalid email or password.' using errcode = '28000';
  end if;

  token_value := encode(public.gen_random_bytes(32), 'hex');
  insert into public.app_sessions(token_hash, user_id, expires_at)
    values (encode(public.digest(token_value, 'sha256'), 'hex'), account.id, now() + interval '12 hours');
  insert into public.app_login_attempts(email, succeeded) values (normalized_email, true);
  return query select token_value, account.id, account.email, account.full_name, account.must_reset_password;
end;
$$;

create or replace function public.app_logout()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  request_headers jsonb;
  raw_token text;
begin
  request_headers := coalesce(nullif(current_setting('request.headers', true), ''), '{}')::jsonb;
  raw_token := request_headers ->> 'x-clinic-session';
  if raw_token is not null and raw_token ~ '^[0-9a-f]{64}$' then
    update public.app_sessions
      set revoked_at = now()
      where token_hash = encode(public.digest(raw_token, 'sha256'), 'hex')
        and revoked_at is null;
  end if;
end;
$$;

revoke all on function public.current_app_user_id() from public;
revoke all on function public.app_login(text, text) from public;
revoke all on function public.app_logout() from public;
grant execute on function public.current_app_user_id() to anon, authenticated;
grant execute on function public.app_login(text, text) to anon, authenticated;
grant execute on function public.app_logout() to anon, authenticated;

commit;
