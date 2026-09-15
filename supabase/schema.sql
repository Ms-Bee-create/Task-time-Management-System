-- ============================================================================
-- The Cracks App — Phase 1 Supabase schema
-- Micro-task delivery engine: Crack Picker, brain-dump parser, bulk importer,
-- and the call-script drawer.
-- ============================================================================

create extension if not exists "pgcrypto";

-- ----------------------------------------------------------------------------
-- profiles
-- role_type drives the default call-script tone/content in the drawer.
-- ----------------------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  email text,
  display_name text,
  -- Legacy "primary" hat, kept for the default call-script lookup.
  -- 'mom_home' kept in the allowed list for backward-compat with any existing
  -- rows, even though it's no longer offered in the UI (replaced by the four
  -- more specific parenting hats below).
  role_type text not null default 'virtual_assistant'
    check (role_type in ('virtual_assistant', 'medical_biller', 'content_creator', 'executive',
      'mom_home', 'toddler_mom', 'homeschool_mom', 'first_time_mom', 'custom_sandbox')),
  -- Multi-hat selection ("Homeschool Mom + Medical Biller" etc.) — source of
  -- truth for which role vocabularies are active. role_type mirrors roles[0].
  active_roles text[] not null default '{}',
  -- Homeschool Mom roster: [{id, name, grade}], used for lesson planning later.
  homeschool_kids jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- tasks
-- The core queue the Crack Picker draws from.
--
-- duration_bucket: which of the three Crack Picker taps ("I have 5 mins" /
--   "15 mins" / "45+ mins") this task belongs to.
-- energy_type: what kind of mental energy it takes, used to avoid surfacing
--   a "focus" task when the user only tapped in because they're drained.
-- task_type: 'call' is what triggers the script drawer on tap.
-- source: how the task got created, useful for tuning the parser later.
-- ----------------------------------------------------------------------------
-- projects
-- Client/project buckets for time tracking + invoicing. keywords drives
-- auto-assignment: a new task's text is matched against every active
-- project's keyword list (longest match wins) to auto-tag it.
-- ----------------------------------------------------------------------------
create table if not exists public.projects (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  name text not null,
  client_name text,
  color text not null default '#7c9473',
  hourly_rate numeric(10,2),
  keywords text[] not null default '{}',
  archived boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists projects_user_id_idx on public.projects (user_id);

-- ----------------------------------------------------------------------------
-- tasks
-- ----------------------------------------------------------------------------
create table if not exists public.tasks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  title text not null,
  raw_input text,
  duration_bucket text not null default '15'
    check (duration_bucket in ('5', '15', '45')),
  energy_type text not null default 'admin'
    check (energy_type in ('low', 'admin', 'focus', 'social')),
  task_type text not null default 'general'
    check (task_type in ('general', 'call', 'email')),
  -- Which active hat's vocabulary tagged this task (null = generic, no hat-specific
  -- keyword matched). Drives the category chips shown inside a time bucket.
  role_tag text
    check (role_tag is null or role_tag in ('virtual_assistant', 'medical_biller', 'content_creator', 'executive', 'mom_home', 'toddler_mom', 'homeschool_mom', 'first_time_mom', 'custom_sandbox')),
  project_id uuid references public.projects (id) on delete set null,
  status text not null default 'open'
    check (status in ('open', 'done', 'skipped')),
  priority int not null default 2 check (priority between 1 and 3),
  source text not null default 'manual'
    check (source in ('brain_dump', 'bulk_import', 'manual')),
  created_at timestamptz not null default now(),
  completed_at timestamptz
);

create index if not exists tasks_user_id_idx on public.tasks (user_id);
create index if not exists tasks_queue_idx on public.tasks (user_id, status, duration_bucket, priority);

-- ----------------------------------------------------------------------------
-- call_scripts
-- History of generated 120-second scripts, optionally tied to a task.
-- ----------------------------------------------------------------------------
create table if not exists public.call_scripts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  task_id uuid references public.tasks (id) on delete set null,
  goal_prompt text not null,
  script_text text not null,
  target_seconds int not null default 120,
  created_at timestamptz not null default now()
);

