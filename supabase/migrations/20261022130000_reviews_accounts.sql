-- LearnDrive 2.0
-- Migration 004: Reviews and account lifecycle safeguards

begin;

-- =========================================================
-- REVIEWS
-- One review per learner/instructor relationship, updateable
-- after later completed paid lessons.
-- =========================================================

create table public.instructor_reviews (
  id uuid primary key default gen_random_uuid(),

  instructor_id uuid not null
    references public.instructor_profiles(user_id)
    on delete cascade,

  learner_id uuid not null
    references public.profiles(id)
    on delete cascade,

  reservation_id uuid not null
    references public.lesson_reservations(id)
    on delete restrict,

  rating integer not null
    check (rating between 1 and 5),

  comment text not null default ''
    check (char_length(comment) <= 1000),

  status text not null default 'pending'
    check (
      status in ('pending','published','rejected')
    ),

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (instructor_id, learner_id)
);

create index instructor_reviews_public_idx
  on public.instructor_reviews (
    instructor_id,
    status,
    created_at desc
  );

create trigger instructor_reviews_set_updated_at
before update on public.instructor_reviews
for each row
execute function public.set_updated_at();

alter table public.instructor_reviews
enable row level security;

revoke all
on public.instructor_reviews
from public, anon, authenticated, service_role;

grant select, insert, update, delete
on public.instructor_reviews
to service_role;

-- =========================================================
-- REVIEW ELIGIBILITY
-- Requires a past confirmed lesson with confirmed payment.
-- =========================================================

create function public.review_eligible_reservation(
  p_instructor uuid,
  p_learner uuid
)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select r.id
  from public.lesson_reservations r
  join public.stripe_checkouts c
    on c.reservation_id = r.id
   and c.state = 'confirmed'
  where r.instructor_id = p_instructor
    and r.learner_id = p_learner
    and r.status = 'confirmed'
    and r.ends_at <= now()
  order by r.ends_at desc
  limit 1;
$$;

