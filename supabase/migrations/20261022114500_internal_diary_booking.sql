-- LearnDrive 2.0
-- Migration 002: Internal diary and booking engine
-- Internal LearnDrive diary is authoritative.
-- No Google/Outlook/iCloud calendar sync is introduced here.

begin;

create extension if not exists pgcrypto;
create extension if not exists btree_gist;

-- =========================================================
-- ACCOUNT STATUS
-- =========================================================

alter table public.profiles
  add column if not exists account_status text not null default 'active'
  check (account_status in ('active','deletion_requested','deleted'));

-- =========================================================
-- CALENDAR ENUMS
-- =========================================================

do $$
begin
  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'public'
      and t.typname = 'calendar_block_type'
  ) then
    create type public.calendar_block_type as enum (
      'unavailable',
      'appointment',
      'holiday',
      'break',
      'other'
    );
  end if;
end
$$;

-- =========================================================
-- INSTRUCTOR WORKING HOURS
-- Multiple windows per weekday are allowed.
-- =========================================================

create table public.instructor_lesson_hours (
  id uuid primary key default gen_random_uuid(),
  instructor_id uuid not null
    references public.instructor_profiles(user_id)
    on delete cascade,
  weekday integer not null
    check (weekday between 1 and 7),
  start_minute integer not null
    check (
      start_minute between 0 and 1410
      and start_minute % 30 = 0
    ),
  end_minute integer not null
    check (
      end_minute between 30 and 1440
      and end_minute % 30 = 0
    ),
  created_at timestamptz not null default now(),
  check (end_minute > start_minute),
  unique (instructor_id, weekday, start_minute, end_minute)
);

create index instructor_lesson_hours_lookup_idx
  on public.instructor_lesson_hours (
    instructor_id,
    weekday,
    start_minute
  );

-- =========================================================
-- PRIVATE INSTRUCTOR TIME BLOCKS
-- private_title is never returned by learner-facing availability.
-- =========================================================

create table public.instructor_time_blocks (
  id uuid primary key default gen_random_uuid(),
  instructor_id uuid not null
    references public.profiles(id)
    on delete cascade,
  block_type public.calendar_block_type
    not null default 'unavailable',
  private_title text
    check (
      private_title is null
      or char_length(private_title) <= 120
    ),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_at > starts_at)
);

create index instructor_time_blocks_dates_idx
  on public.instructor_time_blocks (
    instructor_id,
    starts_at
  );

create trigger instructor_time_blocks_set_updated_at
before update on public.instructor_time_blocks
for each row
execute function public.set_updated_at();

-- =========================================================
-- LESSON RESERVATIONS
-- held = checkout/payment in progress
-- confirmed = paid/confirmed
-- cancelled = released/cancelled
-- request_id provides idempotency per learner.
-- =========================================================

create table public.lesson_reservations (
  id uuid primary key default gen_random_uuid(),
  learner_id uuid not null
    references public.profiles(id),
  instructor_id uuid not null
    references public.profiles(id),
  relationship_id uuid
    references public.instructor_learners(id)
    on delete set null,
  request_id uuid not null,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  status text not null default 'held'
    check (status in ('held','confirmed','cancelled')),
  expires_at timestamptz not null
    default now() + interval '10 minutes',
  confirmed_at timestamptz,
  cancelled_at timestamptz,
  cancellation_reason text
    check (
      cancellation_reason is null
      or char_length(cancellation_reason) <= 500
    ),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (learner_id, request_id),
  check (learner_id <> instructor_id),
  check (ends_at > starts_at)
);

create index lesson_reservations_instructor_dates_idx
  on public.lesson_reservations (
    instructor_id,
    starts_at
  );

create index lesson_reservations_learner_dates_idx
  on public.lesson_reservations (
    learner_id,
    starts_at
  );

create index lesson_reservations_active_idx
  on public.lesson_reservations (
    instructor_id,
    status,
    starts_at
  );

create trigger lesson_reservations_set_updated_at
before update on public.lesson_reservations
for each row
execute function public.set_updated_at();