create index if not exists call_scripts_user_id_idx on public.call_scripts (user_id);
create index if not exists call_scripts_task_id_idx on public.call_scripts (task_id);

-- ----------------------------------------------------------------------------
-- time_entries
-- Completed timer sessions ("time on task"), one row per stop. title/role_tag
-- are snapshotted at stop time so a report still reads correctly even if the
-- source task is later renamed or removed.
-- ----------------------------------------------------------------------------
create table if not exists public.time_entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  task_id uuid references public.tasks (id) on delete set null,
  title text not null,
  role_tag text
    check (role_tag is null or role_tag in ('virtual_assistant', 'medical_biller', 'content_creator', 'executive', 'mom_home', 'toddler_mom', 'homeschool_mom', 'first_time_mom', 'custom_sandbox')),
  project_id uuid references public.projects (id) on delete set null,
  -- Snapshotted at stop time so a report/export is stable even if the project
  -- is later renamed or its rate changes.
  project_name text,
  rate numeric(10,2),
  started_at timestamptz not null,
  ended_at timestamptz not null,
  duration_seconds int not null check (duration_seconds >= 0),
  created_at timestamptz not null default now()
);

create index if not exists time_entries_user_id_idx on public.time_entries (user_id);
create index if not exists time_entries_started_at_idx on public.time_entries (user_id, started_at);

-- ----------------------------------------------------------------------------
-- script_templates
-- Per-role default out-of-office scripts. Seeded with one row per role type
-- and fully user-editable ("All views must be fully editable" — rewrite the
-- script on the fly, it persists here instead of resetting to the default).
-- ----------------------------------------------------------------------------
create table if not exists public.script_templates (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  role_type text not null
    check (role_type in ('virtual_assistant', 'medical_biller', 'content_creator', 'executive', 'mom_home', 'toddler_mom', 'homeschool_mom', 'first_time_mom', 'custom_sandbox')),
  body text not null,
  updated_at timestamptz not null default now(),
  unique (user_id, role_type)
);

-- ============================================================================
-- Row Level Security — every table scoped strictly to auth.uid()
-- ============================================================================

alter table public.profiles enable row level security;
alter table public.projects enable row level security;
alter table public.tasks enable row level security;
alter table public.call_scripts enable row level security;
alter table public.script_templates enable row level security;
alter table public.time_entries enable row level security;

create policy "profiles_select_own" on public.profiles
  for select using (auth.uid() = id);
create policy "profiles_update_own" on public.profiles
  for update using (auth.uid() = id);
create policy "profiles_insert_own" on public.profiles
  for insert with check (auth.uid() = id);

create policy "projects_select_own" on public.projects
  for select using (auth.uid() = user_id);
create policy "projects_insert_own" on public.projects
  for insert with check (auth.uid() = user_id);
create policy "projects_update_own" on public.projects
  for update using (auth.uid() = user_id);
create policy "projects_delete_own" on public.projects
  for delete using (auth.uid() = user_id);

create policy "tasks_select_own" on public.tasks
  for select using (auth.uid() = user_id);
create policy "tasks_insert_own" on public.tasks
  for insert with check (auth.uid() = user_id);
create policy "tasks_update_own" on public.tasks
  for update using (auth.uid() = user_id);
create policy "tasks_delete_own" on public.tasks
  for delete using (auth.uid() = user_id);

create policy "call_scripts_select_own" on public.call_scripts
  for select using (auth.uid() = user_id);
create policy "call_scripts_insert_own" on public.call_scripts
  for insert with check (auth.uid() = user_id);
create policy "call_scripts_delete_own" on public.call_scripts
  for delete using (auth.uid() = user_id);

create policy "time_entries_select_own" on public.time_entries
  for select using (auth.uid() = user_id);
