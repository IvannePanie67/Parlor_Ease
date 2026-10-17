-- ParlorEase Supabase database setup
-- Run this entire file in Supabase Dashboard > SQL Editor > New query.
-- Authentication is handled by Supabase Auth; never store plaintext passwords in tables.

create extension if not exists pgcrypto;

create type public.app_role as enum ('customer', 'staff', 'admin');
create type public.appointment_status as enum ('pending', 'confirmed', 'completed', 'cancelled');
create type public.staff_status as enum ('available', 'busy', 'off_duty');
create type public.queue_status as enum ('waiting', 'serving', 'completed', 'cancelled');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null check (char_length(trim(full_name)) >= 2),
  phone text,
  role public.app_role not null default 'customer',
  created_at timestamptz not null default now()
);

create table public.customers (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid unique references public.profiles(id) on delete set null,
  full_name text not null check (char_length(trim(full_name)) >= 2),
  email text not null unique,
  phone text,
  visits integer not null default 0 check (visits >= 0),
  created_at timestamptz not null default now()
);

create table public.staff (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid unique references public.profiles(id) on delete set null,
  full_name text not null check (char_length(trim(full_name)) >= 2),
  specialty text not null,
  status public.staff_status not null default 'available',
  created_at timestamptz not null default now()
);

create table public.services (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  category text not null,
  description text,
  price numeric(10,2) not null check (price >= 0),
  duration_minutes integer not null check (duration_minutes > 0),
  image_url text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.appointments (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete restrict,
  service_id uuid not null references public.services(id) on delete restrict,
  staff_id uuid references public.staff(id) on delete set null,
  appointment_date date not null,
  appointment_time time not null,
  status public.appointment_status not null default 'pending',
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.transactions (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid references public.appointments(id) on delete set null,
  customer_id uuid references public.customers(id) on delete set null,
  amount numeric(10,2) not null check (amount >= 0),
  payment_method text not null check (payment_method in ('Cash','GCash','Card','Bank transfer','Other')),
  receipt_number text not null unique default ('PE-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,10))),
  paid_at timestamptz not null default now(),
  notes text
);

create table public.service_queue (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid references public.customers(id) on delete set null,
  service_id uuid not null references public.services(id) on delete restrict,
  staff_id uuid references public.staff(id) on delete set null,
  priority text not null default 'regular' check (priority in ('regular','priority')),
  queue_number bigint generated always as identity unique,
  status public.queue_status not null default 'waiting',
  joined_at timestamptz not null default now(),
  started_at timestamptz,
  completed_at timestamptz
);

create index appointments_date_time_idx on public.appointments(appointment_date, appointment_time);
create index appointments_customer_idx on public.appointments(customer_id);
create index appointments_staff_idx on public.appointments(staff_id);
create index services_category_idx on public.services(category);
create index queue_waiting_idx on public.service_queue(status, priority, joined_at);
create index transactions_paid_at_idx on public.transactions(paid_at);

-- Automatically create a customer profile after signup.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name, phone, role)
  values (
    new.id,
    coalesce(nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''), 'New customer'),
    nullif(new.raw_user_meta_data ->> 'phone', ''),
    'customer'
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

create or replace function public.current_role()
returns public.app_role
language sql
stable
security definer
set search_path = ''
as $$
  select role from public.profiles where id = auth.uid()
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(public.current_role() = 'admin'::public.app_role, false)
$$;

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger appointments_touch_updated_at
before update on public.appointments
for each row execute procedure public.touch_updated_at();


-- Create a customer record for each new customer profile.
create or replace function public.create_customer_for_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  user_email text;
begin
  if new.role = 'customer' then
    select email into user_email from auth.users where id = new.id;
    if user_email is not null then
      insert into public.customers (profile_id, full_name, email, phone)
      values (new.id, new.full_name, user_email, new.phone)
      on conflict (email) do update
        set profile_id = excluded.profile_id,
            full_name = excluded.full_name,
            phone = excluded.phone;
    end if;
  end if;
  return new;
end;
$$;

create trigger profile_create_customer
  after insert on public.profiles
  for each row execute procedure public.create_customer_for_profile();

-- Prevent a normal user from promoting their own role through profile updates.
create or replace function public.protect_profile_role()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.role is distinct from old.role
     and not coalesce(public.is_admin(), false) then
    raise exception 'Only an administrator can change account roles';
  end if;
  return new;
end;
$$;

create trigger profiles_protect_role
  before update on public.profiles
  for each row execute procedure public.protect_profile_role();

-- Turn on Row Level Security for every application table.
alter table public.profiles enable row level security;
alter table public.customers enable row level security;
alter table public.staff enable row level security;
alter table public.services enable row level security;
alter table public.appointments enable row level security;
alter table public.transactions enable row level security;
alter table public.service_queue enable row level security;

-- Profiles: users may see/update their own profile; admins can manage all profiles.
create policy "profiles_read_self_or_admin" on public.profiles
for select to authenticated using (id = auth.uid() or public.is_admin());
create policy "profiles_update_self_or_admin" on public.profiles
for update to authenticated using (id = auth.uid() or public.is_admin())
with check (id = auth.uid() or public.is_admin());

-- Services are public to read; only admins can change the catalog.
create policy "services_read_active" on public.services
for select to anon, authenticated using (is_active or public.is_admin());
create policy "services_admin_manage" on public.services
for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Staff directory can be viewed by signed-in users; admin manages records.
create policy "staff_read_authenticated" on public.staff
for select to authenticated using (true);
create policy "staff_admin_manage" on public.staff
for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Customer records: admins manage all; customers can read/update their own linked record.
create policy "customers_admin_manage" on public.customers
for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "customers_read_own" on public.customers
for select to authenticated using (profile_id = auth.uid());
create policy "customers_update_own" on public.customers
for update to authenticated using (profile_id = auth.uid()) with check (profile_id = auth.uid());

-- Appointments: customers can read/create their own; staff can see assigned appointments; admins manage all.
create policy "appointments_admin_manage" on public.appointments
for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "appointments_customer_read" on public.appointments
for select to authenticated using (
  exists (select 1 from public.customers c where c.id = customer_id and c.profile_id = auth.uid())
);
create policy "appointments_customer_create" on public.appointments
for insert to authenticated with check (
  status = 'pending' and
  exists (select 1 from public.customers c where c.id = customer_id and c.profile_id = auth.uid())
);
create policy "appointments_staff_read" on public.appointments
for select to authenticated using (
  exists (select 1 from public.staff s where s.id = staff_id and s.profile_id = auth.uid())
);
create policy "appointments_staff_update_assigned" on public.appointments
for update to authenticated using (
  exists (select 1 from public.staff s where s.id = staff_id and s.profile_id = auth.uid())
) with check (
  exists (select 1 from public.staff s where s.id = staff_id and s.profile_id = auth.uid())
);

-- Transactions are private to admins by default.
create policy "transactions_admin_manage" on public.transactions
for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Queue is visible to authenticated users; only admins manage it.
create policy "queue_read_authenticated" on public.service_queue
for select to authenticated using (true);
create policy "queue_admin_manage" on public.service_queue
for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Initial salon services. Safe to run more than once.
insert into public.services (name, category, description, price, duration_minutes, image_url)
values
('Haircut & Blow Dry','Hair','A fresh cut finished with a smooth blow dry.',350,60,'https://images.unsplash.com/photo-1522337360788-8b13dee7a37e?auto=format&fit=crop&w=900&q=80'),
('Hair Coloring','Hair','Personalized color for a refreshed look.',1200,120,'https://images.unsplash.com/photo-1560066984-138dadb4c035?auto=format&fit=crop&w=900&q=80'),
('Classic Manicure','Nails','Neat shaping and classic nail care.',300,45,'https://images.unsplash.com/photo-1610992015732-2449b76344bc?auto=format&fit=crop&w=900&q=80'),
('Gel Manicure','Nails','A glossy finish with long-lasting color.',550,60,'https://images.unsplash.com/photo-1610992015732-2449b76344bc?auto=format&fit=crop&w=900&q=80'),
('Facial Treatment','Skin','A relaxing facial for a refreshed feeling.',700,60,'https://images.unsplash.com/photo-1570172619644-dfd03ed5d881?auto=format&fit=crop&w=900&q=80')
on conflict (name) do nothing;

-- IMPORTANT: After creating your own account, promote the intended admin manually
-- in the SQL editor. Replace the email with your actual admin email:
-- update public.profiles p set role = 'admin'
-- from auth.users u where p.id = u.id and lower(u.email) = lower('your-admin@email.com');