-- Database-level protection for confirmed lessons.
-- Held reservations are protected by serialized booking functions because
-- whether a hold is active depends on expires_at > now().

alter table public.lesson_reservations
  add constraint confirmed_instructor_no_overlap
  exclude using gist (
    instructor_id with =,
    tstzrange(starts_at, ends_at, '[)') with &&
  )
  where (status = 'confirmed');

alter table public.lesson_reservations
  add constraint confirmed_learner_no_overlap
  exclude using gist (
    learner_id with =,
    tstzrange(starts_at, ends_at, '[)') with &&
  )
  where (status = 'confirmed');

-- Link the existing CRM lesson records to the booking table.
alter table public.lesson_records
  add constraint lesson_records_lesson_fk
  foreign key (lesson_id)
  references public.lesson_reservations(id)
  on delete set null;

-- =========================================================
-- RLS / ACCESS BOUNDARY
-- Client writes go through trusted server actions.
-- =========================================================

alter table public.instructor_lesson_hours enable row level security;
alter table public.instructor_time_blocks enable row level security;
alter table public.lesson_reservations enable row level security;

revoke all
on public.instructor_lesson_hours,
   public.instructor_time_blocks,
   public.lesson_reservations
from public, anon, authenticated, service_role;

grant select, insert, update, delete
on public.instructor_lesson_hours,
   public.instructor_time_blocks,
   public.lesson_reservations
to service_role;

-- =========================================================
-- SAVE WORKING HOURS
-- =========================================================

create function public.calendar_save_hours(
  p_user uuid,
  p_hours jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  item jsonb;
begin
  perform 1
  from public.profiles p
  join public.instructor_profiles i
    on i.user_id = p.id
  where p.id = p_user
    and p.role = 'instructor'
    and p.account_status = 'active'
  for update;

  if not found then
    raise exception 'Instructor required';
  end if;

  if jsonb_typeof(p_hours) is distinct from 'array'
     or jsonb_array_length(p_hours) > 21 then
    raise exception 'Invalid lesson hours';
  end if;

  delete from public.instructor_lesson_hours
  where instructor_id = p_user;

  for item in
    select *
    from jsonb_array_elements(p_hours)
  loop
    if not (
      item ?& array['weekday','start_minute','end_minute']
    ) then
      raise exception 'Invalid lesson hours';
    end if;

    insert into public.instructor_lesson_hours (
      instructor_id,
      weekday,
      start_minute,
      end_minute
    )
    values (
      p_user,
      (item->>'weekday')::integer,
      (item->>'start_minute')::integer,
      (item->>'end_minute')::integer
    );
  end loop;

  if exists (
    select 1
    from public.instructor_lesson_hours a
    join public.instructor_lesson_hours b
      on b.instructor_id = a.instructor_id
     and b.weekday = a.weekday
     and b.id <> a.id
     and a.start_minute < b.end_minute
     and b.start_minute < a.end_minute
    where a.instructor_id = p_user
  ) then
    raise exception 'Working hours overlap';
  end if;
end;
$$;

-- =========================================================
-- SLOT INSIDE WORKING HOURS
-- =========================================================

create function public.calendar_within_hours(
  p_instructor uuid,
  p_start timestamptz,
  p_end timestamptz
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    p_start is not null
    and p_end is not null
    and p_end > p_start
    and (p_start at time zone 'Europe/London')::date
      =
      ((p_end - interval '1 microsecond') at time zone 'Europe/London')::date
    and extract(second from p_start) = 0
    and extract(minute from p_start)::integer % 30 = 0
    and exists (
      select 1
      from public.instructor_lesson_hours h
      where h.instructor_id = p_instructor
        and h.weekday = extract(
          isodow from p_start at time zone 'Europe/London'
        )
        and (p_start at time zone 'Europe/London')
          >= (p_start at time zone 'Europe/London')::date
             + h.start_minute * interval '1 minute'
        and (p_end at time zone 'Europe/London')
          <= (p_start at time zone 'Europe/London')::date
             + h.end_minute * interval '1 minute'
    );
$$;

-- =========================================================
-- ADD / REMOVE PRIVATE BLOCKS
-- =========================================================

create function public.calendar_add_block(
  p_user uuid,
  p_start timestamptz,
  p_end timestamptz,
  p_type public.calendar_block_type default 'unavailable',
  p_title text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  result uuid;
begin
  perform 1
  from public.profiles
  where id = p_user
    and role = 'instructor'
    and account_status = 'active'
  for update;

  if not found then
    raise exception 'Instructor required';
  end if;

  if p_start is null
     or p_end is null
     or p_end <= p_start
     or p_end <= now()
     or p_start < now() - interval '1 day'
     or p_end > now() + interval '366 days' then
    raise exception 'Invalid dates';
  end if;

  if p_title is not null
     and char_length(trim(p_title)) > 120 then
    raise exception 'Block title is too long';
  end if;

  if (
    select count(*)
    from public.instructor_time_blocks
    where instructor_id = p_user
      and ends_at > now()
  ) >= 500 then
    raise exception 'Block limit reached';
  end if;

  if exists (
    select 1
    from public.lesson_reservations
    where instructor_id = p_user
      and starts_at < p_end
      and ends_at > p_start
      and (
        status = 'confirmed'
        or (status = 'held' and expires_at > now())
      )
  ) then
    raise exception 'An existing lesson overlaps these dates';
  end if;

  insert into public.instructor_time_blocks (
    instructor_id,
    block_type,
    private_title,
    starts_at,
    ends_at
  )
  values (
    p_user,
    p_type,
    nullif(trim(p_title), ''),
    p_start,
    p_end
  )
  returning id into result;

  return result;
end;
$$;

create function public.calendar_remove_block(
  p_user uuid,
  p_id uuid
)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.instructor_time_blocks
  where id = p_id
    and instructor_id = p_user;
$$;

-- =========================================================
-- INSTRUCTOR CALENDAR STATUS
-- =========================================================

create function public.calendar_status(
  p_user uuid
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'mode','internal',
    'external_sync_enabled',false,
    'working_hours',
      coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'id',id,
            'weekday',weekday,
            'start_minute',start_minute,
            'end_minute',end_minute
          )
          order by weekday,start_minute
        )
        from public.instructor_lesson_hours
        where instructor_id = p_user
      ),'[]'::jsonb),
    'blocks',
      coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'id',id,
            'type',block_type,
            'title',private_title,
            'start',starts_at,
            'end',ends_at
          )
          order by starts_at
        )
        from public.instructor_time_blocks
        where instructor_id = p_user
          and ends_at > now() - interval '1 day'
      ),'[]'::jsonb)
  );
