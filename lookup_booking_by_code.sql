-- Public lookup returns only date and time for a still-active reservation.
-- Anyone who knows a valid booking code can call this function.
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

revoke all on function public.get_booking_by_code(text) from public;
grant execute on function public.get_booking_by_code(text) to anon, authenticated;