create policy "time_entries_insert_own" on public.time_entries
  for insert with check (auth.uid() = user_id);
create policy "time_entries_delete_own" on public.time_entries
  for delete using (auth.uid() = user_id);

create policy "script_templates_select_own" on public.script_templates
  for select using (auth.uid() = user_id);
create policy "script_templates_insert_own" on public.script_templates
  for insert with check (auth.uid() = user_id);
create policy "script_templates_update_own" on public.script_templates
  for update using (auth.uid() = user_id);
create policy "script_templates_delete_own" on public.script_templates
  for delete using (auth.uid() = user_id);

-- ----------------------------------------------------------------------------
-- New-user bootstrap: profile row + one default script template per role.
-- ----------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (id, email)
  values (new.id, new.email)
  on conflict (id) do nothing;

  insert into public.script_templates (user_id, role_type, body)
  values
    (new.id, 'virtual_assistant',
     E'Hi, this is [Your Name]. I have about three minutes, so let me get right to it.\n\nI''m reaching out about [reason for call] — I wanted to handle this directly rather than let it drag out over email.\n\nHere''s where things stand: [one or two sentence summary].\n\nWhat I need from you is [specific ask]. Is that something you can do, or is there a blocker I should know about?\n\nI know you''re busy, so I won''t take more of your time than I need to. Can we agree on [next step / deadline] as the plan?\n\nGreat — I''ll follow up in writing so we both have it. Thanks for your time today.'),
    (new.id, 'medical_biller',
     E'Hi, this is [Your Name] calling on behalf of [Practice Name] regarding claim [claim number].\n\nI''m following up on [reason for call — denial, missing info, resubmission].\n\nCan you confirm the current status, and what''s needed from our end to move it forward?\n\nI''ll note that on the account and follow up in writing so we have a record on both sides. Thank you for your time.'),
    (new.id, 'content_creator',
     E'Hi, it''s [Your Name] — thanks for hopping on.\n\nI''m calling about [reason — collab, deliverable, usage rights].\n\nHere''s what I''m thinking: [one-sentence pitch or ask].\n\nDoes that work on your end, or is there something you''d want adjusted?\n\nI''ll send a quick recap by email so it''s all in writing. Appreciate you making time.'),
    (new.id, 'executive',
     E'Hi, [Your Name] here. I have a hard stop shortly, so I''ll be brief.\n\nCalling regarding [reason for call].\n\nBottom line: [the ask or decision needed].\n\nCan we align on [next step] before I go?\n\nI''ll circulate a short recap after this call. Thanks for your time.'),
    (new.id, 'toddler_mom',
     E'Hi, this is [Your Name]. I''ve got about two minutes before my toddler notices I''ve disappeared, so I''ll be quick.\n\nI''m calling about [reason for call].\n\nWhat I need is [specific ask] — can you help with that today?\n\nIf you need to reach me back, [best way to reach you] is easiest. Thanks so much.'),
    (new.id, 'homeschool_mom',
     E'Hi, this is [Your Name]. I''m between lessons, so I only have a few minutes.\n\nI''m calling about [reason for call].\n\nWhat I need is [specific ask] — is that something you can help with?\n\nFeel free to reach me back at [best way to reach you]. Thank you!'),
    (new.id, 'first_time_mom',
     E'Hi, this is [Your Name]. I only have a couple minutes before the baby needs me, so I''ll be quick.\n\nI''m calling about [reason for call].\n\nWhat I need is [specific ask] — can you help with that today?\n\nIf you need to reach me back, [best way to reach you] is easiest. Thanks so much.'),
    (new.id, 'custom_sandbox',
     E'Hi, this is [Your Name]. I have a couple minutes, so I''ll be quick.\n\nI''m calling about [reason for call].\n\nWhat I need is [specific ask] — can you help with that today?\n\nThanks so much for your time.')
  on conflict (user_id, role_type) do nothing;

  return new;
end;
$$ language plpgsql security definer set search_path = public;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