$$;

-- =========================================================
-- LEARNER-FACING AVAILABILITY
-- Private title/type is deliberately hidden.
-- =========================================================

create function public.calendar_availability(
  p_instructor uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1
    from public.instructor_profiles i
    join public.profiles p
      on p.id = i.user_id
    where i.user_id = p_instructor
      and i.approved = true
      and i.accepting_new_pupils = true
      and p.account_status = 'active'
  ) then
    raise exception 'Instructor unavailable';
  end if;

  return jsonb_build_object(
    'mode','internal',
    'checked_at',now(),
    'range_from',now(),
    'range_until',now() + interval '89 days',
    'incomplete',false,
    'busy_periods',
      coalesce((
        select jsonb_agg(period)
        from (
          select jsonb_build_object(
            'start',starts_at,
            'end',ends_at
          ) period
          from public.instructor_time_blocks
          where instructor_id = p_instructor
            and ends_at > now()
            and starts_at < now() + interval '90 days'

          union all

          select jsonb_build_object(
            'start',starts_at,
            'end',ends_at
          )
          from public.lesson_reservations
          where instructor_id = p_instructor
            and ends_at > now()
            and starts_at < now() + interval '90 days'
            and (
              status = 'confirmed'
              or (status = 'held' and expires_at > now())
            )
        ) periods
      ),'[]'::jsonb)
  );
end;
$$;

-- =========================================================
-- RESERVE SLOT
-- Serializes participant profiles, checks both instructor and learner
-- conflicts, and preserves idempotency via learner_id + request_id.
-- =========================================================

