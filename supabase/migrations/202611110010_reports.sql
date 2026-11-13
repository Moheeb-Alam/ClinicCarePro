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
