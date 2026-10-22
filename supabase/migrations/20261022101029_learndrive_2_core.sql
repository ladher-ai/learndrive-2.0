-- LearnDrive 2.0
-- Migration 001: Core CRM, pupil relationships and teaching records

create extension if not exists pgcrypto;

-- =========================================================
-- ENUMS
-- =========================================================

create type public.user_role as enum (
  'learner',
  'instructor',
  'admin'
);

create type public.enquiry_status as enum (
  'new',
  'contacted',
  'waiting',
  'converted',
  'declined',
  'closed'
);

create type public.pupil_status as enum (
  'waiting',
  'active',
  'test_ready',
  'passed',
  'former'
);

create type public.transmission_type as enum (
  'manual',
  'automatic',
  'both'
);

create type public.driving_test_status as enum (
  'scheduled',
  'passed',
  'failed',
  'cancelled'
);

-- =========================================================
-- UPDATED_AT HELPER
-- =========================================================

create or replace function public.set_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- =========================================================
-- PROFILES
-- =========================================================

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role public.user_role not null default 'learner',
  display_name text,
  phone text,
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger profiles_set_updated_at
before update on public.profiles
for each row execute function public.set_updated_at();

-- =========================================================
-- LEARNER PROFILE
-- =========================================================

create table public.learner_profiles (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  postcode text,
  transmission_preference public.transmission_type,
  preferred_pickup_location text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger learner_profiles_set_updated_at
before update on public.learner_profiles
for each row execute function public.set_updated_at();

-- =========================================================
-- INSTRUCTOR PROFILE
-- =========================================================

create table public.instructor_profiles (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  business_name text,
  bio text,
  transmission public.transmission_type,
  hourly_rate_pence integer check (hourly_rate_pence is null or hourly_rate_pence >= 0),
  approved boolean not null default false,
  accepting_new_pupils boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger instructor_profiles_set_updated_at
before update on public.instructor_profiles
for each row execute function public.set_updated_at();

-- =========================================================
-- ENQUIRIES
-- =========================================================

create table public.enquiries (
  id uuid primary key default gen_random_uuid(),
  learner_id uuid not null references public.profiles(id) on delete cascade,
  instructor_id uuid not null references public.profiles(id) on delete cascade,
  status public.enquiry_status not null default 'new',
  message text,
  learner_postcode text,
  preferred_times text,
  transmission_preference public.transmission_type,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  check (learner_id <> instructor_id)
);

create index enquiries_learner_idx
on public.enquiries (learner_id, created_at desc);

create index enquiries_instructor_idx
on public.enquiries (instructor_id, status, created_at desc);

create trigger enquiries_set_updated_at
before update on public.enquiries
for each row execute function public.set_updated_at();

-- =========================================================
-- INSTRUCTOR / PUPIL RELATIONSHIP
-- =========================================================

create table public.instructor_learners (
  id uuid primary key default gen_random_uuid(),
  instructor_id uuid not null references public.profiles(id) on delete cascade,
  learner_id uuid not null references public.profiles(id) on delete cascade,
  status public.pupil_status not null default 'active',
  source_enquiry_id uuid references public.enquiries(id) on delete set null,
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (instructor_id, learner_id),
  check (instructor_id <> learner_id)
);

create index instructor_learners_instructor_idx
on public.instructor_learners (instructor_id, status);

create index instructor_learners_learner_idx
on public.instructor_learners (learner_id, status);

create trigger instructor_learners_set_updated_at
before update on public.instructor_learners
for each row execute function public.set_updated_at();

-- =========================================================
-- SKILL CATALOGUE
-- Actual DVSA-oriented skill list will be seeded separately.
-- =========================================================

create table public.skill_catalogue (
  id bigint generated by default as identity primary key,
  code text not null unique,
  name text not null,
  category text,
  sort_order integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- =========================================================
-- PUPIL SKILL PROGRESS
-- 1 Introduced
-- 2 Developing
-- 3 Prompted
-- 4 Independent
-- 5 Test ready
-- =========================================================

create table public.learner_skill_progress (
  id uuid primary key default gen_random_uuid(),
  relationship_id uuid not null
    references public.instructor_learners(id) on delete cascade,
  skill_id bigint not null
    references public.skill_catalogue(id) on delete restrict,
  level smallint not null default 1 check (level between 1 and 5),
  last_assessed_at timestamptz not null default now(),
  updated_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (relationship_id, skill_id)
);

create index learner_skill_progress_relationship_idx
on public.learner_skill_progress (relationship_id);

create trigger learner_skill_progress_set_updated_at
before update on public.learner_skill_progress
for each row execute function public.set_updated_at();

-- =========================================================
-- SHARED LESSON RECORDS
-- Learners can see these.
-- lesson_id deliberately has no FK yet:
-- booking/lesson schema will be ported from proven 1.0 design.
-- =========================================================

create table public.lesson_records (
  id uuid primary key default gen_random_uuid(),
  relationship_id uuid not null
    references public.instructor_learners(id) on delete cascade,
  lesson_id uuid,
  lesson_date timestamptz not null,
  shared_summary text,
  strengths text,
  focus_next_lesson text,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index lesson_records_relationship_idx
on public.lesson_records (relationship_id, lesson_date desc);

create trigger lesson_records_set_updated_at
before update on public.lesson_records
for each row execute function public.set_updated_at();

-- =========================================================
-- PRIVATE INSTRUCTOR NOTES
-- Kept separate so learners can never retrieve private notes.
-- =========================================================

create table public.instructor_private_notes (
  id uuid primary key default gen_random_uuid(),
  relationship_id uuid not null
    references public.instructor_learners(id) on delete cascade,
  lesson_record_id uuid
    references public.lesson_records(id) on delete cascade,
  instructor_id uuid not null
    references public.profiles(id) on delete cascade,
  note text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index instructor_private_notes_relationship_idx
on public.instructor_private_notes (relationship_id, created_at desc);

create trigger instructor_private_notes_set_updated_at
before update on public.instructor_private_notes
for each row execute function public.set_updated_at();

-- =========================================================
-- LEARNER REFLECTIVE LOG
-- =========================================================

create table public.reflective_logs (
  id uuid primary key default gen_random_uuid(),
  relationship_id uuid not null
    references public.instructor_learners(id) on delete cascade,
  lesson_record_id uuid
    references public.lesson_records(id) on delete set null,
  learner_id uuid not null
    references public.profiles(id) on delete cascade,
  reflection text not null,
  confidence smallint check (confidence between 1 and 5),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index reflective_logs_relationship_idx
on public.reflective_logs (relationship_id, created_at desc);

create trigger reflective_logs_set_updated_at
before update on public.reflective_logs
for each row execute function public.set_updated_at();

-- =========================================================
-- MOCK TESTS
-- =========================================================

create table public.mock_tests (
  id uuid primary key default gen_random_uuid(),
  relationship_id uuid not null
    references public.instructor_learners(id) on delete cascade,
  conducted_at timestamptz not null default now(),
  serious_faults integer not null default 0 check (serious_faults >= 0),
  dangerous_faults integer not null default 0 check (dangerous_faults >= 0),
  driving_faults integer not null default 0 check (driving_faults >= 0),
  passed boolean not null default false,
  notes text,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index mock_tests_relationship_idx
on public.mock_tests (relationship_id, conducted_at desc);

create trigger mock_tests_set_updated_at
before update on public.mock_tests
for each row execute function public.set_updated_at();

-- =========================================================
-- DRIVING TESTS
-- =========================================================

create table public.driving_tests (
  id uuid primary key default gen_random_uuid(),
  relationship_id uuid not null
    references public.instructor_learners(id) on delete cascade,
  scheduled_at timestamptz not null,
  test_centre text,
  status public.driving_test_status not null default 'scheduled',
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index driving_tests_relationship_idx
on public.driving_tests (relationship_id, scheduled_at);

create trigger driving_tests_set_updated_at
before update on public.driving_tests
for each row execute function public.set_updated_at();

-- =========================================================
-- ROW LEVEL SECURITY
-- =========================================================

alter table public.profiles enable row level security;
alter table public.learner_profiles enable row level security;
alter table public.instructor_profiles enable row level security;
alter table public.enquiries enable row level security;
alter table public.instructor_learners enable row level security;
alter table public.skill_catalogue enable row level security;
alter table public.learner_skill_progress enable row level security;
alter table public.lesson_records enable row level security;
alter table public.instructor_private_notes enable row level security;
alter table public.reflective_logs enable row level security;
alter table public.mock_tests enable row level security;
alter table public.driving_tests enable row level security;

-- Profiles: users can see/update themselves.
create policy "profiles_select_self"
on public.profiles for select
to authenticated
using (id = auth.uid());

create policy "profiles_update_self"
on public.profiles for update
to authenticated
using (id = auth.uid())
with check (id = auth.uid());

-- Learner profiles: learner owns their row.
create policy "learner_profiles_self"
on public.learner_profiles for all
to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

-- Instructor profiles:
-- owner can manage their row; approved profiles are readable by signed-in users.
create policy "instructor_profiles_select"
on public.instructor_profiles for select
to authenticated
using (approved = true or user_id = auth.uid());

create policy "instructor_profiles_insert_self"
on public.instructor_profiles for insert
to authenticated
with check (user_id = auth.uid());

create policy "instructor_profiles_update_self"
on public.instructor_profiles for update
to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

-- Enquiries.
create policy "enquiries_learner_insert"
on public.enquiries for insert
to authenticated
with check (learner_id = auth.uid());

create policy "enquiries_participants_select"
on public.enquiries for select
to authenticated
using (
  learner_id = auth.uid()
  or instructor_id = auth.uid()
);

create policy "enquiries_instructor_update"
on public.enquiries for update
to authenticated
using (instructor_id = auth.uid())
with check (instructor_id = auth.uid());

-- Instructor / learner relationship.
create policy "relationships_participants_select"
on public.instructor_learners for select
to authenticated
using (
  instructor_id = auth.uid()
  or learner_id = auth.uid()
);

create policy "relationships_instructor_insert"
on public.instructor_learners for insert
to authenticated
with check (instructor_id = auth.uid());

create policy "relationships_instructor_update"
on public.instructor_learners for update
to authenticated
using (instructor_id = auth.uid())
with check (instructor_id = auth.uid());

-- Skill catalogue is readable by authenticated users.
create policy "skill_catalogue_read"
on public.skill_catalogue for select
to authenticated
using (true);

-- Skill progress readable by both sides, writable by instructor.
create policy "skill_progress_participants_select"
on public.learner_skill_progress for select
to authenticated
using (
  exists (
    select 1
    from public.instructor_learners il
    where il.id = relationship_id
      and (il.instructor_id = auth.uid() or il.learner_id = auth.uid())
  )
);

create policy "skill_progress_instructor_insert"
on public.learner_skill_progress for insert
to authenticated
with check (
  updated_by = auth.uid()
  and exists (
    select 1
    from public.instructor_learners il
    where il.id = relationship_id
      and il.instructor_id = auth.uid()
  )
);

create policy "skill_progress_instructor_update"
on public.learner_skill_progress for update
to authenticated
using (
  exists (
    select 1
    from public.instructor_learners il
    where il.id = relationship_id
      and il.instructor_id = auth.uid()
  )
)
with check (
  updated_by = auth.uid()
);

-- Shared lesson records readable by learner/instructor, writable by instructor.
create policy "lesson_records_participants_select"
on public.lesson_records for select
to authenticated
using (
  exists (
    select 1
    from public.instructor_learners il
    where il.id = relationship_id
      and (il.instructor_id = auth.uid() or il.learner_id = auth.uid())
  )
);

create policy "lesson_records_instructor_insert"
on public.lesson_records for insert
to authenticated
with check (
  created_by = auth.uid()
  and exists (
    select 1
    from public.instructor_learners il
    where il.id = relationship_id
      and il.instructor_id = auth.uid()
  )
);

create policy "lesson_records_instructor_update"
on public.lesson_records for update
to authenticated
using (
  exists (
    select 1
    from public.instructor_learners il
    where il.id = relationship_id
      and il.instructor_id = auth.uid()
  )
);

-- Private instructor notes: instructor only.
create policy "private_notes_instructor_only"
on public.instructor_private_notes for all
to authenticated
using (instructor_id = auth.uid())
with check (
  instructor_id = auth.uid()
  and exists (
    select 1
    from public.instructor_learners il
    where il.id = relationship_id
      and il.instructor_id = auth.uid()
  )
);

-- Reflective logs: learner writes, learner + instructor can read.
create policy "reflective_logs_participants_select"
on public.reflective_logs for select
to authenticated
using (
  learner_id = auth.uid()
  or exists (
    select 1
    from public.instructor_learners il
    where il.id = relationship_id
      and il.instructor_id = auth.uid()
  )
);

create policy "reflective_logs_learner_insert"
on public.reflective_logs for insert
to authenticated
with check (
  learner_id = auth.uid()
  and exists (
    select 1
    from public.instructor_learners il
    where il.id = relationship_id
      and il.learner_id = auth.uid()
  )
);

create policy "reflective_logs_learner_update"
on public.reflective_logs for update
to authenticated
using (learner_id = auth.uid())
with check (learner_id = auth.uid());

-- Mock tests: learner/instructor read, instructor writes.
create policy "mock_tests_participants_select"
on public.mock_tests for select
to authenticated
using (
  exists (
    select 1
    from public.instructor_learners il
    where il.id = relationship_id
      and (il.instructor_id = auth.uid() or il.learner_id = auth.uid())
  )
);

create policy "mock_tests_instructor_insert"
on public.mock_tests for insert
to authenticated
with check (
  created_by = auth.uid()
  and exists (
    select 1
    from public.instructor_learners il
    where il.id = relationship_id
      and il.instructor_id = auth.uid()
  )
);

create policy "mock_tests_instructor_update"
on public.mock_tests for update
to authenticated
using (
  exists (
    select 1
    from public.instructor_learners il
    where il.id = relationship_id
      and il.instructor_id = auth.uid()
  )
);

-- Driving tests: both sides read; instructor manages.
create policy "driving_tests_participants_select"
on public.driving_tests for select
to authenticated
using (
  exists (
    select 1
    from public.instructor_learners il
    where il.id = relationship_id
      and (il.instructor_id = auth.uid() or il.learner_id = auth.uid())
  )
);

create policy "driving_tests_instructor_insert"
on public.driving_tests for insert
to authenticated
with check (
  exists (
    select 1
    from public.instructor_learners il
    where il.id = relationship_id
      and il.instructor_id = auth.uid()
  )
);

create policy "driving_tests_instructor_update"
on public.driving_tests for update
to authenticated
using (
  exists (
    select 1
    from public.instructor_learners il
    where il.id = relationship_id
      and il.instructor_id = auth.uid()
  )
);

-- =========================================================
-- END MIGRATION 001
-- =========================================================