create function public.calendar_reserve_slot(
  p_learner uuid,
  p_instructor uuid,
  p_start timestamptz,
  p_end timestamptz,
  p_request uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  existing public.lesson_reservations;
  result uuid;
  relation uuid;
begin
  perform 1
  from public.profiles
  where id in (p_learner,p_instructor)
  order by id
  for update;

  if not exists (
    select 1
    from public.profiles
    where id = p_instructor
      and role = 'instructor'
      and account_status = 'active'
  )
  or not exists (
    select 1
    from public.instructor_profiles
    where user_id = p_instructor
      and approved = true
  )
  or not exists (
    select 1
    from public.profiles
    where id = p_learner
      and role = 'learner'
      and account_status = 'active'
  ) then
    raise exception 'Account unavailable';
  end if;

  select *
  into existing
  from public.lesson_reservations
  where learner_id = p_learner
    and request_id = p_request;

  if found then
    if existing.instructor_id = p_instructor
       and existing.starts_at = p_start
       and existing.ends_at = p_end
       and (
         existing.status = 'confirmed'
         or (
           existing.status = 'held'
           and existing.expires_at > now()
         )
       ) then
      return existing.id;
    end if;

    raise exception 'Reservation request already used';
  end if;

  if p_request is null
     or p_start is null
     or p_end is null
     or p_start < now() + interval '30 minutes'
     or p_end > now() + interval '89 days'
     or p_end - p_start < interval '30 minutes'
     or p_end - p_start > interval '4 hours' then
    raise exception 'Invalid lesson dates';
  end if;

  if not public.calendar_within_hours(
    p_instructor,
    p_start,
    p_end
  ) then
    raise exception 'Outside instructor lesson hours';
  end if;

  if exists (
    select 1
    from public.instructor_time_blocks
    where instructor_id = p_instructor
      and starts_at < p_end
      and ends_at > p_start
  ) then
    raise exception 'This time is unavailable';
  end if;

  if exists (
    select 1
    from public.lesson_reservations
    where instructor_id = p_instructor
      and starts_at < p_end
      and ends_at > p_start
      and (
        status = 'confirmed'
        or (status = 'held' and expires_at > now())
      )
  ) then
    raise exception 'This time is unavailable';
  end if;

  if exists (
    select 1
    from public.lesson_reservations
    where learner_id = p_learner
      and starts_at < p_end
      and ends_at > p_start
      and (
        status = 'confirmed'
        or (status = 'held' and expires_at > now())
      )
  ) then
    raise exception 'Learner already has a lesson at this time';
  end if;

  select id
  into relation
  from public.instructor_learners
  where instructor_id = p_instructor
    and learner_id = p_learner
  limit 1;

  insert into public.lesson_reservations (
    learner_id,
    instructor_id,
    relationship_id,
    request_id,
    starts_at,
    ends_at
  )
  values (
    p_learner,
    p_instructor,
    relation,
    p_request,
    p_start,
    p_end
  )
  returning id into result;

  return result;
end;
$$;

-- =========================================================
-- FUNCTION PERMISSIONS
-- =========================================================

revoke all
on function public.calendar_save_hours(uuid,jsonb),
   public.calendar_within_hours(uuid,timestamptz,timestamptz),
   public.calendar_add_block(uuid,timestamptz,timestamptz,public.calendar_block_type,text),
   public.calendar_remove_block(uuid,uuid),
   public.calendar_status(uuid),
   public.calendar_availability(uuid),
   public.calendar_reserve_slot(uuid,uuid,timestamptz,timestamptz,uuid)
from public, anon, authenticated;

grant execute
on function public.calendar_save_hours(uuid,jsonb),
   public.calendar_within_hours(uuid,timestamptz,timestamptz),
   public.calendar_add_block(uuid,timestamptz,timestamptz,public.calendar_block_type,text),
   public.calendar_remove_block(uuid,uuid),
   public.calendar_status(uuid),
   public.calendar_availability(uuid),
   public.calendar_reserve_slot(uuid,uuid,timestamptz,timestamptz,uuid)
to service_role;

notify pgrst, 'reload schema';

commit;
