-- ParlorEase patch. Run ONCE in Supabase SQL Editor, AFTER supabase-schema.sql.

alter table public.transactions add column if not exists service_name text;
alter table public.staff add column if not exists email text;
create unique index if not exists staff_email_key on public.staff (lower(email)) where email is not null;

-- Block double-booking: one active booking per staff member per time slot.
create unique index if not exists appointments_no_double_booking
  on public.appointments (staff_id, appointment_date, appointment_time)
  where staff_id is not null and status in ('pending','confirmed');

-- Staff can read the customers on their own appointments (helper avoids recursive RLS).
create or replace function public.staff_serves_customer(cid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.appointments a
    join public.staff s on s.id = a.staff_id
    where a.customer_id = cid and s.profile_id = auth.uid())
$$;
create policy "customers_staff_read" on public.customers
for select to authenticated using (public.staff_serves_customer(id));

-- Customers can cancel their own pending/confirmed appointments.
create policy "appointments_customer_cancel" on public.appointments
for update to authenticated
using (status in ('pending','confirmed') and exists (select 1 from public.customers c where c.id = customer_id and c.profile_id = auth.uid()))
with check (status = 'cancelled' and exists (select 1 from public.customers c where c.id = customer_id and c.profile_id = auth.uid()));

-- Admin-only: give a registered user the staff role and link them to their staff record by email.
create or replace function public.link_staff_by_email(p_email text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare uid uuid;
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  select id into uid from auth.users where lower(email) = lower(p_email);
  if uid is null then return false; end if;
  update public.profiles set role = 'staff' where id = uid;
  update public.staff set profile_id = uid where lower(email) = lower(p_email);
  return true;
end;
$$;
revoke all on function public.link_staff_by_email(text) from public, anon;
grant execute on function public.link_staff_by_email(text) to authenticated;