-- Service-side submit/update helper.
create function public.review_submit_for_learner(
  p_learner uuid,
  p_instructor uuid,
  p_rating integer,
  p_comment text default ''
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  booking uuid;
  result uuid;
begin
  if p_learner is null
     or p_instructor is null
     or p_learner = p_instructor
     or p_rating is null
     or p_rating not between 1 and 5
     or p_comment is null
     or char_length(trim(p_comment)) > 1000 then
    raise exception 'Invalid review';
  end if;

  if not exists (
    select 1
    from public.profiles p
    where p.id = p_learner
      and p.role = 'learner'
      and p.account_status = 'active'
  ) then
    raise exception 'Learner account required';
  end if;

  if not exists (
    select 1
    from public.instructor_profiles i
    join public.profiles p
      on p.id = i.user_id
    where i.user_id = p_instructor
      and i.approved = true
      and p.account_status = 'active'
  ) then
    raise exception 'Instructor unavailable';
  end if;

  booking := public.review_eligible_reservation(
    p_instructor,
    p_learner
  );

  if booking is null then
    raise exception 'Past confirmed paid lesson required';
  end if;

  insert into public.instructor_reviews (
    instructor_id,
    learner_id,
    reservation_id,
    rating,
    comment,
    status
  )
  values (
    p_instructor,
    p_learner,
    booking,
    p_rating,
    trim(p_comment),
    'pending'
  )
  on conflict (instructor_id, learner_id)
  do update set
    reservation_id = excluded.reservation_id,
    rating = excluded.rating,
    comment = excluded.comment,
    status = 'pending',
    updated_at = now()
  returning id into result;

  return result;
end;
$$;

create function public.review_set_status(
  p_review uuid,
  p_status text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_status not in ('pending','published','rejected') then
    raise exception 'Invalid review status';
  end if;

  update public.instructor_reviews
  set status = p_status
  where id = p_review;

  if not found then
    raise exception 'Review not found';
  end if;
end;
$$;

create function public.instructor_reviews_page(
  p_instructor uuid,
  p_offset integer default 0
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'summary',
      jsonb_build_object(
        'count', count(*),
        'average_rating',
          case
            when count(*) = 0 then null
            else round(avg(rating)::numeric, 2)
          end
      ),
    'reviews',
      coalesce(
        jsonb_agg(
          jsonb_build_object(
            'id',id,
            'rating',rating,
            'comment',comment,
            'created_at',created_at
          )
          order by created_at desc
        ) filter (
          where rn > greatest(coalesce(p_offset,0),0)
            and rn <= greatest(coalesce(p_offset,0),0) + 50
        ),
        '[]'::jsonb
      )
  )
  from (
    select
      id,
      rating,
      comment,
      created_at,
      row_number() over (
        order by created_at desc
      ) as rn
    from public.instructor_reviews
    where instructor_id = p_instructor
      and status = 'published'
  ) q;
$$;

-- =========================================================
-- ACCOUNT DELETION REQUESTS
-- Financial/payment records are preserved for reconciliation.
-- Profile access is disabled immediately after request.
-- =========================================================

create table public.account_deletion_requests (
  id uuid primary key default gen_random_uuid(),

  user_id uuid not null unique
    references public.profiles(id)
    on delete restrict,

  requested_at timestamptz not null default now(),
  due_at timestamptz not null
    default now() + interval '30 days',

  status text not null default 'requested'
    check (
      status in ('requested','prepared','completed','cancelled')
    ),

  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger account_deletion_requests_set_updated_at
before update on public.account_deletion_requests
for each row
execute function public.set_updated_at();

alter table public.account_deletion_requests
enable row level security;

revoke all
on public.account_deletion_requests
from public, anon, authenticated, service_role;

grant select, insert, update, delete
on public.account_deletion_requests
to service_role;

create function public.account_request_deletion_for_user(
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

  -- Stop an instructor accepting new work immediately.
  update public.instructor_profiles
  set accepting_new_pupils = false
  where user_id = p_user;

  -- Existing held reservations for this account are released.
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
    );

  select *
  into result
  from public.account_deletion_requests
  where user_id = p_user;

  return to_jsonb(result);
end;
$$;

create function public.account_cancel_deletion_for_user(
  p_user uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform 1
  from public.profiles
  where id = p_user
    and account_status = 'deletion_requested'
  for update;

  if not found then
    raise exception 'No deletion request';
  end if;

  update public.account_deletion_requests
  set status = 'cancelled'
  where user_id = p_user
    and status in ('requested','prepared');

  update public.profiles
  set account_status = 'active'
  where id = p_user;
end;
$$;

-- Final anonymisation helper.
-- Does not delete Stripe/payment rows or booking financial history.
create function public.account_complete_deletion(
  p_user uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform 1
  from public.profiles
  where id = p_user
    and account_status = 'deletion_requested'
  for update;

  if not found then
    raise exception 'Account not ready for deletion';
  end if;

  if exists (
    select 1
    from public.lesson_reservations
    where (
      learner_id = p_user
      or instructor_id = p_user
    )
      and status = 'confirmed'
      and ends_at > now()
  ) then
    raise exception 'Future confirmed lessons must be resolved first';
  end if;

  update public.profiles
  set
    display_name = 'Deleted account',
    phone = null,
    avatar_url = null,
    account_status = 'deleted'
  where id = p_user;

  update public.learner_profiles
  set
    postcode = null,
    preferred_pickup_location = null
  where user_id = p_user;

  update public.instructor_profiles
  set
    business_name = null,
    bio = null,
    accepting_new_pupils = false
  where user_id = p_user;

  delete from public.instructor_time_blocks
  where instructor_id = p_user;

  delete from public.instructor_lesson_hours
  where instructor_id = p_user;

  update public.account_deletion_requests
  set
    status = 'completed',
    completed_at = now()
  where user_id = p_user;
end;
$$;

-- =========================================================
-- FUNCTION PERMISSIONS
-- =========================================================

revoke all
on function public.review_eligible_reservation(uuid,uuid),
   public.review_submit_for_learner(uuid,uuid,integer,text),
   public.review_set_status(uuid,text),
   public.instructor_reviews_page(uuid,integer),
   public.account_request_deletion_for_user(uuid),
   public.account_cancel_deletion_for_user(uuid),
   public.account_complete_deletion(uuid)
from public, anon, authenticated;

grant execute
on function public.review_eligible_reservation(uuid,uuid),
   public.review_submit_for_learner(uuid,uuid,integer,text),
   public.review_set_status(uuid,text),
   public.instructor_reviews_page(uuid,integer),
   public.account_request_deletion_for_user(uuid),
   public.account_cancel_deletion_for_user(uuid),
   public.account_complete_deletion(uuid)
to service_role;

notify pgrst, 'reload schema';

commit;
