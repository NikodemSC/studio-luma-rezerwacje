-- Enable immediate customer accounts and attach bookings to the signed-in user.
-- Run once in Supabase SQL Editor after deploying the matching frontend.

alter table public.bookings
  add column if not exists customer_user_id uuid references auth.users(id) on delete set null;

create index if not exists bookings_customer_user_date_idx
  on public.bookings (customer_user_id, booking_date desc, booking_time desc);

drop policy if exists "Customers can read their own bookings" on public.bookings;
create policy "Customers can read their own bookings"
  on public.bookings for select to authenticated
  using (customer_user_id = auth.uid());

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

revoke all on function public.create_booking(text, text, text, date, time) from public, anon;
grant execute on function public.create_booking(text, text, text, date, time) to authenticated;
