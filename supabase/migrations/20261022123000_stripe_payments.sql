-- LearnDrive 2.0
-- Migration 003: Stripe Connect, booking fees, commission and refunds
--
-- Pricing model:
--   Learner pays lesson price + GBP 2.50 booking fee.
--   LearnDrive retains GBP 2.50 booking fee + 10% of lesson price.
--   Instructor receives 90% of lesson price.
--
-- All payment mutation functions are service-role only.

begin;

-- =========================================================
-- STRIPE CONNECT INSTRUCTOR STATE
-- =========================================================

create table public.stripe_instructors (
  user_id uuid primary key
    references public.instructor_profiles(user_id)
    on delete cascade,

  account_id text not null unique
    check (account_id ~ '^acct_[A-Za-z0-9]+$'),

  ready boolean not null default false,
  checked_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger stripe_instructors_set_updated_at
before update on public.stripe_instructors
for each row
execute function public.set_updated_at();

-- =========================================================
-- CHECKOUT / PAYMENT SNAPSHOTS
-- Immutable price snapshots prevent client-side repricing.
-- =========================================================

create table public.stripe_checkouts (
  reservation_id uuid primary key
    references public.lesson_reservations(id)
    on delete restrict,

  account_id text not null
    references public.stripe_instructors(account_id),

  hourly_rate_pence integer not null
    check (hourly_rate_pence between 1000 and 100000),

  duration_minutes integer not null
    check (
      duration_minutes between 30 and 240
      and duration_minutes % 30 = 0
    ),

  lesson_pence integer not null
    check (lesson_pence > 0),

  booking_fee_pence integer not null
    default 250
    check (booking_fee_pence = 250),

  commission_pence integer not null
    check (
      commission_pence =
      round(lesson_pence::numeric / 10)::integer
    ),

  platform_fee_pence integer not null
    check (
      platform_fee_pence =
      booking_fee_pence + commission_pence
    ),

  instructor_pence integer not null
    check (
      instructor_pence =
      lesson_pence - commission_pence
    ),

  total_pence integer not null
    check (
      total_pence =
      lesson_pence + booking_fee_pence
    ),

  session_id text unique
    check (
      session_id is null
      or session_id ~ '^cs_[A-Za-z0-9_]+$'
    ),

  payment_intent text unique
    check (
      payment_intent is null
      or payment_intent ~ '^pi_[A-Za-z0-9_]+$'
    ),

  refund_id text unique
    check (
      refund_id is null
      or refund_id ~ '^re_[A-Za-z0-9_]+$'
    ),

  state text not null default 'creating'
    check (
      state in (
        'creating',
        'open',
        'confirmed',
        'expired',
        'refund_pending',
        'refunded'
      )
    ),

  checkout_expires_at timestamptz
    not null default now() + interval '35 minutes',

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index stripe_checkouts_state_idx
  on public.stripe_checkouts (state, created_at);

create index stripe_checkouts_intent_idx
  on public.stripe_checkouts (payment_intent)
  where payment_intent is not null;

create trigger stripe_checkouts_set_updated_at
before update on public.stripe_checkouts
for each row
execute function public.set_updated_at();

-- =========================================================
-- RLS / ACCESS BOUNDARY
-- =========================================================

alter table public.stripe_instructors enable row level security;
alter table public.stripe_checkouts enable row level security;

revoke all
on public.stripe_instructors,
   public.stripe_checkouts
from public, anon, authenticated, service_role;

grant select, insert, update, delete
on public.stripe_instructors,
   public.stripe_checkouts
to service_role;

-- =========================================================
-- FIXED COMMERCIAL RULES
-- =========================================================

create function public.payment_booking_fee_pence()
returns integer
language sql
immutable
security definer
set search_path = ''
as $$
  select 250;
$$;

create function public.payment_commission_pence(
  p_lesson_pence integer
)
returns integer
language sql
immutable
security definer
set search_path = ''
as $$
  select round(p_lesson_pence::numeric / 10)::integer;
$$;

-- =========================================================
-- STRIPE ACCOUNT SNAPSHOT
-- Called only after the server has verified the Stripe account.
-- =========================================================

create function public.payment_save_account(
  p_user uuid,
  p_account text,
  p_ready boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_user is null
     or p_account is null
     or p_account !~ '^acct_[A-Za-z0-9]+$'
     or p_ready is null then
    raise exception 'Invalid Stripe account state';
  end if;

  if not exists (
    select 1
    from public.instructor_profiles i
    join public.profiles p
      on p.id = i.user_id
    where i.user_id = p_user
      and p.role = 'instructor'
      and p.account_status = 'active'
  ) then
    raise exception 'Instructor unavailable';
  end if;

  insert into public.stripe_instructors (
    user_id,
    account_id,
    ready,
    checked_at
  )
  values (
    p_user,
    p_account,
    p_ready,
    now()
  )
  on conflict (user_id)
  do update set
    ready = excluded.ready,
    checked_at = excluded.checked_at
  where public.stripe_instructors.account_id = excluded.account_id;

  if not found then
    raise exception 'Stripe account changed';
  end if;
end;
$$;

-- =========================================================
-- AVAILABLE PAYMENT SLOTS
-- Preview only. payment_prepare performs authoritative checks.
-- =========================================================

create function public.payment_slots(
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

  if rate is null then
    raise exception 'Instructor unavailable';
  end if;

  if not exists (
    select 1
    from public.stripe_instructors
    where user_id = p_instructor
      and ready = true
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
-- PREPARE CHECKOUT
-- =========================================================

create function public.payment_prepare(
  p_learner uuid,
  p_instructor uuid,
  p_start timestamptz,
  p_duration_minutes integer,
  p_request uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  existing record;
  reservation uuid;
  rate integer;
  account text;
  finish timestamptz;
  lesson integer;
  booking_fee integer := public.payment_booking_fee_pence();
  commission integer;
begin
  -- Deterministic participant locks reduce race/deadlock risk.
  perform 1
  from public.profiles
  where id in (p_learner,p_instructor)
  order by id
  for update;

  if not exists (
    select 1
    from public.profiles
    where id = p_learner
      and role = 'learner'
      and account_status = 'active'
  ) then
    raise exception 'Learner required';
  end if;

  if not exists (
    select 1
    from public.profiles
    where id = p_instructor
      and role = 'instructor'
      and account_status = 'active'
  ) then
    raise exception 'Instructor unavailable';
  end if;

  if p_start is null
     or p_request is null
     or p_duration_minutes is null
     or p_duration_minutes < 30
     or p_duration_minutes > 240
     or p_duration_minutes % 30 <> 0 then
    raise exception 'Invalid lesson dates';
  end if;

  finish :=
    p_start
    + p_duration_minutes * interval '1 minute';

  select
    r.id,
    r.instructor_id,
    r.starts_at,
    r.ends_at,
    r.expires_at,
    c.state
  into existing
  from public.lesson_reservations r
  join public.stripe_checkouts c
    on c.reservation_id = r.id
  where r.learner_id = p_learner
    and r.request_id = p_request;

  if found then
    if existing.instructor_id <> p_instructor
       or existing.starts_at <> p_start
       or existing.ends_at <> finish then
      raise exception 'Reservation request already used';
    end if;

    if existing.state in ('creating','open')
       and existing.expires_at <= now() then
      raise exception 'Checkout expired';
    end if;

    return (
      select to_jsonb(c)
      from public.stripe_checkouts c
      where c.reservation_id = existing.id
    );
  end if;

  if exists (
    select 1
    from public.lesson_reservations r
    where r.learner_id = p_learner
      and r.status = 'held'
      and r.expires_at > now()
  ) then
    raise exception 'Finish or cancel your pending payment first';
  end if;

  if p_start < now() + interval '2 hours'
     or finish > now() + interval '88 days'
     or not public.calendar_within_hours(
       p_instructor,
       p_start,
       finish
     ) then
    raise exception 'Outside instructor lesson hours';
  end if;

  select i.hourly_rate_pence
  into rate
  from public.instructor_profiles i
  where i.user_id = p_instructor
    and i.approved = true;

  select s.account_id
  into account
  from public.stripe_instructors s
  where s.user_id = p_instructor
    and s.ready = true
    and s.checked_at > now() - interval '5 minutes';

  if rate is null or account is null then
    raise exception 'Instructor payments unavailable';
  end if;

  lesson := round(
    rate::numeric * p_duration_minutes::numeric / 60
  )::integer;

  commission := public.payment_commission_pence(lesson);

  reservation := public.calendar_reserve_slot(
    p_learner,
    p_instructor,
    p_start,
    finish,
    p_request
  );

  update public.lesson_reservations
  set expires_at = now() + interval '35 minutes'
  where id = reservation;

  insert into public.stripe_checkouts (
    reservation_id,
    account_id,
    hourly_rate_pence,
    duration_minutes,
    lesson_pence,
    booking_fee_pence,
    commission_pence,
    platform_fee_pence,
    instructor_pence,
    total_pence,
    checkout_expires_at
  )
  values (
    reservation,
    account,
    rate,
    p_duration_minutes,
    lesson,
    booking_fee,
    commission,
    booking_fee + commission,
    lesson - commission,
    lesson + booking_fee,
    now() + interval '35 minutes'
  );

  return (
    select to_jsonb(c)
    from public.stripe_checkouts c
    where c.reservation_id = reservation
  );
end;
$$;

-- =========================================================
-- ATTACH STRIPE CHECKOUT SESSION
-- =========================================================

create function public.payment_attach_session(
  p_reservation uuid,
  p_session text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_session is null
     or p_session !~ '^cs_[A-Za-z0-9_]+$' then
    raise exception 'Invalid Stripe session';
  end if;

  update public.stripe_checkouts
  set
    session_id = p_session,
    state = case
      when state = 'creating' then 'open'
      else state
    end
  where reservation_id = p_reservation
    and (
      session_id is null
      or session_id = p_session
    );

  if not found then
    raise exception 'Payment session changed';
  end if;
end;
$$;

-- =========================================================
-- SETTLE SUCCESSFUL STRIPE PAYMENT
-- Delayed webhooks never resurrect expired/released slots.
-- =========================================================

create function public.payment_settle(
  p_reservation uuid,
  p_session text,
  p_intent text,
  p_amount integer,
  p_fee integer,
  p_destination text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.stripe_checkouts;
  r public.lesson_reservations;
  instructor uuid;
  blocked boolean;
begin
  if p_session is null
     or p_session !~ '^cs_[A-Za-z0-9_]+$'
     or p_intent is null
     or p_intent !~ '^pi_[A-Za-z0-9_]+$'
     or p_destination is null
     or p_destination !~ '^acct_[A-Za-z0-9]+$' then
    raise exception 'Payment mismatch';
  end if;

  select instructor_id
  into instructor
  from public.lesson_reservations
  where id = p_reservation;

  if instructor is null then
    raise exception 'Unknown payment';
  end if;

  perform 1
  from public.profiles
  where id = instructor
  for update;

  select *
  into r
  from public.lesson_reservations
  where id = p_reservation
  for update;

  select *
  into c
  from public.stripe_checkouts
  where reservation_id = p_reservation
  for update;

  if c.reservation_id is null
     or c.session_id is distinct from p_session
     or c.total_pence is distinct from p_amount
     or c.platform_fee_pence is distinct from p_fee
     or c.account_id is distinct from p_destination
     or (
       c.payment_intent is not null
       and c.payment_intent <> p_intent
     ) then
    raise exception 'Payment mismatch';
  end if;

  if c.state in (
    'confirmed',
    'refund_pending',
    'refunded'
  ) then
    return c.state;
  end if;

  blocked :=
    r.status <> 'held'
    or r.expires_at <= now()
    or r.starts_at <= now()
    or not exists (
      select 1
      from public.instructor_profiles i
      join public.profiles p
        on p.id = i.user_id
      where i.user_id = instructor
        and i.approved = true
        and p.account_status = 'active'
    )
    or exists (
      select 1
      from public.instructor_time_blocks b
      where b.instructor_id = instructor
        and b.starts_at < r.ends_at
        and b.ends_at > r.starts_at
    )
    or exists (
      select 1
      from public.lesson_reservations x
      where x.instructor_id = instructor
        and x.id <> r.id
        and x.starts_at < r.ends_at
        and x.ends_at > r.starts_at
        and (
          x.status = 'confirmed'
          or (
            x.status = 'held'
            and x.expires_at > now()
          )
        )
    )
    or exists (
      select 1
      from public.lesson_reservations x
      where x.learner_id = r.learner_id
        and x.id <> r.id
        and x.starts_at < r.ends_at
        and x.ends_at > r.starts_at
        and (
          x.status = 'confirmed'
          or (
            x.status = 'held'
            and x.expires_at > now()
          )
        )
    );

  update public.lesson_reservations
  set
    status = case
      when blocked then 'cancelled'
      else 'confirmed'
    end,
    confirmed_at = case
      when blocked then confirmed_at
      else coalesce(confirmed_at,now())
    end,
    cancelled_at = case
      when blocked then coalesce(cancelled_at,now())
      else cancelled_at
    end,
    cancellation_reason = case
      when blocked then coalesce(
        cancellation_reason,
        'Payment arrived after booking became unavailable'
      )
      else cancellation_reason
    end
  where id = r.id;

  update public.stripe_checkouts
  set
    payment_intent = p_intent,
    state = case
      when blocked then 'refund_pending'
      else 'confirmed'
    end
  where reservation_id = r.id;

  return case
    when blocked then 'refund_pending'
    else 'confirmed'
  end;
end;
$$;

-- =========================================================
-- EXPIRE ABANDONED CHECKOUT
-- =========================================================

create function public.payment_expire(
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
    and session_id = p_session
    and state in ('creating','open');

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

-- =========================================================
-- REFUND RECONCILIATION
-- =========================================================

create function public.payment_mark_refund_pending(
  p_reservation uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.stripe_checkouts
  set state = 'refund_pending'
  where reservation_id = p_reservation
    and state = 'confirmed';

  if not found
     and not exists (
       select 1
       from public.stripe_checkouts
       where reservation_id = p_reservation
         and state in ('refund_pending','refunded')
     ) then
    raise exception 'Payment cannot be refunded';
  end if;
end;
$$;

create function public.payment_record_refund(
  p_reservation uuid,
  p_refund text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_refund is null
     or p_refund !~ '^re_[A-Za-z0-9_]+$' then
    raise exception 'Invalid refund';
  end if;

  update public.stripe_checkouts
  set refund_id = p_refund
  where reservation_id = p_reservation
    and state = 'refund_pending'
    and (
      refund_id is null
      or refund_id = p_refund
    );

  if not found
     and not exists (
       select 1
       from public.stripe_checkouts
       where reservation_id = p_reservation
         and state = 'refunded'
         and refund_id = p_refund
     ) then
    raise exception 'Refund changed';
  end if;
end;
$$;

create function public.payment_refunded(
  p_reservation uuid,
  p_refund text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_refund is null
     or p_refund !~ '^re_[A-Za-z0-9_]+$' then
    raise exception 'Invalid refund';
  end if;

  update public.stripe_checkouts
  set
    refund_id = p_refund,
    state = 'refunded'
  where reservation_id = p_reservation
    and state in ('refund_pending','refunded')
    and (
      refund_id is null
      or refund_id = p_refund
    );

  if not found then
    raise exception 'Refund mismatch';
  end if;

  update public.lesson_reservations
  set
    status = 'cancelled',
    cancelled_at = coalesce(cancelled_at,now()),
    cancellation_reason = coalesce(
      cancellation_reason,
      'Payment refunded'
    )
  where id = p_reservation;
end;
$$;

create function public.payment_reconcile_full_refund(
  p_reservation uuid,
  p_refund text,
  p_intent text,
  p_amount integer
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.stripe_checkouts;
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

  select *
  into c
  from public.stripe_checkouts
  where reservation_id = p_reservation
  for update;

  if c.reservation_id is null
     or c.payment_intent is distinct from p_intent
     or c.total_pence is distinct from p_amount
     or p_refund is null
     or p_refund !~ '^re_[A-Za-z0-9_]+$'
     or c.state not in (
       'confirmed',
       'refund_pending',
       'refunded'
     )
     or (
       c.refund_id is not null
       and c.refund_id <> p_refund
     ) then
    raise exception 'Refund mismatch';
  end if;

  update public.stripe_checkouts
  set
    state = 'refunded',
    refund_id = p_refund
  where reservation_id = p_reservation;

  update public.lesson_reservations
  set
    status = 'cancelled',
    cancelled_at = coalesce(cancelled_at,now()),
    cancellation_reason = coalesce(
      cancellation_reason,
      'Payment refunded'
    )
  where id = p_reservation;
end;
$$;

-- =========================================================
-- PAYMENT HISTORY
-- Service-side helper. PII exposure remains controlled by API layer.
-- =========================================================

create function public.payment_list(
  p_user uuid
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    jsonb_agg(to_jsonb(items) order by starts_at desc),
    '[]'::jsonb
  )
  from (
    select
      r.id,
      r.learner_id,
      r.instructor_id,
      learner.display_name as learner_name,
      instructor.display_name as instructor_name,
      r.starts_at,
      r.ends_at,
      c.hourly_rate_pence,
      c.duration_minutes,
      c.lesson_pence,
      c.booking_fee_pence,
      c.commission_pence,
      c.platform_fee_pence,
      c.instructor_pence,
      c.total_pence,
      case
        when c.state in ('creating','open')
         and r.expires_at <= now()
          then 'expired'
        else c.state
      end as payment_state,
      c.session_id is not null as has_checkout,
      r.expires_at
    from public.lesson_reservations r
    join public.stripe_checkouts c
      on c.reservation_id = r.id
    join public.profiles learner
      on learner.id = r.learner_id
    join public.profiles instructor
      on instructor.id = r.instructor_id
    where p_user in (
      r.learner_id,
      r.instructor_id
    )
    order by r.starts_at desc
    limit 200
  ) items;
$$;

-- =========================================================
-- FUNCTION PERMISSIONS
-- =========================================================

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as signature
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname like 'payment\_%' escape '\'
  loop
    execute format(
      'revoke all on function %s from public,anon,authenticated',
      f.signature
    );
    execute format(
      'grant execute on function %s to service_role',
      f.signature
    );
  end loop;
end
$$;

notify pgrst, 'reload schema';

commit;
