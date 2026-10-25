-- LearnDrive 2.0
-- Migration 005: Payment/account hardening
--
-- Follow-up safeguards for Stripe checkout lifecycle and account deletion.
-- No pricing changes. No external calendar sync.

begin;

-- =========================================================
-- PAYMENT SLOTS
-- Treat stale Stripe readiness as unavailable, matching payment_prepare.
-- =========================================================

create or replace function public.payment_slots(
  p_instructor uuid,
  p_day date,
  p_duration_minutes integer
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  result jsonb;
  rate integer;
  lesson integer;
  booking_fee integer := public.payment_booking_fee_pence();
  commission integer;
begin
  if p_day is null
     or p_day < current_date
     or p_day > current_date + 88
     or p_duration_minutes is null
     or p_duration_minutes < 30
     or p_duration_minutes > 240
     or p_duration_minutes % 30 <> 0 then
    raise exception 'Invalid lesson dates';
  end if;

  select i.hourly_rate_pence
  into rate
  from public.instructor_profiles i
  join public.profiles p
    on p.id = i.user_id
  where i.user_id = p_instructor
    and i.approved = true
    and i.accepting_new_pupils = true
    and p.account_status = 'active';

  if rate is null
     or rate < 1000
     or rate > 100000 then
    raise exception 'Instructor unavailable';
  end if;

  if not exists (
    select 1
    from public.stripe_instructors
    where user_id = p_instructor
      and ready = true
      and checked_at > now() - interval '5 minutes'
  ) then
    return jsonb_build_object(
      'slots','[]'::jsonb,
      'ready',false
    );
  end if;

  lesson := round(
    rate::numeric * p_duration_minutes::numeric / 60
  )::integer;

  commission := public.payment_commission_pence(lesson);

  select coalesce(
    jsonb_agg(s order by s),
    '[]'::jsonb
  )
  into result
  from (
    select
      (
        p_day::timestamp
        + m * interval '30 minutes'
      ) at time zone 'Europe/London' as s
    from generate_series(0,47) m
  ) times
  where s >= now() + interval '2 hours'
    and s + p_duration_minutes * interval '1 minute'
      <= now() + interval '88 days'
    and public.calendar_within_hours(
      p_instructor,
      s,
      s + p_duration_minutes * interval '1 minute'
    )
    and not exists (
      select 1
      from public.instructor_time_blocks b
      where b.instructor_id = p_instructor
        and b.starts_at
          < s + p_duration_minutes * interval '1 minute'
        and b.ends_at > s
    )
    and not exists (
      select 1
      from public.lesson_reservations r
      where r.instructor_id = p_instructor
        and r.starts_at
          < s + p_duration_minutes * interval '1 minute'
        and r.ends_at > s
        and (
          r.status = 'confirmed'
          or (
            r.status = 'held'
            and r.expires_at > now()
          )
        )
    );

  return jsonb_build_object(
    'slots',result,
    'ready',true,
    'hourly_rate_pence',rate,
    'duration_minutes',p_duration_minutes,
    'lesson_pence',lesson,
    'booking_fee_pence',booking_fee,
    'commission_pence',commission,
    'platform_fee_pence',booking_fee + commission,
    'instructor_pence',lesson - commission,
    'total_pence',lesson + booking_fee,
    'time_zone','Europe/London'
  );
end;
$$;

-- =========================================================
-- ATTACH CHECKOUT SESSION
-- Do not attach a brand-new Stripe session to an expired/terminal checkout.
-- Repeating the same session remains idempotent.
-- =========================================================

create or replace function public.payment_attach_session(
  p_reservation uuid,
  p_session text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.stripe_checkouts;
begin
  if p_reservation is null
     or p_session is null
     or p_session !~ '^cs_[A-Za-z0-9_]+$' then
    raise exception 'Invalid Stripe session';
  end if;

  select *
  into c
  from public.stripe_checkouts
  where reservation_id = p_reservation
  for update;

  if c.reservation_id is null then
    raise exception 'Unknown checkout';
  end if;

  if c.session_id = p_session then
    return;
  end if;

  if c.session_id is not null then
    raise exception 'Payment session changed';
  end if;

  if c.state <> 'creating'
     or c.checkout_expires_at <= now() then
    raise exception 'Checkout unavailable';
  end if;

  update public.stripe_checkouts
  set
    session_id = p_session,
    state = 'open'
  where reservation_id = p_reservation;
end;
$$;

-- =========================================================
-- EXPIRE CHECKOUT
-- Supports both webhook-driven expiry and abandoned "creating" rows
-- where no Stripe session was attached.
-- =========================================================

create or replace function public.payment_expire(
  p_reservation uuid,
  p_session text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  instructor uuid;
begin
  select instructor_id
  into instructor
  from public.lesson_reservations
  where id = p_reservation;

  perform 1
  from public.profiles
  where id = instructor
  for update;

  perform 1
  from public.lesson_reservations
  where id = p_reservation
  for update;

  update public.stripe_checkouts
  set state = 'expired'
  where reservation_id = p_reservation
    and state in ('creating','open')
    and (
      (session_id is null and p_session is null)
      or session_id = p_session
    );

  if found then
    update public.lesson_reservations
    set
      status = 'cancelled',
      cancelled_at = coalesce(cancelled_at,now()),
      cancellation_reason = coalesce(
        cancellation_reason,
        'Checkout expired'
      )
    where id = p_reservation
      and status = 'held';
  end if;
end;
$$;

-- Scheduled/server-side cleanup helper for abandoned checkout holds.
create function public.payment_expire_stale()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  affected integer := 0;
begin
  with expired as (
    update public.stripe_checkouts c
    set state = 'expired'
    where c.state in ('creating','open')
      and c.checkout_expires_at <= now()
    returning c.reservation_id
  ),
  released as (
    update public.lesson_reservations r
    set
      status = 'cancelled',
      cancelled_at = coalesce(r.cancelled_at,now()),
      cancellation_reason = coalesce(
        r.cancellation_reason,
        'Checkout expired'
      )
    where r.id in (
      select reservation_id
      from expired
    )
      and r.status = 'held'
    returning r.id
  )
  select count(*)
  into affected
  from released;

  return affected;
end;
$$;

-- =========================================================
-- ACCOUNT DELETION REQUEST
-- Release held bookings and make their checkout state non-payable in DB.
-- Stripe API session expiry remains an API-layer responsibility.
-- =========================================================

create or replace function public.account_request_deletion_for_user(
  p_user uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  result public.account_deletion_requests;
begin
  if p_user is null then
    raise exception 'Account required';
  end if;

  perform 1
  from public.profiles
  where id = p_user
    and account_status <> 'deleted'
  for update;

  if not found then
    raise exception 'Account unavailable';
  end if;

  insert into public.account_deletion_requests (
    user_id
  )
  values (
    p_user
  )
  on conflict (user_id)
  do update set
    status = case
      when public.account_deletion_requests.status = 'completed'
        then public.account_deletion_requests.status
      else 'requested'
    end,
    requested_at = case
      when public.account_deletion_requests.status = 'completed'
        then public.account_deletion_requests.requested_at
      else now()
    end,
    due_at = case
      when public.account_deletion_requests.status = 'completed'
        then public.account_deletion_requests.due_at
      else now() + interval '30 days'
    end;

  update public.profiles
  set account_status = 'deletion_requested'
  where id = p_user
    and account_status <> 'deleted';

  update public.instructor_profiles
  set accepting_new_pupils = false
  where user_id = p_user;

  with cancelled as (
    update public.lesson_reservations
    set
      status = 'cancelled',
      cancelled_at = coalesce(cancelled_at,now()),
      cancellation_reason = coalesce(
        cancellation_reason,
        'Account deletion requested'
      )
    where status = 'held'
      and (
        learner_id = p_user
        or instructor_id = p_user
      )
    returning id
  )
  update public.stripe_checkouts
  set state = 'expired'
  where reservation_id in (
      select id
      from cancelled
    )
    and state in ('creating','open');

  select *
  into result
  from public.account_deletion_requests
  where user_id = p_user;

  return to_jsonb(result);
end;
$$;

-- =========================================================
-- FUNCTION PERMISSIONS
-- =========================================================

revoke all
on function public.payment_expire_stale()
from public, anon, authenticated;

grant execute
on function public.payment_expire_stale()
to service_role;

-- Existing replacement functions retain their previous grants,
-- but explicitly reassert the intended service-role boundary.
revoke all
on function public.payment_slots(uuid,date,integer),
   public.payment_attach_session(uuid,text),
   public.payment_expire(uuid,text),
   public.account_request_deletion_for_user(uuid)
from public, anon, authenticated;

grant execute
on function public.payment_slots(uuid,date,integer),
   public.payment_attach_session(uuid,text),
   public.payment_expire(uuid,text),
   public.account_request_deletion_for_user(uuid)
to service_role;

notify pgrst, 'reload schema';

commit;
