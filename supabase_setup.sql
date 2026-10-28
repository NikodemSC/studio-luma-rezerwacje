-- Studio Luma demo booking backend.
-- Run this only in the Supabase project created for this booking site.

create extension if not exists pgcrypto;

create table if not exists public.booking_services (
  id text primary key,
  name text not null,
  duration_minutes integer not null check (duration_minutes > 0),
  price_pln numeric(8,2) not null check (price_pln >= 0),
  active boolean not null default true
);

insert into public.booking_services (id, name, duration_minutes, price_pln, active)
values
  ('mani', 'Manicure hybrydowy', 90, 120, true),
  ('zel', 'Uzupełnienie żelowe', 120, 160, true),
  ('rzęsy', 'Stylizacja rzęs', 120, 180, true)
on conflict (id) do update
set name = excluded.name,
    duration_minutes = excluded.duration_minutes,
    price_pln = excluded.price_pln,
    active = excluded.active;

create table if not exists public.booking_owner_access (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.bookings (
  id uuid primary key default gen_random_uuid(),
  booking_code text not null unique,
  guest_name text not null check (length(trim(guest_name)) between 2 and 100),
  guest_phone text not null check (length(trim(guest_phone)) between 7 and 30),
  service_id text not null references public.booking_services(id),
  service_name text not null,
  duration_minutes integer not null check (duration_minutes > 0),
  price_pln numeric(8,2) not null check (price_pln >= 0),
  booking_date date not null,
  booking_time time not null,
  customer_user_id uuid references auth.users(id) on delete set null,
  status text not null default 'pending' check (status in ('pending', 'confirmed', 'rejected')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);

create index if not exists bookings_date_status_idx
  on public.bookings (booking_date, status, booking_time);
create index if not exists bookings_phone_status_idx
  on public.bookings (guest_phone, status);
create index if not exists bookings_customer_user_date_idx
  on public.bookings (customer_user_id, booking_date desc, booking_time desc);

alter table public.booking_services enable row level security;
alter table public.booking_owner_access enable row level security;
alter table public.bookings enable row level security;

create or replace function public.is_booking_owner()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.booking_owner_access
    where user_id = auth.uid()
  );
$$;

revoke all on function public.is_booking_owner() from public;
grant execute on function public.is_booking_owner() to authenticated;

drop policy if exists "Active services are public" on public.booking_services;
create policy "Active services are public"
  on public.booking_services for select to anon, authenticated
  using (active);

drop policy if exists "Owners can read their access row" on public.booking_owner_access;
create policy "Owners can read their access row"
  on public.booking_owner_access for select to authenticated
  using (user_id = auth.uid());

drop policy if exists "Owners can read bookings" on public.bookings;
create policy "Owners can read bookings"
  on public.bookings for select to authenticated
  using (public.is_booking_owner());

drop policy if exists "Customers can read their own bookings" on public.bookings;
create policy "Customers can read their own bookings"
  on public.bookings for select to authenticated
  using (customer_user_id = auth.uid());

drop policy if exists "Owners can change booking status" on public.bookings;
create policy "Owners can change booking status"
  on public.bookings for update to authenticated
  using (public.is_booking_owner())
  with check (public.is_booking_owner());

revoke all on public.booking_services from anon, authenticated;
grant select on public.booking_services to anon, authenticated;
revoke all on public.booking_owner_access from anon, authenticated;
grant select on public.booking_owner_access to authenticated;
revoke all on public.bookings from anon, authenticated;
grant select on public.bookings to authenticated;
grant update (status) on public.bookings to authenticated;

create or replace function public.get_busy_booking_slots(p_date date)
returns table (slot_time time, duration_minutes integer)
language sql
stable
security definer
set search_path = public
as $$
  select b.booking_time, b.duration_minutes
  from public.bookings b
  where b.booking_date = p_date
    and b.status in ('pending', 'confirmed')
    and b.expires_at > now()
  order by b.booking_time;
$$;

create or replace function public.create_booking(
  p_guest_name text,
  p_guest_phone text,
  p_service_id text,
  p_booking_date date,
  p_booking_time time
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_service public.booking_services%rowtype;
  v_expires_at timestamptz;
  v_code text;
  v_attempt integer;
  v_start timestamp;
  v_end timestamp;
  v_customer_user_id uuid := auth.uid();
begin
  if v_customer_user_id is null then
    raise exception 'Zaloguj się lub załóż konto, aby zarezerwować termin.' using errcode = '28000';
  end if;
  if p_guest_name is null or length(trim(p_guest_name)) not between 2 and 100 then
    raise exception 'Podaj prawidłowe imię i nazwisko.' using errcode = '22023';
  end if;
  if p_guest_phone is null or length(trim(p_guest_phone)) not between 7 and 30 then
    raise exception 'Podaj prawidłowy numer telefonu.' using errcode = '22023';
  end if;
  if p_booking_date < (now() at time zone 'Europe/Warsaw')::date then
    raise exception 'Wybrany dzień już minął.' using errcode = '22023';
  end if;
  if extract(dow from p_booking_date) in (0, 1) then
    raise exception 'Studio jest zamknięte w niedzielę i poniedziałek.' using errcode = '22023';
  end if;
  if p_booking_time < time '09:00' or p_booking_time >= time '18:00' then
    raise exception 'Wybierz godzinę otwarcia studia.' using errcode = '22023';
  end if;

  v_expires_at := (p_booking_date::timestamp + time '22:00') at time zone 'Europe/Warsaw';
  if v_expires_at <= now() then
    raise exception 'Czas na rezerwację tego dnia już minął.' using errcode = '22023';
  end if;

  select * into v_service
  from public.booking_services
  where id = p_service_id and active;
  if not found then
    raise exception 'Wybrana usługa nie jest dostępna.' using errcode = '22023';
  end if;

  -- Serialize booking attempts for a given date before checking for overlaps.
  perform pg_advisory_xact_lock(hashtext(p_booking_date::text)::bigint);

  if exists (
    select 1 from public.bookings b
    where b.customer_user_id = v_customer_user_id
      and b.status = 'pending'
      and b.expires_at > now()
  ) then
    raise exception 'Masz już oczekującą rezerwację.' using errcode = '23505';
  end if;

  v_start := p_booking_date + p_booking_time;
  v_end := v_start + make_interval(mins => v_service.duration_minutes);
  if v_end > p_booking_date + time '18:00' then
    raise exception 'Ta usługa nie mieści się w godzinach pracy studia.' using errcode = '22023';
  end if;

  if exists (
    select 1 from public.bookings b
    where b.booking_date = p_booking_date
      and b.status in ('pending', 'confirmed')
      and b.expires_at > now()
      and v_start < (b.booking_date + b.booking_time + make_interval(mins => b.duration_minutes))
      and (b.booking_date + b.booking_time) < v_end
  ) then
    raise exception 'Ten termin został właśnie zajęty. Wybierz inną godzinę.' using errcode = '23505';
  end if;

  -- Two random letters and three digits. The unique constraint on booking_code
  -- is the final authority; retry if a code has already been used.
  for v_attempt in 1..100 loop
    v_code :=
      substr('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz', floor(random() * 52)::integer + 1, 1) ||
      substr('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz', floor(random() * 52)::integer + 1, 1) ||
      lpad(floor(random() * 1000)::integer::text, 3, '0');

    insert into public.bookings (
      booking_code, guest_name, guest_phone, service_id, service_name,
      duration_minutes, price_pln, booking_date, booking_time, expires_at, customer_user_id
    ) values (
      v_code, trim(p_guest_name), trim(p_guest_phone), v_service.id, v_service.name,
      v_service.duration_minutes, v_service.price_pln, p_booking_date, p_booking_time, v_expires_at,
      v_customer_user_id
    ) on conflict (booking_code) do nothing
    returning booking_code into v_code;

    if found then
      return v_code;
    end if;
  end loop;

  raise exception 'Nie udało się wygenerować unikalnego kodu rezerwacji. Spróbuj ponownie.'
    using errcode = '23505';
end;
$$;

create or replace function public.get_booking_by_code(p_booking_code text)
returns table (booking_date date, booking_time time)
language sql
stable
security definer
set search_path = public
as $$
  select b.booking_date, b.booking_time
  from public.bookings b
  where b.booking_code = trim(p_booking_code)
    and b.status in ('pending', 'confirmed')
    and b.expires_at > now()
  limit 1;
$$;

revoke all on function public.get_busy_booking_slots(date) from public;
revoke all on function public.create_booking(text, text, text, date, time) from public;
revoke all on function public.get_booking_by_code(text) from public;
grant execute on function public.get_busy_booking_slots(date) to anon, authenticated;
grant execute on function public.create_booking(text, text, text, date, time) to authenticated;
grant execute on function public.get_booking_by_code(text) to anon, authenticated;
