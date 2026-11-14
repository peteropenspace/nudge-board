-- =====================================================================
-- Nudge Board: shared team backend for Supabase (Postgres 15 or newer)
--
-- HOW TO RUN: Supabase dashboard > SQL Editor > New query > paste this
-- whole file > Run. You can run it again after an update; it uses
-- "create or replace" and "if not exists" so nothing is lost.
--
-- WHAT IT SETS UP
--   * tables: board, people, cards, card history, in-app notifications
--   * row level security: only people on the team roster can see or edit
--     anything. Only the project manager (PM) can manage people, assign
--     tasks to other people, and change board settings.
--   * a notification queue with calm defaults (see docs/NOTIFICATIONS.md)
--   * a worker that runs every minute and sends email over HTTPS
--   * cycle roll-over that happens once, on the server
-- =====================================================================

-- @supabase-only:begin
create extension if not exists pg_net;
create extension if not exists pg_cron;
-- @supabase-only:end

create schema if not exists private;
grant usage on schema private to authenticated;

-- ---------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------

-- "Now", which tests can override. In real use this is just now().
create or replace function private.now_utc() returns timestamptz
language sql stable as $$
  select coalesce(nullif(current_setting('nb.fake_now', true), '')::timestamptz, now())
$$;

-- True for the SQL editor, cron jobs, edge functions and our own trusted
-- functions. False for signed-in browsers (roles authenticated / anon).
-- Our trusted functions mark themselves with set_config('nb.system', '1', true)
-- and put the old value back before they return. (A "set nb.system = '1'" clause
-- on the function would be tidier, but on Supabase only a superuser may attach a
-- custom setting to a function: "permission denied to set parameter".)
create or replace function private.is_system() returns boolean
language sql stable as $$
  select coalesce(current_setting('nb.system', true), '') = '1'
      or coalesce(current_setting('role', true), 'none') not in ('authenticated', 'anon')
$$;

create or replace function private.status_name(s text) returns text
language sql immutable as $$
  select case s when 'backlog' then 'Backlog' when 'todo' then 'To do' when 'doing' then 'Doing'
                when 'review' then 'QA Test' when 'security' then 'Security' when 'done' then 'Done' else coalesce(s, '') end
$$;

-- Escape text for safe use inside HTML.
create or replace function private.h(t text) returns text
language sql immutable as $$
  select replace(replace(replace(replace(replace(coalesce(t, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;')
$$;

create or replace function private.valid_tz(tz text) returns boolean
language sql stable as $$
  select exists (select 1 from pg_timezone_names where name = tz)
$$;

-- Checklist items must look like {"t": "text", "done": true}, at most 50 of them.
create or replace function private.valid_checks(j jsonb) returns boolean
language sql immutable as $$
  select case when jsonb_typeof(j) = 'array' and jsonb_array_length(j) <= 50 and pg_column_size(j) <= 20000
    then coalesce((select bool_and(coalesce(jsonb_typeof(e) = 'object' and jsonb_typeof(e -> 't') = 'string'
                                            and length(e ->> 't') <= 200 and jsonb_typeof(e -> 'done') = 'boolean', false))
                     from jsonb_array_elements(j) e), true)
    else false end
$$;

-- A join code like K7PM3QXD (shown as K7PM-3QXD): 8 characters, about 40 random bits.
-- No 0/O or 1/I so it reads cleanly over chat. Bytes 6 and 8 of a v4 UUID are not fully random, so they are skipped.
create or replace function private.new_code() returns text
language sql volatile as $$
  select string_agg(substr('23456789ABCDEFGHJKLMNPQRSTUVWXYZ', (get_byte(x.b, i) % 32) + 1, 1), '' order by i)
    from (select decode(replace(gen_random_uuid()::text, '-', ''), 'hex') as b) x,
         unnest(array[0, 1, 2, 3, 4, 5, 7, 9]) as i
$$;

-- What someone typed, tidied for comparing with a join code: "k7pm-3qxd " -> "K7PM3QXD"
create or replace function private.clean_code(t text) returns text
language sql immutable as $$
  select upper(regexp_replace(coalesce(t, ''), '[^A-Za-z0-9]', '', 'g'))
$$;

-- The first moment of the next Monday in a time zone. On a Monday itself, tomorrow.
create or replace function private.next_monday_start(ts timestamptz, tz text) returns timestamptz
language sql stable as $$
  select (case when extract(isodow from (ts at time zone tz)) = 1
               then date_trunc('day', ts at time zone tz) + interval '1 day'
               else date_trunc('week', ts at time zone tz) + interval '7 days' end) at time zone tz
$$;

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------

create table if not exists public.board (
  id int primary key default 1 check (id = 1),
  name text not null default 'My board' check (length(trim(name)) between 1 and 80),
  card_prefix text not null default 'TSK' check (card_prefix ~ '^[A-Z0-9]{2,5}$'),
  timezone text not null default 'UTC',
  cycle_days int not null default 14 check (cycle_days between 1 and 60),
  wip_limit int not null default 3 check (wip_limit between 1 and 50),
  stale_days int not null default 3 check (stale_days between 1 and 30),
  cycle_n int not null default 1,
  cycle_start date not null default current_date,
  default_reviewer_id uuid,
  updated_at timestamptz not null default now()
);
insert into public.board (id) values (1) on conflict do nothing;

create table if not exists public.people (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 80),
  email text not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  role text not null default 'member' check (role in ('member', 'pm')),
  timezone text not null default 'UTC',
  notify_mode text not null default 'normal' check (notify_mode in ('normal', 'calm', 'off')),
  pm_instant boolean not null default false,
  active boolean not null default true,
  muted_until timestamptz,
  mute_token uuid not null default gen_random_uuid(),
  created_at timestamptz not null default now()
);
create unique index if not exists people_email_key on public.people (lower(email));
-- Password sign-in: the sign-in account this person claimed with their join code.
-- The PM shares the code with them (chat, in person). It is cleared once used.
alter table public.people add column if not exists user_id uuid;
alter table public.people add column if not exists join_code text;
alter table public.people add column if not exists join_tries int not null default 0;
create unique index if not exists people_user_id_key on public.people (user_id) where user_id is not null;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'board_default_reviewer_fk') then
    alter table public.board add constraint board_default_reviewer_fk
      foreign key (default_reviewer_id) references public.people (id) on delete set null;
  end if;
end $$;

create sequence if not exists public.card_num_seq;

create table if not exists public.cards (
  id uuid primary key default gen_random_uuid(),
  num int not null,
  title text not null check (length(trim(title)) between 1 and 200),
  notes text not null default '' check (length(notes) <= 20000),
  status text not null default 'todo' check (status in ('backlog', 'todo', 'doing', 'review', 'done')),
  prio text not null default 'med' check (prio in ('low', 'med', 'high', 'urgent')),
  assignee_id uuid references public.people (id) on delete set null,
  reviewer_id uuid references public.people (id) on delete set null,
  due date,
  tags text[] not null default '{}',
  checks jsonb not null default '[]',
  blocked boolean not null default false,
  rolled int not null default 0,
  created_by uuid references public.people (id) on delete set null,
  created_at timestamptz not null default now(),
  touched_at timestamptz not null default now(),
  status_since timestamptz not null default now(),
  done_at timestamptz,
  archived_at timestamptz,
  version int not null default 1,
  updated_at timestamptz not null default now()
);
alter table public.cards alter column num drop default;
create unique index if not exists cards_num_key on public.cards (num);
create index if not exists cards_updated_idx on public.cards (updated_at);
create index if not exists cards_assignee_idx on public.cards (assignee_id) where archived_at is null;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'cards_checks_shape') then
    alter table public.cards add constraint cards_checks_shape check (private.valid_checks(checks));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'cards_tags_shape') then
    alter table public.cards add constraint cards_tags_shape
      check (cardinality(tags) <= 20 and coalesce(length(array_to_string(tags, ',')), 0) <= 600);
  end if;
end $$;

-- Planning fields:
--   horizon      backlog cards are either "next" (pull in soon) or "later" (someday)
--   size         s / m / l instead of story points (empty = not sized)
--   unplanned    set by the database when a card joins a cycle after its first day
--   waiting_on   who a blocked card is waiting on; block_note says what for
alter table public.cards add column if not exists horizon text not null default 'later';
alter table public.cards add column if not exists size text;
alter table public.cards add column if not exists unplanned boolean not null default false;
alter table public.cards add column if not exists waiting_on uuid references public.people (id) on delete set null;
alter table public.cards add column if not exists block_note text not null default '';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'cards_planning_shape') then
    alter table public.cards add constraint cards_planning_shape check (
      horizon in ('next', 'later') and (size is null or size in ('s', 'm', 'l')) and length(block_note) <= 200);
  end if;
end $$;

-- What this cycle is for, in one to three short lines (the PM writes it)
alter table public.board add column if not exists cycle_goals text not null default '';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'board_goals_length') then
    alter table public.board add constraint board_goals_length check (length(cycle_goals) <= 600);
  end if;
end $$;

-- The flow: Backlog > To do > Doing > QA Test ('review') > Security > Done.
-- Security is the cyber-security sign-off before a card is done.
alter table public.cards drop constraint if exists cards_status_check;
alter table public.cards add constraint cards_status_check
  check (status in ('backlog', 'todo', 'doing', 'review', 'security', 'done'));

-- Security reviewers: the people who sign off the Security step (the PM ticks them in Team)
alter table public.people add column if not exists security boolean not null default false;

-- Default reviewers, one per column, chosen by the PM on the column itself:
--   default_reviewer_id    QA Test, for cards without their own reviewer
--   security_reviewer_id   Security. Empty means every security reviewer.
alter table public.board add column if not exists security_reviewer_id uuid references public.people (id) on delete set null;

-- Who is away, and until when (people set this themselves in Settings)
alter table public.people add column if not exists away_until date;

-- Descriptions hold formatted text and image links now: allow 20,000 characters on older boards too.
alter table public.cards drop constraint if exists cards_notes_check;
alter table public.cards add constraint cards_notes_check check (length(notes) <= 20000);

-- Comments on a card. Formatted like the description. "mentions" lists the people @mentioned,
-- checked against the roster by the database; they get a notification.
create table if not exists public.card_comments (
  id uuid primary key default gen_random_uuid(),
  card_id uuid not null references public.cards (id) on delete cascade,
  author_id uuid references public.people (id) on delete set null,
  body text not null check (length(trim(body)) between 1 and 10000),
  mentions uuid[] not null default '{}',
  created_at timestamptz not null default now()
);
create index if not exists card_comments_card_idx on public.card_comments (card_id, created_at);

create table if not exists public.card_events (
  id bigint generated always as identity primary key,
  card_id uuid references public.cards (id) on delete set null,
  card_key text not null,
  title text not null,
  from_status text,
  to_status text,
  actor_id uuid references public.people (id) on delete set null,
  at timestamptz not null default now()
);
create index if not exists card_events_at_idx on public.card_events (at desc);

create table if not exists public.cycle_history (
  n int primary key,
  start_date date not null,
  end_date date not null,
  done int not null,
  total int not null
);

-- Each finished cycle keeps the goals it had, for its summary email
alter table public.cycle_history add column if not exists goals text not null default '';

-- The in-app inbox. Always on, silent, and free.
create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.people (id) on delete cascade,
  card_id uuid references public.cards (id) on delete cascade,
  kind text not null,
  message text not null,
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index if not exists notifications_recipient_idx on public.notifications (recipient_id, created_at desc);

-- Email settings. Only the PM can see or change these. The API key is NOT
-- stored here. It lives in Supabase Vault under the name email_api_key.
create table if not exists public.notify_settings (
  id int primary key default 1 check (id = 1),
  emails_enabled boolean not null default false,
  provider text not null default 'claude' check (provider in ('claude', 'resend', 'brevo', 'log')),
  from_name text not null default 'Nudge Board',
  from_email text not null default '',
  app_url text not null default '',
  hide_titles boolean not null default false,
  debounce_min int not null default 3 check (debounce_min between 0 and 60),
  debounce_max_min int not null default 10 check (debounce_max_min between 1 and 240),
  min_gap_min int not null default 15 check (min_gap_min between 0 and 240),
  instant_daily_cap int not null default 5 check (instant_daily_cap between 0 and 100),
  daily_cap int not null default 80 check (daily_cap between 1 and 100000),
  work_start int not null default 8 check (work_start between 0 and 23),
  work_end int not null default 18 check (work_end between 1 and 24),
  updated_at timestamptz not null default now()
);
insert into public.notify_settings (id) values (1) on conflict do nothing;
-- Boards made before Claude could send email: allow the 'claude' provider too.
alter table public.notify_settings drop constraint if exists notify_settings_provider_check;
alter table public.notify_settings add constraint notify_settings_provider_check
  check (provider in ('claude', 'resend', 'brevo', 'log'));
alter table public.notify_settings alter column provider set default 'claude';

-- Private tables: no browser access at all.
create table if not exists private.notify_queue (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.people (id) on delete cascade,
  card_id uuid references public.cards (id) on delete cascade,
  kind text not null check (kind in ('turn', 'alert', 'update')),
  reason text not null,
  delivery text not null check (delivery in ('instant', 'digest')),
  payload jsonb not null default '{}',
  status text not null default 'pending' check (status in ('pending', 'sending', 'sent', 'cancelled', 'digested', 'failed')),
  seq bigint generated always as identity,
  first_event_at timestamptz not null,
  send_after timestamptz not null,
  attempts int not null default 0,
  email_id uuid,
  created_at timestamptz not null default now(),
  finished_at timestamptz
);
-- One pending instant message per person per card per kind. A newer event
-- updates the same row instead of adding another email.
create unique index if not exists notify_queue_pending_instant
  on private.notify_queue (recipient_id, card_id, kind)
  where status = 'pending' and delivery = 'instant';
alter table private.notify_queue add column if not exists seq bigint generated always as identity;
create index if not exists notify_queue_due_idx on private.notify_queue (status, delivery, send_after);

create table if not exists private.email_log (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid references public.people (id) on delete set null,
  to_email text not null,
  kind text not null check (kind in ('instant', 'digest', 'test')),
  slot text,
  subject text not null,
  provider text not null,
  request_id bigint,
  status text not null default 'sending' check (status in ('sending', 'sent', 'failed')),
  detail text,
  created_at timestamptz not null default now(),
  finished_at timestamptz
);
alter table private.email_log add column if not exists slot text;
create index if not exists email_log_recipient_idx on private.email_log (recipient_id, created_at desc);

create table if not exists private.digest_slots (
  person_id uuid not null references public.people (id) on delete cascade,
  slot text not null,
  done_at timestamptz not null default now(),
  primary key (person_id, slot)
);

-- Remembers which blocked / overdue cards a person was already told about, so a standing
-- problem is mentioned every few days, not every morning.
create table if not exists private.digest_mentions (
  person_id uuid not null references public.people (id) on delete cascade,
  card_id uuid not null references public.cards (id) on delete cascade,
  kind text not null,
  last_at timestamptz not null,
  primary key (person_id, card_id, kind)
);

create table if not exists private.kv (
  key text primary key,
  value text
);

-- Emails waiting for Claude to send them (provider 'claude'). A scheduled task in the PM's
-- Claude app picks these up with the Claude key and sends them through their email connector.
create table if not exists private.outbox (
  id uuid primary key default gen_random_uuid(),
  idem text not null,
  to_email text not null,
  to_name text not null default '',
  subject text not null,
  html text not null,
  body_text text not null,
  status text not null default 'pending' check (status in ('pending', 'taken', 'sent', 'failed')),
  detail text,
  created_at timestamptz not null default now(),
  taken_at timestamptz,
  finished_at timestamptz
);
create unique index if not exists outbox_idem_key on private.outbox (idem);
create index if not exists outbox_status_idx on private.outbox (status, created_at);

-- The Claude key: a long random secret that lets the Claude task read the outbox and nothing else.
insert into private.kv (key, value)
values ('claude_key', replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''))
on conflict (key) do nothing;

-- The GitHub key: lets the board's GitHub workflow move cards, and nothing else.
insert into private.kv (key, value)
values ('github_key', replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''))
on conflict (key) do nothing;

-- Boards that never got Resend or Brevo working: switch them to Claude.
update public.notify_settings set provider = 'claude'
 where provider in ('resend', 'brevo')
   and not exists (select 1 from private.email_log where status = 'sent' and provider in ('resend', 'brevo'));

-- ---------------------------------------------------------------------
-- Who is signed in?
--   * a password account that was claimed with the person's join code, or
--   * an email-code or Google sign-in whose confirmed email is on the roster.
-- ---------------------------------------------------------------------

create or replace function private.me() returns uuid
language sql stable security definer set search_path = '' as $$
  select p.id
    from public.people p
   where p.active
     and (p.user_id = (select auth.uid())
          or exists (
            select 1 from auth.users u
             where u.id = (select auth.uid())
               and lower(u.email) = lower(p.email)
               and u.email_confirmed_at is not null
               -- A password session only counts through the join code above: anyone can
               -- register a password for an email they do not own.
               and position('"password"' in coalesce((select auth.jwt()) -> 'amr', '[]'::jsonb)::text) = 0))
   order by (p.user_id = (select auth.uid())) desc nulls last
   limit 1
$$;

create or replace function private.is_member() returns boolean
language sql stable security definer set search_path = '' as $$
  select private.me() is not null
$$;

create or replace function private.is_pm() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.people p where p.id = private.me() and p.role = 'pm')
$$;

-- ---------------------------------------------------------------------
-- People: guard rails
-- ---------------------------------------------------------------------

create or replace function private.people_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform pg_advisory_xact_lock(hashtext('nudge.people'));
  if tg_op = 'DELETE' then
    if old.role = 'pm' and old.active
       and not exists (select 1 from public.people where role = 'pm' and active and id <> old.id) then
      raise exception 'The board needs at least one active project manager' using errcode = '23514';
    end if;
    return old;
  end if;

  new.email := lower(trim(new.email));
  new.name := trim(new.name);
  if not private.valid_tz(new.timezone) then
    raise exception 'Unknown time zone: %', new.timezone using errcode = '22023';
  end if;
  if tg_op = 'INSERT' and new.user_id is null and new.join_code is null then
    new.join_code := private.new_code();
  end if;
  -- A new email means a new person may be behind it: drop the old password account and issue a fresh code.
  if tg_op = 'UPDATE' and new.email is distinct from old.email then
    new.user_id := null;
    new.join_code := private.new_code();
    new.join_tries := 0;
  end if;
  if tg_op = 'UPDATE' then
    if not private.is_system() then
      new.mute_token := old.mute_token;
      if old.role = 'pm' and new.email is distinct from old.email then
        raise exception 'To change a project manager''s email, make them a member first, change the email, then make them a PM again' using errcode = '42501';
      end if;
    end if;
    if old.role = 'pm' and old.active and (new.role <> 'pm' or not new.active)
       and not exists (select 1 from public.people where role = 'pm' and active and id <> old.id) then
      raise exception 'The board needs at least one active project manager' using errcode = '23514';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists people_guard_trg on public.people;
create trigger people_guard_trg before insert or update or delete on public.people
  for each row execute function private.people_guard();

-- People added before password sign-in existed get a join code now.
update public.people set join_code = private.new_code() where user_id is null and join_code is null;
-- Codes saved with a dash by an earlier version: store them plain, and forgive the failed tries that caused.
update public.people set join_code = private.clean_code(join_code), join_tries = 0
 where join_code is not null and join_code <> private.clean_code(join_code);

create or replace function private.board_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not private.valid_tz(new.timezone) then
    raise exception 'Unknown time zone: %', new.timezone using errcode = '22023';
  end if;
  return new;
end $$;
drop trigger if exists board_guard_trg on public.board;
create trigger board_guard_trg before insert or update on public.board
  for each row execute function private.board_guard();

-- ---------------------------------------------------------------------
-- Cards: server-controlled fields and who may assign
-- ---------------------------------------------------------------------

-- Has the current cycle passed its first day? (Work added on day one counts as planned.)
create or replace function private.mid_cycle() returns boolean
language sql stable security definer set search_path = '' as $$
  select (private.now_utc() at time zone b.timezone)::date > b.cycle_start from public.board b where b.id = 1
$$;

-- Planning fields that follow from the rest of the card
create or replace function private.tidy_planning(c public.cards) returns public.cards
language plpgsql stable security definer set search_path = '' as $$
begin
  c.horizon := coalesce(c.horizon, 'later');
  c.block_note := trim(coalesce(c.block_note, ''));
  if not c.blocked then
    c.waiting_on := null;
    c.block_note := '';
  elsif c.waiting_on is not null and not exists (select 1 from public.people where id = c.waiting_on and active) then
    raise exception 'A blocked card can only wait on someone active on the team' using errcode = '23514';
  end if;
  return c;
end $$;

create or replace function private.cards_before() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  me uuid := private.me();
  pm boolean := private.is_pm();
  sys boolean := private.is_system();
begin
  if tg_op = 'INSERT' then
    new.num := case when sys then coalesce(new.num, nextval('public.card_num_seq')) else nextval('public.card_num_seq') end;
    if not sys then
      new.version := 1;
      new.rolled := 0;
      new.archived_at := null;
      new.created_at := now();
      new.touched_at := now();
      new.status_since := now();
      new.updated_at := now();
      new.created_by := me;
      if not pm and (new.assignee_id is not null and new.assignee_id is distinct from me) then
        raise exception 'Only the project manager can assign tasks to other people' using errcode = '42501';
      end if;
      if not pm and new.reviewer_id is not null then
        raise exception 'Only the project manager can choose a reviewer' using errcode = '42501';
      end if;
    end if;
    new.done_at := case when new.status = 'done' then coalesce(new.done_at, now()) else null end;
    if new.status = 'done' then new.blocked := false; end if;
    new.unplanned := new.status <> 'backlog' and private.mid_cycle();
    new := private.tidy_planning(new);
    return new;
  end if;

  -- UPDATE
  if not sys then
    new.id := old.id;
    new.num := old.num;
    new.created_at := old.created_at;
    new.created_by := old.created_by;
    new.rolled := old.rolled;
    new.archived_at := old.archived_at;
    new.touched_at := now();
    if not pm then
      if new.assignee_id is distinct from old.assignee_id
         and not ((old.assignee_id is null and new.assignee_id = me)
                  or (old.assignee_id = me and new.assignee_id is null)) then
        raise exception 'Only the project manager can assign tasks to other people' using errcode = '42501';
      end if;
      if new.reviewer_id is distinct from old.reviewer_id then
        raise exception 'Only the project manager can choose a reviewer' using errcode = '42501';
      end if;
    end if;
  end if;
  new.version := old.version + 1;
  new.updated_at := now();
  if new.status is distinct from old.status then
    new.status_since := now();
    new.done_at := case when new.status = 'done' then now() else null end;
    if new.status = 'done' then new.blocked := false; end if;
    if new.status = 'backlog' then new.rolled := 0; end if;
    -- Joining the cycle after day one makes a card unplanned; going back to the backlog clears it
    if new.status = 'backlog' then new.unplanned := false;
    elsif old.status = 'backlog' then new.unplanned := private.mid_cycle();
    end if;
  end if;
  new := private.tidy_planning(new);
  return new;
end $$;

drop trigger if exists cards_before_trg on public.cards;
create trigger cards_before_trg before insert or update on public.cards
  for each row execute function private.cards_before();

-- ---------------------------------------------------------------------
-- Notifications: one place decides who is told what
-- ---------------------------------------------------------------------

-- Records an in-app notification (always) and queues an email (calmly).
create or replace function private.notify(
  p_recipient uuid, p_card public.cards, p_kind text, p_reason text,
  p_actor_name text, p_from text default null, p_to text default null
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  per public.people;
  s public.notify_settings;
  b public.board;
  ckey text;
  msg text;
  now_ts timestamptz := private.now_utc();
  deliv text;
begin
  select * into per from public.people where id = p_recipient and active;
  if not found then return; end if;
  select * into s from public.notify_settings where id = 1;
  select * into b from public.board where id = 1;
  ckey := b.card_prefix || '-' || p_card.num;

  msg := case p_reason
    when 'assigned'  then format('%s gave you %s: %s', p_actor_name, ckey, p_card.title)
    when 'review'    then format('%s moved %s to QA Test. It''s with you now: %s', p_actor_name, ckey, p_card.title)
    when 'security'  then format('%s moved %s to Security for your sign-off: %s', p_actor_name, ckey, p_card.title)
    when 'sent_back' then format('%s sent %s back to %s: %s', p_actor_name, ckey, private.status_name(p_to), p_card.title)
    when 'blocked'   then format('%s marked %s as blocked: %s', p_actor_name, ckey, p_card.title)
    when 'unblocked' then format('%s unblocked %s: %s', p_actor_name, ckey, p_card.title)
    when 'mentioned' then format('%s mentioned you on %s: %s', p_actor_name, ckey, p_card.title)
    when 'commented' then format('%s commented on %s: %s', p_actor_name, ckey, p_card.title)
    when 'waiting_on' then format('%s is blocked on %s and waiting on you%s: %s', p_actor_name, ckey,
                                  case when p_card.block_note <> '' then ' (' || p_card.block_note || ')' else '' end, p_card.title)
    else case when p_from is not null
           then format('%s moved %s from %s to %s: %s', p_actor_name, ckey, private.status_name(p_from), private.status_name(p_to), p_card.title)
           else format('%s moved %s to %s: %s', p_actor_name, ckey, private.status_name(p_to), p_card.title) end
  end;
  insert into public.notifications (recipient_id, card_id, kind, message, created_at)
  values (p_recipient, p_card.id, p_kind, msg, now_ts);

  if per.notify_mode = 'off' or p_reason in ('unblocked', 'commented') then return; end if;

  deliv := case
    when p_kind = 'update' then case when per.pm_instant then 'instant' else 'digest' end
    when per.notify_mode = 'calm' then 'digest'
    else 'instant' end;

  if deliv = 'instant' then
    insert into private.notify_queue as q
      (recipient_id, card_id, kind, reason, delivery, payload, first_event_at, send_after, created_at)
    values
      (p_recipient, p_card.id, p_kind, p_reason, 'instant',
       jsonb_build_object('actor', p_actor_name, 'from', p_from, 'to', p_to),
       now_ts, now_ts + make_interval(mins => s.debounce_min), now_ts)
    on conflict (recipient_id, card_id, kind) where status = 'pending' and delivery = 'instant'
    do update set
      reason = excluded.reason,
      -- keep where the card started, so a move that ends where it began is recognised as no change
      payload = excluded.payload || case when q.payload ->> 'from' is not null
                                         then jsonb_build_object('from', q.payload -> 'from') else '{}'::jsonb end,
      send_after = least(excluded.send_after, q.first_event_at + make_interval(mins => s.debounce_max_min));
  else
    insert into private.notify_queue
      (recipient_id, card_id, kind, reason, delivery, payload, first_event_at, send_after, created_at)
    values
      (p_recipient, p_card.id, p_kind, p_reason, 'digest',
       jsonb_build_object('actor', p_actor_name, 'from', p_from, 'to', p_to),
       now_ts, now_ts, now_ts);
  end if;
end $$;

-- Who reviews a card: its reviewer, else the board default, else the first PM. Inactive people are skipped.
create or replace function private.reviewer_for(c public.cards, b public.board) returns uuid
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select id from public.people where id = c.reviewer_id and active),
    (select id from public.people where id = b.default_reviewer_id and active),
    (select id from public.people where role = 'pm' and active order by created_at, id limit 1))
$$;

-- Who signs off Security: the column's default reviewer, else every security reviewer. Inactive people are skipped.
create or replace function private.security_reviewers(b public.board) returns uuid[]
language sql stable security definer set search_path = '' as $$
  select case when exists (select 1 from public.people where id = b.security_reviewer_id and active)
              then array[b.security_reviewer_id]
              else coalesce((select array_agg(id order by created_at, id) from public.people where security and active), '{}') end
$$;

-- The reviewer(s) a card is with while it sits in QA Test or Security; empty in other columns
create or replace function private.column_reviewers(c public.cards, b public.board) returns uuid[]
language sql stable security definer set search_path = '' as $$
  select case c.status
    when 'review' then array_remove(array[private.reviewer_for(c, b)], null)
    when 'security' then private.security_reviewers(b)
    else '{}'::uuid[] end
$$;

create or replace function private.cards_after() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := private.me();
  actor_name text;
  b public.board;
  ckey text;
  owner uuid;
  reason text;
  pm_id uuid;
  sec uuid[] := '{}';
  now_ts timestamptz := private.now_utc();
begin
  select * into b from public.board where id = 1;
  ckey := b.card_prefix || '-' || new.num;
  if actor is not null then
    select name into actor_name from public.people where id = actor;
  end if;
  -- Moves made by the GitHub workflow name the GitHub user
  actor_name := coalesce(actor_name, nullif(current_setting('nb.actor_name', true), ''), 'Someone');

  if tg_op = 'INSERT' then
    insert into public.card_events (card_id, card_key, title, from_status, to_status, actor_id, at)
    values (new.id, ckey, new.title, null, new.status, actor, now_ts);
    if new.status = 'review' then
      owner := private.reviewer_for(new, b);
      if owner is not null and owner is distinct from actor then
        perform private.notify(owner, new, 'turn', 'review', actor_name, null, 'review');
      end if;
    elsif new.status = 'security' then
      foreach pm_id in array private.security_reviewers(b) loop
        if pm_id is distinct from actor then
          perform private.notify(pm_id, new, 'turn', 'security', actor_name, null, 'security');
        end if;
      end loop;
    end if;
    if new.assignee_id is not null and new.assignee_id is distinct from actor and new.status <> 'done' then
      perform private.notify(new.assignee_id, new, 'turn', 'assigned', actor_name);
    end if;
    if new.blocked and new.waiting_on is not null and new.waiting_on is distinct from actor then
      perform private.notify(new.waiting_on, new, 'turn', 'waiting_on', actor_name);
    end if;
    return new;
  end if;

  if new.archived_at is not null then return new; end if;

  if new.status is distinct from old.status then
    insert into public.card_events (card_id, card_key, title, from_status, to_status, actor_id, at)
    values (new.id, ckey, new.title, old.status, new.status, actor, now_ts);

    if new.status = 'security' then sec := private.security_reviewers(b); end if;
    -- Whose turn is it now?
    owner := case
      when new.status in ('todo', 'doing') then new.assignee_id
      when new.status = 'review' then private.reviewer_for(new, b)
      else null end;
    reason := case
      when new.status = 'review' and old.status in ('security', 'done') then 'sent_back'   -- back to QA Test
      when new.status = 'review' then 'review'
      when old.status in ('review', 'security') and new.status in ('todo', 'doing') then 'sent_back'
      else 'moved' end;
    if owner is not null and owner is distinct from actor then
      if new.status in ('todo', 'doing') and old.status in ('todo', 'doing') then
        -- shuffling inside the owner's own columns is not a hand-off: digest only
        perform private.notify(owner, new, 'update', 'moved', actor_name, old.status, new.status);
      else
        perform private.notify(owner, new, 'turn', reason, actor_name, old.status, new.status);
      end if;
    end if;

    -- The assignee hears about it in the digest if someone else moved it
    if new.assignee_id is not null and new.assignee_id is distinct from actor
       and new.assignee_id is distinct from owner and not (new.assignee_id = any (sec)) then
      perform private.notify(new.assignee_id, new, 'update', 'moved', actor_name, old.status, new.status);
    end if;

    -- Security: the column's default reviewer (else every security reviewer) is asked to sign it off
    if new.status = 'security' then
      foreach pm_id in array sec loop
        if pm_id is distinct from actor then
          perform private.notify(pm_id, new, 'turn', case when old.status = 'done' then 'sent_back' else 'security' end,
                                 actor_name, old.status, new.status);
        end if;
      end loop;
    end if;

    -- PMs get a digest line for every move (never for their own moves)
    for pm_id in
      select id from public.people
       where role = 'pm' and active and id is distinct from actor and id is distinct from owner
         and id is distinct from new.assignee_id and not (id = any (sec))
    loop
      perform private.notify(pm_id, new, 'update', 'moved', actor_name, old.status, new.status);
    end loop;
  end if;

  if new.assignee_id is distinct from old.assignee_id and new.assignee_id is not null
     and new.assignee_id is distinct from actor and new.status <> 'done' then
    perform private.notify(new.assignee_id, new, 'turn', 'assigned', actor_name);
  end if;

  if new.reviewer_id is distinct from old.reviewer_id and new.reviewer_id is not null
     and new.status = 'review' and new.reviewer_id is distinct from actor then
    perform private.notify(new.reviewer_id, new, 'turn', 'review', actor_name, old.status, new.status);
  end if;

  if new.blocked and not old.blocked then
    for pm_id in select id from public.people where role = 'pm' and active and id is distinct from actor loop
      perform private.notify(pm_id, new, 'alert', 'blocked', actor_name);
    end loop;
    -- A card blocked in QA Test or Security is stuck with that column's reviewer: they hear too (PMs already have)
    foreach pm_id in array private.column_reviewers(new, b) loop
      if pm_id is distinct from actor and not exists (select 1 from public.people where id = pm_id and role = 'pm') then
        perform private.notify(pm_id, new, 'alert', 'blocked', actor_name);
      end if;
    end loop;
  elsif old.blocked and not new.blocked and new.status <> 'done' then
    for pm_id in select id from public.people where role = 'pm' and active and id is distinct from actor loop
      perform private.notify(pm_id, new, 'update', 'unblocked', actor_name);
    end loop;
  end if;

  -- "Blocked by @person": the person who can unblock it hears about it straight away
  if new.blocked and new.waiting_on is not null and new.waiting_on is distinct from actor
     and (not old.blocked or new.waiting_on is distinct from old.waiting_on) then
    perform private.notify(new.waiting_on, new, 'turn', 'waiting_on', actor_name);
  end if;

  return new;
end $$;

create or replace function private.cards_before_delete() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.card_events set title = '(deleted card)' where card_id = old.id;
  return old;
end $$;
drop trigger if exists cards_before_delete_trg on public.cards;
create trigger cards_before_delete_trg before delete on public.cards
  for each row execute function private.cards_before_delete();

drop trigger if exists cards_after_trg on public.cards;
create trigger cards_after_trg after insert or update on public.cards
  for each row execute function private.cards_after();

-- ---------------------------------------------------------------------
-- Comments: who wrote it is decided here, and mentions are checked against the roster
-- ---------------------------------------------------------------------

create or replace function private.comments_before() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_system() then
    new.author_id := private.me();
    new.created_at := private.now_utc();
  end if;
  new.body := trim(new.body);
  -- only active teammates, never the author, each once, at most 20
  new.mentions := coalesce((select array_agg(id) from (
      select p.id from public.people p
       where p.id = any(coalesce(new.mentions, '{}')) and p.active and p.id is distinct from new.author_id
       limit 20) m), '{}');
  return new;
end $$;
drop trigger if exists comments_before_trg on public.card_comments;
create trigger comments_before_trg before insert on public.card_comments
  for each row execute function private.comments_before();

-- Mentioned people hear about it (bell, desktop, and email like a task that needs them).
-- The card's owner sees new comments in the bell.
create or replace function private.comments_after() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  c public.cards;
  actor_name text;
  pid uuid;
begin
  select * into c from public.cards where id = new.card_id;
  if not found then return null; end if;
  actor_name := coalesce((select name from public.people where id = new.author_id), 'Someone');
  foreach pid in array new.mentions loop
    perform private.notify(pid, c, 'turn', 'mentioned', actor_name);
  end loop;
  if c.assignee_id is not null and c.assignee_id is distinct from new.author_id
     and not (c.assignee_id = any(new.mentions)) then
    perform private.notify(c.assignee_id, c, 'update', 'commented', actor_name);
  end if;
  return null;
end $$;
drop trigger if exists comments_after_trg on public.card_comments;
create trigger comments_after_trg after insert on public.card_comments
  for each row execute function private.comments_after();

-- ---------------------------------------------------------------------
-- Sending email over HTTPS (Resend or Brevo). Needs pg_net and Vault.
-- ---------------------------------------------------------------------

create or replace function private.send_email(
  p_to_email text, p_to_name text, p_subject text, p_html text, p_text text, p_idem text
) returns bigint
language plpgsql security definer set search_path = '' as $$
declare
  s public.notify_settings;
  api_key text;
  rid bigint;
begin
  select * into s from public.notify_settings where id = 1;
  if s.provider = 'log' then
    return null;
  end if;
  if s.provider = 'claude' then
    if s.app_url = '' then
      raise exception 'Set the board web address in the Team panel first (it makes the buttons and the pause links work).';
    end if;
    -- Claude sends it later. A repeat of the same message (same idem) is ignored.
    insert into private.outbox (idem, to_email, to_name, subject, html, body_text, created_at)
    values (p_idem, p_to_email, coalesce(p_to_name, ''), p_subject, p_html, p_text, private.now_utc())
    on conflict (idem) do nothing;
    return null;
  end if;

  -- Resend and Brevo, sent straight from the database. Not used while the provider is 'claude'.
  select decrypted_secret into api_key from vault.decrypted_secrets where name = 'email_api_key' limit 1;
  if api_key is null or api_key = '' then
    raise exception 'No email API key yet. Save it in Vault under the name email_api_key (see docs/SETUP.md).';
  end if;
  if s.from_email = '' then
    raise exception 'Set the "From" email address in the Team panel first.';
  end if;
  if s.app_url = '' then
    raise exception 'Set the board web address in the Team panel first (it makes the buttons and the pause links work).';
  end if;

  if s.provider = 'resend' then
    select net.http_post(
      url := 'https://api.resend.com/emails',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || api_key,
        'Idempotency-Key', p_idem,
        'User-Agent', 'nudge-board/1.0'),
      body := jsonb_build_object(
        'from', s.from_name || ' <' || s.from_email || '>',
        'to', jsonb_build_array(p_to_email),
        'subject', p_subject,
        'html', p_html,
        'text', p_text),
      timeout_milliseconds := 10000) into rid;
  else
    select net.http_post(
      url := 'https://api.brevo.com/v3/smtp/email',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'accept', 'application/json',
        'api-key', api_key,
        'User-Agent', 'nudge-board/1.0'),
      body := jsonb_build_object(
        'sender', jsonb_build_object('name', s.from_name, 'email', s.from_email),
        'to', jsonb_build_array(jsonb_build_object('email', p_to_email, 'name', p_to_name)),
        'subject', p_subject,
        'htmlContent', p_html,
        'textContent', p_text),
      timeout_milliseconds := 10000) into rid;
  end if;
  return rid;
end $$;

-- ---------------------------------------------------------------------
-- Email copy. Short, friendly, one action.
-- ---------------------------------------------------------------------

create or replace function private.email_shell(
  p public.people, s public.notify_settings, b public.board,
  p_body_html text, p_cta_label text, p_cta_url text
) returns text
language plpgsql stable security definer set search_path = '' as $$
declare
  base text := regexp_replace(s.app_url, '#.*$', '');
  btn text := '';
  foot text;
begin
  if p_cta_url is not null and p_cta_url <> '' then
    btn := format('<p style="margin:20px 0 4px"><a href="%s" style="background:#0f766e;color:#ffffff;text-decoration:none;padding:10px 16px;border-radius:8px;font-weight:600;display:inline-block">%s</a></p>',
                  private.h(p_cta_url), private.h(p_cta_label));
  end if;
  foot := format('You get this because you are on the %s board.', private.h(b.name));
  if base <> '' then
    foot := foot || format(' <a href="%1$s#mute=%2$s&amp;mode=pause" style="color:#6b7280">Pause until Monday</a> &middot; <a href="%1$s#mute=%2$s&amp;mode=calm" style="color:#6b7280">Daily digest only</a> &middot; <a href="%1$s#mute=%2$s&amp;mode=off" style="color:#6b7280">Turn off emails</a>',
                           private.h(base), p.mute_token);
  end if;
  return '<div style="font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;font-size:15px;line-height:1.5;color:#111827;max-width:520px;margin:0 auto;padding:16px">'
    || '<p style="margin:0 0 12px">Hi ' || private.h(split_part(p.name, ' ', 1)) || ',</p>'
    || p_body_html || btn
    || '<p style="margin:24px 0 0;font-size:12px;color:#6b7280">' || foot || '</p></div>';
end $$;

create or replace function private.email_foot_text(p public.people, s public.notify_settings) returns text
language sql stable security definer set search_path = '' as $$
  select case when regexp_replace(s.app_url, '#.*$', '') = '' then ''
    else E'\n\nPause until Monday: ' || regexp_replace(s.app_url, '#.*$', '') || '#mute=' || p.mute_token || E'&mode=pause\n'
      || 'Daily digest only: ' || regexp_replace(s.app_url, '#.*$', '') || '#mute=' || p.mute_token || E'&mode=calm\n'
      || 'Turn off emails: ' || regexp_replace(s.app_url, '#.*$', '') || '#mute=' || p.mute_token || '&mode=off' end
$$;

create or replace function private.show_title(t text, s public.notify_settings) returns text
language sql immutable as $$
  select case when s.hide_titles then '(details on the board)' else t end
$$;

-- items: [{key, title, reason, actor, status, num}]
create or replace function private.render_instant(
  p public.people, items jsonb, s public.notify_settings, b public.board
) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  n int := jsonb_array_length(items);
  it jsonb := items -> 0;
  subj text; line text; line_txt text; body text; txt text;
  base text := regexp_replace(s.app_url, '#.*$', '');
  cta_url text := '';
  t text; st text; actor text; k text; i int;
begin
  if n = 1 then
    t := private.show_title(it ->> 'title', s);
    st := private.status_name(it ->> 'status');
    actor := coalesce(it ->> 'actor', 'Someone');
    k := it ->> 'key';
    case it ->> 'reason'
      when 'assigned' then
        subj := 'New for you: ' || left(t, 60);
        line := format('%s gave you <b>%s</b> &ldquo;%s&rdquo;.', private.h(actor), private.h(k), private.h(t));
        line_txt := format('%s gave you %s "%s".', actor, k, t);
        if it ->> 'due' is not null then
          line := line || ' Due ' || private.h(to_char((it ->> 'due')::date, 'Dy Mon DD')) || '.';
          line_txt := line_txt || ' Due ' || to_char((it ->> 'due')::date, 'Dy Mon DD') || '.';
        end if;
        line := line || ' It''s waiting in ' || private.h(st) || ' whenever you''re ready.';
        line_txt := line_txt || ' It''s waiting in ' || st || ' whenever you''re ready.';
      when 'review' then
        subj := 'Your turn: ' || left(t, 60);
        line := format('%s moved <b>%s</b> &ldquo;%s&rdquo; to QA Test. It''s with you now, whenever you''re ready.', private.h(actor), private.h(k), private.h(t));
        line_txt := format('%s moved %s "%s" to QA Test. It''s with you now, whenever you''re ready.', actor, k, t);
      when 'security' then
        subj := 'Security sign-off: ' || left(t, 60);
        line := format('%s moved <b>%s</b> &ldquo;%s&rdquo; to Security. It needs your sign-off before it is done.', private.h(actor), private.h(k), private.h(t));
        line_txt := format('%s moved %s "%s" to Security. It needs your sign-off before it is done.', actor, k, t);
      when 'sent_back' then
        subj := 'Back with you: ' || left(t, 60);
        line := format('%s sent <b>%s</b> &ldquo;%s&rdquo; back to %s. Have a look when you can.', private.h(actor), private.h(k), private.h(t), private.h(st));
        line_txt := format('%s sent %s "%s" back to %s. Have a look when you can.', actor, k, t, st);
      when 'waiting_on' then
        subj := 'Waiting on you: ' || left(t, 60);
        line := format('%s is blocked on <b>%s</b> &ldquo;%s&rdquo; and needs you to move it forward.', private.h(actor), private.h(k), private.h(t));
        line_txt := format('%s is blocked on %s "%s" and needs you to move it forward.', actor, k, t);
      when 'mentioned' then
        subj := 'Mentioned: ' || left(t, 60);
        line := format('%s mentioned you in a comment on <b>%s</b> &ldquo;%s&rdquo;.', private.h(actor), private.h(k), private.h(t));
        line_txt := format('%s mentioned you in a comment on %s "%s".', actor, k, t);
      when 'blocked' then
        subj := 'Blocked: ' || left(t, 60);
        line := format('%s marked <b>%s</b> &ldquo;%s&rdquo; as blocked. It might be worth a quick word.', private.h(actor), private.h(k), private.h(t));
        line_txt := format('%s marked %s "%s" as blocked. It might be worth a quick word.', actor, k, t);
      else
        subj := format('%s is now in %s', k, st);
        line := format('%s moved <b>%s</b> &ldquo;%s&rdquo; to %s.', private.h(actor), private.h(k), private.h(t), private.h(st));
        line_txt := format('%s moved %s "%s" to %s.', actor, k, t, st);
    end case;
    body := '<p style="margin:0">' || line || '</p>';
    txt := 'Hi ' || split_part(p.name, ' ', 1) || E',\n\n' || line_txt;
    if base <> '' then cta_url := base || '#card=' || (it ->> 'num'); end if;
    if cta_url <> '' then txt := txt || E'\n\nOpen the card: ' || cta_url; end if;
    txt := txt || private.email_foot_text(p, s);
    return jsonb_build_object('subject', subj,
      'html', private.email_shell(p, s, b, body, 'Open the card', cta_url), 'text', txt);
  end if;

  body := '<p style="margin:0 0 8px">' || n || ' cards are waiting for you:</p><ul style="margin:0;padding-left:20px">';
  txt := 'Hi ' || split_part(p.name, ' ', 1) || E',\n\n' || n || E' cards are waiting for you:\n';
  for i in 0 .. n - 1 loop
    it := items -> i;
    t := private.show_title(it ->> 'title', s);
    st := private.status_name(it ->> 'status');
    actor := coalesce(it ->> 'actor', 'Someone');
    line := case it ->> 'reason'
      when 'assigned' then 'assigned to you by ' || actor
      when 'review' then 'ready for QA'
      when 'security' then 'ready for security sign-off'
      when 'sent_back' then 'sent back to ' || st
      when 'blocked' then 'marked blocked by ' || actor
      when 'mentioned' then 'mentioned by ' || actor
      when 'waiting_on' then 'waiting on you, from ' || actor
      else 'now in ' || st end;
    body := body || format('<li><b>%s</b> %s <span style="color:#6b7280">(%s)</span></li>',
                           private.h(it ->> 'key'), private.h(t), private.h(line));
    txt := txt || format(E'- %s %s (%s)\n', it ->> 'key', t, line);
  end loop;
  body := body || '</ul>';
  if base <> '' then cta_url := base; txt := txt || E'\nOpen the board: ' || base; end if;
  txt := txt || private.email_foot_text(p, s);
  return jsonb_build_object('subject', n || ' cards are waiting for you',
    'html', private.email_shell(p, s, b, body, 'Open the board', cta_url), 'text', txt);
end $$;

-- waiting: [{key,title,reason,actor,status,num}]  moved: [{key,title,actor,from,to}]
-- blocked / due: [{key,title,assignee,due}]
create or replace function private.render_digest(
  p public.people, waiting jsonb, moved jsonb, blocked jsonb, due jsonb,
  s public.notify_settings, b public.board
) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  base text := regexp_replace(s.app_url, '#.*$', '');
  body text := ''; txt text; subj text; it jsonb; i int; line text;
  total int;
  today date := (private.now_utc() at time zone b.timezone)::date;
  d int;
begin
  total := jsonb_array_length(waiting) + jsonb_array_length(moved);
  txt := 'Hi ' || split_part(p.name, ' ', 1) || E',\n';

  if jsonb_array_length(waiting) > 0 then
    body := body || '<p style="margin:0 0 6px"><b>Waiting for you</b></p><ul style="margin:0 0 14px;padding-left:20px">';
    txt := txt || E'\nWaiting for you\n';
    for i in 0 .. jsonb_array_length(waiting) - 1 loop
      it := waiting -> i;
      line := case it ->> 'reason'
        when 'assigned' then 'assigned to you by ' || coalesce(it ->> 'actor', 'Someone')
        when 'review' then 'ready for QA'
        when 'security' then 'ready for security sign-off'
        when 'sent_back' then 'sent back to ' || private.status_name(it ->> 'status')
        when 'blocked' then 'marked blocked'
        when 'mentioned' then 'mentioned by ' || coalesce(it ->> 'actor', 'Someone')
        when 'waiting_on' then 'waiting on you, from ' || coalesce(it ->> 'actor', 'Someone')
        else 'now in ' || private.status_name(it ->> 'status') end;
      body := body || format('<li><b>%s</b> %s <span style="color:#6b7280">(%s)</span></li>',
        private.h(it ->> 'key'), private.h(private.show_title(it ->> 'title', s)), private.h(line));
      txt := txt || format(E'- %s %s (%s)\n', it ->> 'key', private.show_title(it ->> 'title', s), line);
    end loop;
    body := body || '</ul>';
  end if;

  if jsonb_array_length(moved) > 0 then
    body := body || '<p style="margin:0 0 6px"><b>Moved</b></p><ul style="margin:0 0 14px;padding-left:20px">';
    txt := txt || E'\nMoved\n';
    for i in 0 .. least(jsonb_array_length(moved), 10) - 1 loop
      it := moved -> i;
      line := format('%s: %s to %s', coalesce(it ->> 'actor', 'Someone'),
                     private.status_name(it ->> 'from'), private.status_name(it ->> 'to'));
      body := body || format('<li><b>%s</b> %s <span style="color:#6b7280">(%s)</span></li>',
        private.h(it ->> 'key'), private.h(private.show_title(it ->> 'title', s)), private.h(line));
      txt := txt || format(E'- %s %s (%s)\n', it ->> 'key', private.show_title(it ->> 'title', s), line);
    end loop;
    if jsonb_array_length(moved) > 10 then
      body := body || format('<li style="color:#6b7280">and %s more</li>', jsonb_array_length(moved) - 10);
      txt := txt || format(E'- and %s more\n', jsonb_array_length(moved) - 10);
    end if;
    body := body || '</ul>';
  end if;

  if jsonb_array_length(blocked) > 0 then
    body := body || '<p style="margin:0 0 6px"><b>Blocked right now</b></p><ul style="margin:0 0 14px;padding-left:20px">';
    txt := txt || E'\nBlocked right now\n';
    for i in 0 .. least(jsonb_array_length(blocked), 8) - 1 loop
      it := blocked -> i;
      body := body || format('<li><b>%s</b> %s%s</li>', private.h(it ->> 'key'),
        private.h(private.show_title(it ->> 'title', s)),
        case when it ->> 'assignee' is not null then ' <span style="color:#6b7280">(' || private.h(it ->> 'assignee') || ')</span>' else '' end);
      txt := txt || format(E'- %s %s%s\n', it ->> 'key', private.show_title(it ->> 'title', s),
        case when it ->> 'assignee' is not null then ' (' || (it ->> 'assignee') || ')' else '' end);
    end loop;
    body := body || '</ul>';
  end if;

  if jsonb_array_length(due) > 0 then
    body := body || '<p style="margin:0 0 6px"><b>Due soon or overdue</b></p><ul style="margin:0 0 14px;padding-left:20px">';
    txt := txt || E'\nDue soon or overdue\n';
    for i in 0 .. least(jsonb_array_length(due), 8) - 1 loop
      it := due -> i;
      d := (it ->> 'due')::date - today;
      line := case when d < 0 then (-d) || 'd overdue' when d = 0 then 'due today' else 'due tomorrow' end;
      body := body || format('<li><b>%s</b> %s <span style="color:#6b7280">(%s)</span></li>',
        private.h(it ->> 'key'), private.h(private.show_title(it ->> 'title', s)), private.h(line));
      txt := txt || format(E'- %s %s (%s)\n', it ->> 'key', private.show_title(it ->> 'title', s), line);
    end loop;
    body := body || '</ul>';
  end if;

  subj := case
    when jsonb_array_length(waiting) > 0 and total > 0 then format('Board update: %s for you, %s moved', jsonb_array_length(waiting), jsonb_array_length(moved))
    when jsonb_array_length(waiting) > 0 then format('%s card%s waiting for you', jsonb_array_length(waiting), case when jsonb_array_length(waiting) > 1 then 's' else '' end)
    when jsonb_array_length(moved) > 0 then format('Board update: %s card%s moved', jsonb_array_length(moved), case when jsonb_array_length(moved) > 1 then 's' else '' end)
    else 'Board update: a few things need a look' end;

  if base <> '' then txt := txt || E'\nOpen the board: ' || base; end if;
  txt := txt || private.email_foot_text(p, s);
  return jsonb_build_object('subject', subj,
    'html', private.email_shell(p, s, b, body, 'Open the board', base), 'text', txt);
end $$;

-- ---------------------------------------------------------------------
-- The worker
-- ---------------------------------------------------------------------

-- Is a queued message still true? Checked at send time, so an accidental
-- drag that was undone never becomes an email.
create or replace function private.item_is_current(q private.notify_queue, b public.board) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare
  c public.cards;
begin
  if q.card_id is null then return true; end if;
  select * into c from public.cards where id = q.card_id and archived_at is null;
  if not found then return false; end if;
  if q.kind = 'update' then
    if q.delivery = 'instant' and q.reason = 'moved' then
      return c.status = coalesce(q.payload ->> 'to', c.status) and c.status is distinct from (q.payload ->> 'from');
    end if;
    return true;
  end if;
  case q.reason
    when 'assigned' then
      -- still theirs, not finished, and they have not already picked it up themselves
      return c.assignee_id = q.recipient_id and c.status <> 'done'
         and not exists (select 1 from public.card_events e
                          where e.card_id = c.id and e.actor_id = q.recipient_id and e.at >= q.first_event_at);
    when 'review' then
      return c.status = 'review' and private.reviewer_for(c, b) = q.recipient_id;
    when 'security' then
      return c.status = 'security' and q.recipient_id = any (private.security_reviewers(b));
    when 'sent_back' then
      return (c.status in ('todo', 'doing') and c.assignee_id = q.recipient_id)
          or q.recipient_id = any (private.column_reviewers(c, b));
    when 'moved' then
      return c.assignee_id = q.recipient_id and c.status = coalesce(q.payload ->> 'to', c.status);
    when 'blocked' then
      return c.blocked;
    when 'waiting_on' then
      return c.blocked and c.waiting_on = q.recipient_id;
    else
      return true;
  end case;
end $$;

create or replace function private.next_work_start(ts timestamptz, tz text, work_start int) returns timestamptz
language plpgsql stable set search_path = '' as $$
declare
  local_ts timestamp := ts at time zone tz;
  d timestamp := date_trunc('day', local_ts);
  cand timestamp;
  i int;
begin
  for i in 0 .. 8 loop
    cand := d + make_interval(hours => work_start);
    if extract(isodow from cand) <= 5 and cand > local_ts then
      return cand at time zone tz;
    end if;
    d := d + interval '1 day';
  end loop;
  return ts + interval '1 day';
end $$;

-- Look up what the email provider said about earlier sends.
create or replace function private.reconcile_emails(now_ts timestamptz) returns void
language plpgsql security definer set search_path = '' as $$
declare
  l record;
  r record;
  perm boolean;
begin
  for l in select * from private.email_log where status = 'sending' and request_id is not null loop
    select * into r from net._http_response where id = l.request_id;
    if found then
      if r.status_code between 200 and 299 then
        update private.email_log set status = 'sent', finished_at = now_ts, detail = 'Accepted by the email provider' where id = l.id;
        update private.notify_queue set status = 'sent', finished_at = now_ts where email_id = l.id and status = 'sending';
      else
        -- A 4xx other than "slow down / try again" will not get better by repeating it.
        perm := coalesce(r.status_code between 400 and 499 and r.status_code not in (408, 409, 425, 429), false);
        update private.email_log set status = 'failed', finished_at = now_ts,
          detail = left(coalesce('HTTP ' || r.status_code || ' ' || coalesce(r.content, ''), r.error_msg, 'Unknown error'), 400)
         where id = l.id;
        perform private.retry_items(l.id, now_ts, perm);
        if not perm then perform private.release_digest_slot(l.id); end if;
      end if;
    elsif l.created_at < now_ts - interval '15 minutes' then
      update private.email_log set status = 'failed', finished_at = now_ts, detail = 'No answer from the email provider' where id = l.id;
      perform private.retry_items(l.id, now_ts, false);
      perform private.release_digest_slot(l.id);
    end if;
  end loop;
end $$;

create or replace function private.retry_items(p_email uuid, now_ts timestamptz, p_permanent boolean default false) returns void
language plpgsql security definer set search_path = '' as $$
declare
  qi record;
begin
  for qi in select * from private.notify_queue where email_id = p_email and status = 'sending' loop
    if p_permanent or qi.attempts + 1 >= 3 then
      update private.notify_queue set status = 'failed', attempts = attempts + 1, finished_at = now_ts where id = qi.id;
    elsif qi.delivery = 'instant' and exists (
        select 1 from private.notify_queue x
         where x.recipient_id = qi.recipient_id and x.card_id is not distinct from qi.card_id
           and x.kind = qi.kind and x.status = 'pending' and x.delivery = 'instant') then
      update private.notify_queue set status = 'cancelled', finished_at = now_ts where id = qi.id;
    else
      update private.notify_queue set status = 'pending', attempts = attempts + 1, email_id = null,
        send_after = now_ts + case qi.attempts when 0 then interval '1 minute' else interval '5 minutes' end
       where id = qi.id;
    end if;
  end loop;
end $$;

-- A digest that failed may be tried again by the next tick, up to three times in all.
create or replace function private.release_digest_slot(p_log uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  l private.email_log;
  fails int;
begin
  select * into l from private.email_log where id = p_log;
  if not found or l.kind <> 'digest' or l.slot is null or l.recipient_id is null then return; end if;
  select count(*) into fails from private.email_log
   where recipient_id = l.recipient_id and kind = 'digest' and slot = l.slot and status = 'failed';
  if fails < 3 then
    delete from private.digest_slots where person_id = l.recipient_id and slot = l.slot;
  end if;
end $$;

create or replace function private.process_instant(s public.notify_settings, now_ts timestamptz) returns void
language plpgsql security definer set search_path = '' as $$
declare
  rc record;
  p public.people;
  b public.board;
  n int;
  local_ts timestamp;
  in_hours boolean;
  last_sent timestamptz;
  sent_today int;
  sent_team int;
  day_start timestamptz;
  items jsonb;
  ids uuid[];
  rendered jsonb;
  log_id uuid;
  rid bigint;
  idem text;
begin
  select * into b from public.board where id = 1;

  for rc in
    select distinct recipient_id from private.notify_queue
     where status = 'pending' and delivery = 'instant' and send_after <= now_ts
  loop
    select * into p from public.people where id = rc.recipient_id;
    if not found or not p.active or p.notify_mode = 'off' then
      update private.notify_queue set status = 'cancelled', finished_at = now_ts
       where recipient_id = rc.recipient_id and status = 'pending' and delivery = 'instant' and send_after <= now_ts;
      continue;
    end if;
    if p.notify_mode = 'calm' or (p.muted_until is not null and p.muted_until > now_ts) then
      -- calm people, and people on a pause, hear about it in the next digest instead
      update private.notify_queue set delivery = 'digest'
       where recipient_id = p.id and status = 'pending' and delivery = 'instant' and send_after <= now_ts;
      continue;
    end if;

    -- 1. Only keep what is still true
    update private.notify_queue q set status = 'cancelled', finished_at = now_ts
     where q.recipient_id = p.id and q.status = 'pending' and q.delivery = 'instant' and q.send_after <= now_ts
       and not private.item_is_current(q, b);
    select count(*) into n from private.notify_queue
     where recipient_id = p.id and status = 'pending' and delivery = 'instant' and send_after <= now_ts;
    if n = 0 then continue; end if;

    -- 2. Working hours in the person's own time zone: hold, never drop
    local_ts := now_ts at time zone p.timezone;
    in_hours := extract(isodow from local_ts) <= 5
                and extract(hour from local_ts) >= s.work_start and extract(hour from local_ts) < s.work_end;
    if not in_hours then
      update private.notify_queue set send_after = private.next_work_start(now_ts, p.timezone, s.work_start)
       where recipient_id = p.id and status = 'pending' and delivery = 'instant' and send_after <= now_ts;
      continue;
    end if;

    -- 3. Space emails out
    select max(created_at) into last_sent from private.email_log
     where recipient_id = p.id and kind = 'instant' and status in ('sending', 'sent');
    if last_sent is not null and last_sent + make_interval(mins => s.min_gap_min) > now_ts then
      update private.notify_queue set send_after = last_sent + make_interval(mins => s.min_gap_min)
       where recipient_id = p.id and status = 'pending' and delivery = 'instant' and send_after <= now_ts;
      continue;
    end if;

    -- 4. Daily caps: overflow moves to the next digest
    day_start := date_trunc('day', local_ts) at time zone p.timezone;
    select count(*) into sent_today from private.email_log
     where recipient_id = p.id and kind = 'instant' and status in ('sending', 'sent') and created_at >= day_start;
    select count(*) into sent_team from private.email_log
     where status in ('sending', 'sent') and created_at >= date_trunc('day', now_ts at time zone 'UTC') at time zone 'UTC';
    if sent_today >= s.instant_daily_cap or sent_team >= s.daily_cap then
      update private.notify_queue set delivery = 'digest'
       where recipient_id = p.id and status = 'pending' and delivery = 'instant' and send_after <= now_ts;
      continue;
    end if;

    -- 5. One email with everything that is due for this person
    select coalesce(jsonb_agg(jsonb_build_object(
             'key', b.card_prefix || '-' || c.num, 'num', c.num, 'title', c.title, 'reason', q.reason,
             'actor', q.payload ->> 'actor', 'status', c.status, 'due', c.due) order by q.first_event_at, q.seq), '[]'::jsonb),
           array_agg(q.id)
      into items, ids
      from private.notify_queue q join public.cards c on c.id = q.card_id
     where q.recipient_id = p.id and q.status = 'pending' and q.delivery = 'instant' and q.send_after <= now_ts;
    if ids is null then
      update private.notify_queue set status = 'cancelled', finished_at = now_ts
       where recipient_id = p.id and status = 'pending' and delivery = 'instant' and send_after <= now_ts;
      continue;
    end if;

    rendered := private.render_instant(p, items, s, b);
    log_id := gen_random_uuid();
    idem := 'nudge-' || md5(array_to_string(ids, ',') || (rendered ->> 'html'));
    begin
      rid := private.send_email(p.email, p.name, rendered ->> 'subject', rendered ->> 'html', rendered ->> 'text', idem);
      insert into private.email_log (id, recipient_id, to_email, kind, subject, provider, request_id, status, detail, created_at, finished_at)
      values (log_id, p.id, p.email, 'instant', rendered ->> 'subject', s.provider, rid,
              case when rid is null then 'sent' else 'sending' end,
              case when rid is null then (case s.provider when 'claude' then 'Waiting for Claude to send it' else 'Logged only (provider is set to log)' end) end, now_ts,
              case when rid is null then now_ts end);
      update private.notify_queue
         set status = case when rid is null then 'sent' else 'sending' end, email_id = log_id,
             finished_at = case when rid is null then now_ts end
       where id = any (ids);
    exception when others then
      insert into private.email_log (id, recipient_id, to_email, kind, subject, provider, status, detail, created_at, finished_at)
      values (log_id, p.id, p.email, 'instant', rendered ->> 'subject', s.provider, 'failed', left(sqlerrm, 400), now_ts, now_ts);
      update private.notify_queue set email_id = log_id, status = 'sending' where id = any (ids);
      perform private.retry_items(log_id, now_ts, false);
    end;
  end loop;
end $$;

create or replace function private.process_digests(s public.notify_settings, now_ts timestamptz) returns void
language plpgsql security definer set search_path = '' as $$
declare
  p public.people;
  b public.board;
  local_ts timestamp;
  hr int;
  hours int[];
  v_slot text;
  first_slot boolean;
  waiting jsonb; moved jsonb; blocked jsonb; due jsonb;
  ids uuid[];
  rendered jsonb;
  log_id uuid;
  rid bigint;
  sent_team int;
  today date;
  claimed int;
  fails int;
begin
  select * into b from public.board where id = 1;
  today := (now_ts at time zone b.timezone)::date;

  for p in
    select * from public.people
     where active and notify_mode <> 'off' and (muted_until is null or muted_until <= now_ts)
  loop
    local_ts := now_ts at time zone p.timezone;
    continue when extract(isodow from local_ts) > 5;
    hr := extract(hour from local_ts)::int;
    hours := case when p.role = 'pm' then array[9, 13, 17] else array[9] end;
    continue when not (hr = any (hours));
    v_slot := to_char(local_ts, 'YYYY-MM-DD') || 'T' || lpad(hr::text, 2, '0');

    -- claim the slot first so nothing can send it twice
    insert into private.digest_slots (person_id, slot, done_at) values (p.id, v_slot, now_ts)
      on conflict do nothing;
    get diagnostics claimed = row_count;
    continue when claimed = 0;
    first_slot := hr = hours[1];
    blocked := '[]'::jsonb;
    due := '[]'::jsonb;

    -- Digest items stay good for five days, so Friday's items reach Monday's digest
    with cand as (
      select q.*, c.num, c.title, c.status as cur_status, c.due
        from private.notify_queue q join public.cards c on c.id = q.card_id
       where q.recipient_id = p.id and q.status = 'pending' and q.delivery = 'digest'
         and q.created_at > now_ts - interval '120 hours'
         and c.archived_at is null and private.item_is_current(q, b)
    )
    select
      coalesce((select jsonb_agg(jsonb_build_object('key', b.card_prefix || '-' || w.num, 'num', w.num, 'title', w.title,
                  'reason', w.reason, 'actor', w.payload ->> 'actor', 'status', w.cur_status) order by w.first_event_at, w.seq)
                  from (select distinct on (card_id) * from cand where kind in ('turn', 'alert') order by card_id, created_at desc, seq desc) w), '[]'::jsonb),
      coalesce((select jsonb_agg(jsonb_build_object('key', b.card_prefix || '-' || m.num, 'title', m.title,
                  'actor', m.actor, 'from', m.from_s, 'to', m.to_s) order by m.last_at)
                  from (select card_id, num, title,
                               (array_agg(payload ->> 'from' order by created_at, seq))[1] as from_s,
                               (array_agg(payload ->> 'to' order by created_at desc, seq desc))[1] as to_s,
                               (array_agg(payload ->> 'actor' order by created_at desc, seq desc))[1] as actor,
                               max(created_at) as last_at
                          from cand where kind = 'update' and reason = 'moved'
                         group by card_id, num, title
                        having (array_agg(payload ->> 'from' order by created_at, seq))[1]
                               is distinct from (array_agg(payload ->> 'to' order by created_at desc, seq desc))[1]) m), '[]'::jsonb),
      (select array_agg(id) from cand)
    into waiting, moved, ids;

    -- Standing problems (blocked, overdue) are listed once every three days, not every morning
    if p.role = 'pm' and first_slot then
      select coalesce(jsonb_agg(x.j order by x.num), '[]'::jsonb) into blocked
        from (select jsonb_build_object('id', c.id, 'key', b.card_prefix || '-' || c.num, 'title', c.title,
                       'assignee', (select name from public.people where id = c.assignee_id)) as j, c.num
                from public.cards c
               where c.blocked and c.status <> 'done' and c.archived_at is null
                 and not exists (
                   select 1 from private.notify_queue a
                    where a.recipient_id = p.id and a.card_id = c.id and a.kind = 'alert'
                      and a.status in ('sending', 'sent') and a.created_at > now_ts - interval '24 hours')
                 and not exists (
                   select 1 from private.digest_mentions m
                    where m.person_id = p.id and m.card_id = c.id and m.kind = 'blocked' and m.last_at > now_ts - interval '3 days')
               order by c.num limit 8) x;
      select coalesce(jsonb_agg(x.j order by x.due, x.num), '[]'::jsonb) into due
        from (select jsonb_build_object('id', c.id, 'key', b.card_prefix || '-' || c.num, 'title', c.title, 'due', c.due) as j, c.due, c.num
                from public.cards c
               where c.due is not null and c.due <= today + 1 and c.status not in ('done', 'backlog') and c.archived_at is null
                 and not exists (
                   select 1 from private.digest_mentions m
                    where m.person_id = p.id and m.card_id = c.id and m.kind = 'due' and m.last_at > now_ts - interval '3 days')
               order by c.due, c.num limit 8) x;
    end if;

    if jsonb_array_length(waiting) + jsonb_array_length(moved) + jsonb_array_length(blocked) + jsonb_array_length(due) = 0 then
      if ids is not null then
        update private.notify_queue set status = 'digested', finished_at = now_ts where id = any (ids);
      end if;
      continue;
    end if;

    select count(*) into sent_team from private.email_log
     where status in ('sending', 'sent') and created_at >= date_trunc('day', now_ts at time zone 'UTC') at time zone 'UTC';
    if sent_team >= s.daily_cap then
      -- Leave the items pending. A later digest picks them up.
      delete from private.digest_slots where person_id = p.id and slot = v_slot;
      continue;
    end if;

    select count(*) into fails from private.email_log
     where recipient_id = p.id and kind = 'digest' and slot = v_slot and status = 'failed';
    rendered := private.render_digest(p, waiting, moved, blocked, due, s, b);
    log_id := gen_random_uuid();
    begin
      rid := private.send_email(p.email, p.name, rendered ->> 'subject', rendered ->> 'html', rendered ->> 'text',
                                'nudge-digest-' || md5(p.id::text || v_slot || fails::text));
      insert into private.email_log (id, recipient_id, to_email, kind, slot, subject, provider, request_id, status, detail, created_at, finished_at)
      values (log_id, p.id, p.email, 'digest', v_slot, rendered ->> 'subject', s.provider, rid,
              case when rid is null then 'sent' else 'sending' end,
              case when rid is null then (case s.provider when 'claude' then 'Waiting for Claude to send it' else 'Logged only (provider is set to log)' end) end, now_ts,
              case when rid is null then now_ts end);
      if ids is not null then
        update private.notify_queue
           set status = case when rid is null then 'sent' else 'sending' end, email_id = log_id,
               finished_at = case when rid is null then now_ts end
         where id = any (ids);
      end if;
      insert into private.digest_mentions (person_id, card_id, kind, last_at)
        select p.id, (e ->> 'id')::uuid, 'blocked', now_ts from jsonb_array_elements(blocked) e
        on conflict (person_id, card_id, kind) do update set last_at = excluded.last_at;
      insert into private.digest_mentions (person_id, card_id, kind, last_at)
        select p.id, (e ->> 'id')::uuid, 'due', now_ts from jsonb_array_elements(due) e
        on conflict (person_id, card_id, kind) do update set last_at = excluded.last_at;
    exception when others then
      insert into private.email_log (id, recipient_id, to_email, kind, slot, subject, provider, status, detail, created_at, finished_at)
      values (log_id, p.id, p.email, 'digest', v_slot, rendered ->> 'subject', s.provider, 'failed', left(sqlerrm, 400), now_ts, now_ts);
      perform private.release_digest_slot(log_id);
    end;
  end loop;
end $$;

create or replace function private.housekeeping(now_ts timestamptz) returns void
language plpgsql security definer set search_path = '' as $$
declare
  day text := to_char(now_ts at time zone 'UTC', 'YYYY-MM-DD');
begin
  -- Digest items older than five days are stale news
  update private.notify_queue set status = 'digested', finished_at = now_ts
   where status = 'pending' and delivery = 'digest' and created_at < now_ts - interval '120 hours';
  -- Claude's outbox: late news is noise, and a pick-up with no answer is not retried (it may have gone out)
  update private.outbox set status = 'failed', finished_at = now_ts, detail = 'Claude did not pick it up within a day'
   where status = 'pending' and created_at < now_ts - interval '24 hours';
  update private.outbox set status = 'failed', finished_at = now_ts, detail = 'Claude picked it up but did not say it was sent'
   where status = 'taken' and taken_at < now_ts - interval '2 hours';
  -- Once a day: clean up
  if coalesce((select value from private.kv where key = 'housekeeping_day'), '') <> day then
    delete from private.notify_queue where status in ('sent', 'cancelled', 'digested', 'failed') and coalesce(finished_at, created_at) < now_ts - interval '30 days';
    delete from private.email_log where created_at < now_ts - interval '30 days';
    delete from private.outbox where status in ('sent', 'failed') and coalesce(finished_at, created_at) < now_ts - interval '30 days';
    delete from private.digest_slots where done_at < now_ts - interval '7 days';
    delete from private.digest_mentions where last_at < now_ts - interval '14 days';
    delete from public.notifications where created_at < now_ts - interval '60 days';
    delete from public.card_events where at < now_ts - interval '90 days';
    insert into private.kv (key, value) values ('housekeeping_day', day)
      on conflict (key) do update set value = excluded.value;
  end if;
end $$;

-- The one function cron calls, every minute.
create or replace function private.run_notifications() returns void
language plpgsql security definer set search_path = '' as $$
declare
  s public.notify_settings;
  now_ts timestamptz := private.now_utc();
  prev_sys text := coalesce(current_setting('nb.system', true), '');
begin
  if not pg_try_advisory_xact_lock(hashtext('nudge.notifications')) then
    return;
  end if;
  perform set_config('nb.system', '1', true);
  select * into s from public.notify_settings where id = 1;
  perform private.reconcile_emails(now_ts);
  if s.emails_enabled then
    perform private.process_instant(s, now_ts);
    perform private.process_digests(s, now_ts);
  else
    -- Kill switch: do not let stale pings pile up while email is off
    update private.notify_queue set status = 'cancelled', finished_at = now_ts
     where status = 'pending' and delivery = 'instant' and send_after <= now_ts;
  end if;
  perform private.housekeeping(now_ts);
  perform set_config('nb.system', prev_sys, true);
end $$;

-- ---------------------------------------------------------------------
-- Cycles roll over once, on the server
-- ---------------------------------------------------------------------

create or replace function private.roll_cycle(p_force boolean default false) returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  b public.board;
  today date;
  elapsed int;
  k int;
  newstart date;
  n_done int;
  n_open int;
  prev_sys text := coalesce(current_setting('nb.system', true), '');
begin
  perform pg_advisory_xact_lock(hashtext('nudge.roll'));
  select * into b from public.board where id = 1 for update;
  today := (private.now_utc() at time zone b.timezone)::date;
  elapsed := today - b.cycle_start;
  if not p_force and elapsed < b.cycle_days then return false; end if;
  -- "Start the next cycle now" twice in a row (or on day one) does nothing the second time
  if p_force and b.cycle_start >= today then return false; end if;
  k := case when p_force then 1 else greatest(1, floor(elapsed::numeric / b.cycle_days)::int) end;
  newstart := case when p_force then today else b.cycle_start + k * b.cycle_days end;

  select count(*) into n_done from public.cards where status = 'done' and archived_at is null;
  select count(*) into n_open from public.cards where status in ('todo', 'doing', 'review', 'security') and archived_at is null;
  insert into public.cycle_history (n, start_date, end_date, done, total, goals)
  values (b.cycle_n, b.cycle_start, least(b.cycle_start + b.cycle_days - 1, newstart - 1), n_done, n_done + n_open, b.cycle_goals)
  on conflict (n) do nothing;
  delete from public.cycle_history where n <= b.cycle_n - 12;

  perform set_config('nb.system', '1', true);
  update public.cards set archived_at = now() where status = 'done' and archived_at is null;
  update public.cards set rolled = rolled + 1, unplanned = false where status in ('todo', 'doing', 'review', 'security') and archived_at is null;
  -- A new cycle starts with its own goals: the old ones are kept with the cycle they belonged to
  update public.board set cycle_n = b.cycle_n + k, cycle_start = newstart, cycle_goals = '', updated_at = now() where id = 1;
  perform set_config('nb.system', prev_sys, true);
  return true;
end $$;

-- ---------------------------------------------------------------------
-- Functions the app calls (public schema, signed-in users only)
-- ---------------------------------------------------------------------

create or replace function public.whoami() returns jsonb
language sql stable security definer set search_path = '' as $$
  select to_jsonb(x) from (
    select p.id, p.name, p.email, p.role, p.timezone, p.notify_mode, p.pm_instant, p.muted_until, p.away_until, p.security
      from public.people p where p.id = private.me()
  ) x
$$;

create or replace function public.roll_cycle_if_due() returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_member() then raise exception 'Not on the team' using errcode = '42501'; end if;
  return private.roll_cycle(false);
end $$;

create or replace function public.roll_cycle_now() returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_pm() then raise exception 'Only the project manager can do this' using errcode = '42501'; end if;
  return private.roll_cycle(true);
end $$;

create or replace function public.update_my_prefs(
  p_notify_mode text default null, p_timezone text default null, p_pause text default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  me uuid := private.me();
  per public.people;
begin
  if me is null then raise exception 'Not on the team' using errcode = '42501'; end if;
  select * into per from public.people where id = me;
  if p_notify_mode is not null and p_notify_mode not in ('normal', 'calm', 'off') then
    raise exception 'Unknown notification setting' using errcode = '22023';
  end if;
  if p_timezone is not null and not private.valid_tz(p_timezone) then
    raise exception 'Unknown time zone' using errcode = '22023';
  end if;
  update public.people set
    notify_mode = coalesce(p_notify_mode, notify_mode),
    timezone = coalesce(p_timezone, timezone),
    muted_until = case p_pause
      when 'monday' then private.next_monday_start(private.now_utc(), coalesce(p_timezone, per.timezone))
      when 'clear' then null
      else muted_until end
   where id = me;
  return public.whoami();
end $$;

-- Used by the "pause / digest / off" links at the bottom of every email.
-- No sign-in needed: the long random token in the link is the key.
create or replace function public.mute_by_token(p_token uuid, p_mode text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  per public.people;
  prev_sys text := coalesce(current_setting('nb.system', true), '');
begin
  if p_mode not in ('pause', 'calm', 'off') then
    return jsonb_build_object('ok', false);
  end if;
  select * into per from public.people where mute_token = p_token and active;
  if not found then return jsonb_build_object('ok', false); end if;
  perform set_config('nb.system', '1', true);
  if p_mode = 'pause' then
    update public.people set muted_until = private.next_monday_start(private.now_utc(), timezone) where id = per.id;
  elsif p_mode = 'calm' then
    update public.people set notify_mode = 'calm', muted_until = null where id = per.id;
  else
    update public.people set notify_mode = 'off' where id = per.id;
  end if;
  perform set_config('nb.system', prev_sys, true);
  return jsonb_build_object('ok', true, 'name', split_part(per.name, ' ', 1), 'mode', p_mode);
end $$;

create or replace function public.email_status() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s public.notify_settings;
  sent_today int;
  last_row private.email_log;
  has_key boolean;
  waiting int;
begin
  if not private.is_pm() then raise exception 'Only the project manager can do this' using errcode = '42501'; end if;
  select * into s from public.notify_settings where id = 1;
  select count(*) into waiting from private.outbox where status in ('pending', 'taken');
  select count(*) into sent_today from private.email_log
   where status in ('sending', 'sent') and created_at >= date_trunc('day', private.now_utc() at time zone 'UTC') at time zone 'UTC';
  select * into last_row from private.email_log order by created_at desc limit 1;
  begin
    select exists (select 1 from vault.decrypted_secrets where name = 'email_api_key') into has_key;
  exception when others then has_key := false;
  end;
  return jsonb_build_object(
    'enabled', s.emails_enabled, 'provider', s.provider, 'has_key', has_key,
    'sent_today', sent_today, 'daily_cap', s.daily_cap,
    'last_status', last_row.status, 'last_detail', last_row.detail, 'last_at', last_row.created_at,
    'last_kind', last_row.kind, 'last_to', last_row.to_email,
    'claude_key', (select value from private.kv where key = 'claude_key'),
    'claude_seen_at', (select value from private.kv where key = 'claude_seen_at'),
    'outbox_waiting', waiting);
end $$;

create or replace function public.send_test_email() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  per public.people;
  s public.notify_settings;
  b public.board;
  rid bigint;
  log_id uuid := gen_random_uuid();
  html text;
  now_ts timestamptz := private.now_utc();
begin
  if not private.is_pm() then raise exception 'Only the project manager can do this' using errcode = '42501'; end if;
  select * into per from public.people where id = private.me();
  select * into s from public.notify_settings where id = 1;
  select * into b from public.board where id = 1;
  html := private.email_shell(per, s, b,
    '<p style="margin:0">This is a test from Nudge Board. If you can read it, email is set up and your team will get calm, short updates.</p>',
    'Open the board', regexp_replace(s.app_url, '#.*$', ''));
  begin
    rid := private.send_email(per.email, per.name, 'Test from Nudge Board', html,
      'This is a test from Nudge Board. If you can read it, email is set up.', 'nudge-test-' || log_id::text);
    insert into private.email_log (id, recipient_id, to_email, kind, subject, provider, request_id, status, detail, created_at, finished_at)
    values (log_id, per.id, per.email, 'test', 'Test from Nudge Board', s.provider, rid,
            case when rid is null then 'sent' else 'sending' end,
            case when rid is null then (case s.provider when 'claude' then 'Waiting for Claude to send it' else 'Logged only (provider is set to log)' end) end, now_ts,
            case when rid is null then now_ts end);
    return jsonb_build_object('ok', true, 'message',
      case when rid is null and s.provider = 'claude' then 'Test email is waiting for Claude. It goes out on the Claude task''s next run (every 2 hours). To send it now: in the Claude app, open Scheduled and run "Nudge Board: send waiting emails".'
           when rid is null then 'Provider is set to log, so nothing was sent.' else 'Test email sent. It should arrive within a minute.' end);
  exception when others then
    insert into private.email_log (id, recipient_id, to_email, kind, subject, provider, status, detail, created_at, finished_at)
    values (log_id, per.id, per.email, 'test', 'Test from Nudge Board', s.provider, 'failed', left(sqlerrm, 400), now_ts, now_ts);
    return jsonb_build_object('ok', false, 'message', sqlerrm);
  end;
end $$;

-- Run once, from the SQL editor, to create the first project manager.
create or replace function private.bootstrap(
  p_name text, p_email text, p_board_name text default 'My board',
  p_prefix text default 'TSK', p_tz text default 'UTC'
) returns text
language plpgsql security definer set search_path = '' as $$
declare
  prev_sys text := coalesce(current_setting('nb.system', true), '');
begin
  if exists (select 1 from public.people) then
    raise exception 'This board already has people, so it was left alone. If you mistyped your email, run: update public.people set email = ''right@address.com'' where role = ''pm'';';
  end if;
  perform set_config('nb.system', '1', true);
  insert into public.people (name, email, role, timezone) values (p_name, p_email, 'pm', p_tz);
  update public.board set name = p_board_name, card_prefix = upper(p_prefix), timezone = p_tz,
    cycle_start = (private.now_utc() at time zone p_tz)::date, updated_at = now() where id = 1;
  perform set_config('nb.system', prev_sys, true);
  return 'Done. ' || p_email || ' is now the project manager. Your join code is '
    || (select substr(private.clean_code(join_code), 1, 4) || '-' || substr(private.clean_code(join_code), 5) from public.people where email = lower(trim(p_email)))
    || '. Open the board, choose "First time here", and use it to set your password.';
end $$;

-- ---------------------------------------------------------------------
-- Password sign-in with a join code (no email needed)
--
-- The PM adds a person and shares their join code. On the board the person enters
-- email + code + a new password:
--   1. start_join checks the code and clears any old sign-in account for that email
--      (a forgotten password, or someone who registered the email before them).
--   2. the app creates the password account (Supabase sign-up, "Confirm email" off).
--   3. finish_join, signed in with that account, checks the code again and links it.
-- Ten wrong codes lock that code until the PM makes a new one.
-- ---------------------------------------------------------------------

create or replace function private.check_join_code(per public.people, p_code text) returns text
language plpgsql security definer set search_path = '' as $$
declare
  prev_sys text := coalesce(current_setting('nb.system', true), '');
begin
  if per.id is null or per.join_code is null then return 'code'; end if;
  if per.join_tries >= 10 then return 'locked'; end if;
  -- Both sides tidied: dashes, spaces and case never matter
  if private.clean_code(p_code) = private.clean_code(per.join_code) then return 'ok'; end if;
  perform set_config('nb.system', '1', true);
  update public.people set join_tries = join_tries + 1 where id = per.id;
  perform set_config('nb.system', prev_sys, true);
  return 'code';
end $$;

create or replace function public.start_join(p_email text, p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  per public.people;
  r text;
begin
  perform pg_advisory_xact_lock(hashtext('nudge.join'));
  select * into per from public.people where email = lower(trim(coalesce(p_email, ''))) and active;
  r := private.check_join_code(per, p_code);
  if r <> 'ok' then return jsonb_build_object('ok', false, 'reason', r); end if;
  begin
    delete from auth.users where lower(email) = per.email;
  exception when insufficient_privilege then
    return jsonb_build_object('ok', false, 'reason', 'server',
      'message', 'The database could not reset the old sign-in for this email. Ask your project manager to delete it in Supabase (Authentication > Users).');
  end;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.finish_join(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  per public.people;
  r text;
  prev_sys text := coalesce(current_setting('nb.system', true), '');
begin
  if uid is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtext('nudge.join'));
  select p.* into per from public.people p join auth.users u on lower(u.email) = p.email
   where u.id = uid and p.active;
  r := private.check_join_code(per, p_code);
  if r <> 'ok' then return jsonb_build_object('ok', false, 'reason', r); end if;
  perform set_config('nb.system', '1', true);
  update public.people set user_id = null where user_id = uid;
  update public.people set user_id = uid, join_code = null, join_tries = 0 where id = per.id;
  perform set_config('nb.system', prev_sys, true);
  return jsonb_build_object('ok', true);
end $$;

-- PM: a fresh code for someone who forgot their password (or whose account should be cut off).
-- Their current password stops working for the board straight away.
create or replace function public.reset_join_code(p_person uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare
  code text;
  prev_sys text := coalesce(current_setting('nb.system', true), '');
begin
  if not private.is_pm() then raise exception 'Only the project manager can do this' using errcode = '42501'; end if;
  perform set_config('nb.system', '1', true);
  update public.people set user_id = null, join_code = private.new_code(), join_tries = 0
   where id = p_person returning join_code into code;
  perform set_config('nb.system', prev_sys, true);
  if code is null then raise exception 'That person is not on the team' using errcode = '22023'; end if;
  return code;
end $$;

-- ---------------------------------------------------------------------
-- Who's away: anyone can say they are away until a date (or clear it)
-- ---------------------------------------------------------------------

create or replace function public.set_my_away(p_until date) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  me uuid := private.me();
  today date;
begin
  if me is null then raise exception 'Not on the team' using errcode = '42501'; end if;
  select (private.now_utc() at time zone timezone)::date into today from public.people where id = me;
  if p_until is not null and (p_until < today or p_until > today + 365) then
    raise exception 'Pick a date from today up to a year ahead' using errcode = '22023';
  end if;
  update public.people set away_until = p_until where id = me;
  return public.whoami();
end $$;

-- ---------------------------------------------------------------------
-- GitHub: the workflow in your code repository sends commit messages, branch names and pull
-- request titles here. Cards mentioned in them move forward on their own (never backwards):
--   a merged pull request                                        -> QA Test
--   any other mention: a push, a branch chk-12-..., "Fixes CHK-12",
--   or an opened pull request                                    -> Doing
-- People move cards on from QA Test (to Security, then Done) themselves.
-- ---------------------------------------------------------------------

create or replace function public.github_sync(p_key text, p_events jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  rank constant jsonb := '{"backlog": 0, "todo": 1, "doing": 2, "review": 3, "security": 4, "done": 5}';
  prefix text := (select card_prefix from public.board where id = 1);
  ev jsonb;
  kind text;
  txt text;
  hit text[];
  card_num int;
  target text;
  c public.cards;
  moved jsonb := '[]';
  prev_sys text := coalesce(current_setting('nb.system', true), '');
  prev_actor text := coalesce(current_setting('nb.actor_name', true), '');
begin
  if coalesce(p_key, '') = '' or p_key is distinct from (select value from private.kv where key = 'github_key') then
    raise exception 'Wrong GitHub key' using errcode = '42501';
  end if;
  if jsonb_typeof(p_events) is distinct from 'array' or jsonb_array_length(p_events) > 200 then
    raise exception 'Send a list of at most 200 events' using errcode = '22023';
  end if;
  insert into private.kv (key, value) values ('github_seen_at', private.now_utc()::text)
    on conflict (key) do update set value = excluded.value;

  for ev in select * from jsonb_array_elements(p_events) loop
    kind := coalesce(ev ->> 'kind', 'commit');
    continue when kind = 'pr_closed';            -- closed without merging: nothing to do
    txt := left(coalesce(ev ->> 'text', ''), 5000);
    for hit in select regexp_matches(txt, '(^|[^A-Za-z0-9])' || prefix || '[-_ ]?([0-9]+)', 'gi') loop
      card_num := hit[2]::int;
      target := case when kind = 'pr_merged' then 'review' else 'doing' end;
      select * into c from public.cards where num = card_num and archived_at is null;
      continue when not found or (rank ->> target)::int <= (rank ->> c.status)::int;
      perform set_config('nb.system', '1', true);
      perform set_config('nb.actor_name', left(coalesce(nullif(ev ->> 'actor', ''), 'GitHub'), 60) || ' (GitHub)', true);
      update public.cards set status = target where id = c.id;
      perform set_config('nb.system', prev_sys, true);
      perform set_config('nb.actor_name', prev_actor, true);
      moved := moved || jsonb_build_object('key', prefix || '-' || card_num, 'from', c.status, 'to', target);
    end loop;
  end loop;
  return jsonb_build_object('moved', moved);
end $$;

-- ---------------------------------------------------------------------
-- Cycle summary email: a PM sends a cycle's summary to anyone (a founder, investors, the team)
-- from their own Gmail. Built here from the board's own data; the app pastes it into Gmail.
-- ---------------------------------------------------------------------

-- The summary of cycle p_n (null = the current one): {subject, html, text, n}. p_note goes at the top.
create or replace function private.cycle_report(p_n int, p_note text, p_from text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  b public.board;
  h public.cycle_history;
  s public.notify_settings;
  cur boolean;
  d_from date; d_to date;
  goals text[];
  shipped jsonb; going jsonb;
  n_open int := 0; n_unplanned int; n_carried int := 0;
  base text;
  head text; body text := ''; txt text := '';
  it jsonb;
  green constant text := '#0f766e';
  grey constant text := '#6b7280';
begin
  select * into b from public.board where id = 1;
  select * into s from public.notify_settings where id = 1;
  base := regexp_replace(coalesce(s.app_url, ''), '#.*$', '');
  cur := p_n is null or p_n = b.cycle_n;
  if cur then
    d_from := b.cycle_start; d_to := b.cycle_start + b.cycle_days - 1;
    goals := array(select trim(g) from unnest(string_to_array(b.cycle_goals, E'\n')) g where trim(g) <> '');
  else
    select * into h from public.cycle_history where n = p_n;
    if not found then raise exception 'Cycle % is no longer kept (the board keeps the last 12)', p_n using errcode = '22023'; end if;
    d_from := h.start_date; d_to := h.end_date;
    goals := array(select trim(g) from unnest(string_to_array(h.goals, E'\n')) g where trim(g) <> '');
  end if;

  -- What shipped: done this cycle (the current one), or finished between its dates (a past one)
  select coalesce(jsonb_agg(jsonb_build_object('key', b.card_prefix || '-' || c.num, 'title', c.title, 'tags', c.tags,
           'owner', (select name from public.people where id = c.assignee_id), 'unplanned', c.unplanned) order by c.done_at), '[]')
    into shipped
    from public.cards c
   where c.status = 'done'
     and (case when cur then c.archived_at is null
               else c.done_at >= (d_from::timestamp at time zone b.timezone) and c.done_at < ((d_to + 1)::timestamp at time zone b.timezone) end);
  n_unplanned := (select count(*) from jsonb_array_elements(shipped) e where (e ->> 'unplanned')::boolean);
  if cur then
    select coalesce(jsonb_agg(jsonb_build_object('key', b.card_prefix || '-' || c.num, 'title', c.title, 'status', private.status_name(c.status),
             'owner', (select name from public.people where id = c.assignee_id)) order by c.status desc, c.num), '[]')
      into going
      from public.cards c where c.status in ('doing', 'review', 'security') and c.archived_at is null;
    select count(*) into n_open from public.cards where status in ('todo', 'doing', 'review', 'security') and archived_at is null;
    select count(*) into n_carried from public.cards where status in ('todo', 'doing', 'review', 'security') and archived_at is null and rolled > 0;
    n_unplanned := n_unplanned + (select count(*) from public.cards where status in ('todo', 'doing', 'review', 'security') and archived_at is null and unplanned);
  else
    going := '[]';
    n_open := greatest(h.total - h.done, 0);
  end if;

  head := b.name || ' · Cycle ' || coalesce(p_n, b.cycle_n) || ' summary: ' || jsonb_array_length(shipped) || ' shipped';

  -- the email
  if coalesce(trim(p_note), '') <> '' then
    body := body || '<p style="margin:0 0 20px;padding:12px 14px;background:#f3f4f6;border-radius:8px;white-space:pre-line">' || private.h(trim(p_note)) || '</p>';
    txt := txt || trim(p_note) || E'\n\n';
  end if;
  body := body
    || '<p style="margin:0;font-size:12px;letter-spacing:.06em;text-transform:uppercase;color:' || grey || '">' || private.h(b.name) || '</p>'
    || '<h1 style="margin:4px 0 2px;font-size:22px;line-height:1.3">Cycle ' || coalesce(p_n, b.cycle_n) || ' summary</h1>'
    || '<p style="margin:0 0 18px;color:' || grey || '">' || to_char(d_from, 'Mon FMDD') || ' to ' || to_char(d_to, 'Mon FMDD') || case when cur then ', so far' else '' end || '</p>'
    || '<table role="presentation" cellspacing="0" cellpadding="0" style="width:100%;border-collapse:separate;border-spacing:6px 0;margin:0 0 20px"><tr>'
    || format('<td style="padding:12px;background:#ecfdf5;border-radius:10px;text-align:center"><div style="font-size:24px;font-weight:700;color:%s">%s</div><div style="font-size:12px;color:%s">shipped</div></td>', green, jsonb_array_length(shipped), grey)
    || format('<td style="padding:12px;background:#fef3c7;border-radius:10px;text-align:center"><div style="font-size:24px;font-weight:700;color:#b45309">%s</div><div style="font-size:12px;color:%s">unplanned</div></td>', n_unplanned, grey)
    || format('<td style="padding:12px;background:#f3f4f6;border-radius:10px;text-align:center"><div style="font-size:24px;font-weight:700">%s</div><div style="font-size:12px;color:%s">%s</div></td>', n_open, grey, case when cur then 'still open' else 'carried over' end)
    || '</tr></table>';
  txt := txt || 'Cycle ' || coalesce(p_n, b.cycle_n) || ' summary, ' || b.name || E'\n'
    || to_char(d_from, 'Mon FMDD') || ' to ' || to_char(d_to, 'Mon FMDD') || case when cur then ', so far' else '' end || E'\n\n'
    || jsonb_array_length(shipped) || ' shipped, ' || n_unplanned || ' unplanned, ' || n_open || case when cur then ' still open' else ' carried over' end || E'\n';

  if cardinality(goals) > 0 then
    body := body || '<h2 style="margin:0 0 6px;font-size:15px">Goals</h2><ul style="margin:0 0 18px;padding-left:20px">'
      || (select string_agg('<li>' || private.h(g) || '</li>', '') from unnest(goals) g) || '</ul>';
    txt := txt || E'\nGoals\n' || (select string_agg('- ' || g, E'\n') from unnest(goals) g) || E'\n';
  end if;

  body := body || '<h2 style="margin:0 0 6px;font-size:15px">What shipped</h2>';
  txt := txt || E'\nWhat shipped\n';
  if jsonb_array_length(shipped) = 0 then
    body := body || '<p style="margin:0 0 18px;color:' || grey || '">Nothing finished ' || case when cur then 'yet.' else 'in this cycle.' end || '</p>';
    txt := txt || 'Nothing finished ' || case when cur then 'yet.' else 'in this cycle.' end || E'\n';
  else
    body := body || '<ul style="margin:0 0 18px;padding-left:20px">';
    for it in select * from jsonb_array_elements(shipped) loop
      body := body || '<li style="margin:0 0 4px"><b>' || private.h(it ->> 'key') || '</b> ' || private.h(it ->> 'title')
        || '<span style="color:' || grey || '">'
        || coalesce(' · ' || private.h(it ->> 'owner'), '')
        || coalesce(' · ' || (select string_agg('#' || private.h(t), ' ') from jsonb_array_elements_text(it -> 'tags') t), '')
        || '</span>' || case when (it ->> 'unplanned')::boolean then ' <span style="color:#b45309">(unplanned)</span>' else '' end || '</li>';
      txt := txt || '- ' || (it ->> 'key') || ' ' || (it ->> 'title') || coalesce(' (' || (it ->> 'owner') || ')', '')
        || case when (it ->> 'unplanned')::boolean then ' [unplanned]' else '' end || E'\n';
    end loop;
    body := body || '</ul>';
  end if;

  if jsonb_array_length(going) > 0 then
    body := body || '<h2 style="margin:0 0 6px;font-size:15px">In progress</h2><ul style="margin:0 0 18px;padding-left:20px">';
    txt := txt || E'\nIn progress\n';
    for it in select * from jsonb_array_elements(going) loop
      body := body || '<li style="margin:0 0 4px"><b>' || private.h(it ->> 'key') || '</b> ' || private.h(it ->> 'title')
        || '<span style="color:' || grey || '"> · ' || private.h(it ->> 'status') || coalesce(' · ' || private.h(it ->> 'owner'), '') || '</span></li>';
      txt := txt || '- ' || (it ->> 'key') || ' ' || (it ->> 'title') || ' (' || (it ->> 'status') || coalesce(', ' || (it ->> 'owner'), '') || E')\n';
    end loop;
    body := body || '</ul>';
  end if;

  if base <> '' then
    body := body || format('<p style="margin:20px 0 4px"><a href="%s" style="background:%s;color:#ffffff;text-decoration:none;padding:10px 16px;border-radius:8px;font-weight:600;display:inline-block">Open the board</a></p>', private.h(base), green);
    txt := txt || E'\nOpen the board: ' || base || E'\n';
  end if;
  body := '<div style="font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;font-size:15px;line-height:1.5;color:#111827;max-width:600px;margin:0 auto;padding:16px">'
    || body || '<p style="margin:24px 0 0;font-size:12px;color:' || grey || '">Sent by ' || private.h(coalesce(p_from, 'the project manager')) || ' from Nudge Board.</p></div>';
  txt := txt || E'\nSent by ' || coalesce(p_from, 'the project manager') || ' from Nudge Board.';
  return jsonb_build_object('subject', head, 'html', body, 'text', txt, 'n', coalesce(p_n, b.cycle_n));
end $$;

-- PM: what the summary of a cycle looks like before sending it
create or replace function public.cycle_report_preview(p_n int default null, p_note text default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_pm() then raise exception 'Only the project manager can do this' using errcode = '42501'; end if;
  return private.cycle_report(p_n, left(p_note, 1000), (select name from public.people where id = private.me()));
end $$;

-- An earlier draft sent the summary from the database; it now goes from the PM's own Gmail
drop function if exists public.send_cycle_report(int, text[], text);

-- PM: the GitHub key and when GitHub last reported in
create or replace function public.github_status() returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_pm() then raise exception 'Only the project manager can do this' using errcode = '42501'; end if;
  return jsonb_build_object(
    'github_key', (select value from private.kv where key = 'github_key'),
    'github_seen_at', (select value from private.kv where key = 'github_seen_at'));
end $$;

-- ---------------------------------------------------------------------
-- Claude's outbox. The Claude task calls these with the Claude key (shown to the PM in
-- Team > Email). No sign-in: the key is the password, and it only reaches the outbox.
-- ---------------------------------------------------------------------

create or replace function private.claude_key_ok(p_key text) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(p_key, '') <> '' and p_key = (select value from private.kv where key = 'claude_key')
$$;

-- Hands over up to p_limit emails. Each is given out once; report back with claude_outbox_done.
create or replace function public.claude_outbox_take(p_key text, p_limit int default 20) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  now_ts timestamptz := private.now_utc();
  items jsonb;
begin
  if not private.claude_key_ok(p_key) then raise exception 'Wrong Claude key' using errcode = '42501'; end if;
  insert into private.kv (key, value) values ('claude_seen_at', now_ts::text)
    on conflict (key) do update set value = excluded.value;
  with picked as (
    select id from private.outbox where status = 'pending'
     order by created_at limit greatest(1, least(coalesce(p_limit, 20), 50)) for update skip locked
  ), upd as (
    update private.outbox o set status = 'taken', taken_at = now_ts
      from picked where o.id = picked.id
    returning o.id, o.to_email, o.to_name, o.subject, o.body_text, o.html, o.created_at
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'to', to_email, 'name', to_name, 'subject', subject,
                                               'text', body_text, 'html', html) order by created_at), '[]'::jsonb)
    into items from upd;
  return items;
end $$;

create or replace function public.claude_outbox_done(p_key text, p_id uuid, p_ok boolean, p_detail text default null) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  if not private.claude_key_ok(p_key) then raise exception 'Wrong Claude key' using errcode = '42501'; end if;
  update private.outbox
     set status = case when p_ok then 'sent' else 'failed' end, finished_at = private.now_utc(),
         detail = left(coalesce(p_detail, case when p_ok then 'Sent by Claude' else 'Claude could not send it' end), 400)
   where id = p_id and status = 'taken';
  return found;
end $$;

-- ---------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------

alter table public.board enable row level security;
alter table public.people enable row level security;
alter table public.cards enable row level security;
alter table public.card_events enable row level security;
alter table public.cycle_history enable row level security;
alter table public.notifications enable row level security;
alter table public.notify_settings enable row level security;
alter table private.notify_queue enable row level security;
alter table private.email_log enable row level security;
alter table private.digest_slots enable row level security;
alter table private.kv enable row level security;
alter table private.digest_mentions enable row level security;

drop policy if exists board_select on public.board;
create policy board_select on public.board for select to authenticated using ((select private.is_member()));
drop policy if exists board_update on public.board;
create policy board_update on public.board for update to authenticated
  using ((select private.is_pm())) with check ((select private.is_pm()));

drop policy if exists people_select on public.people;
create policy people_select on public.people for select to authenticated
  using ((select private.is_pm()) or id = (select private.me()));
drop policy if exists people_insert on public.people;
create policy people_insert on public.people for insert to authenticated with check ((select private.is_pm()));
drop policy if exists people_update on public.people;
create policy people_update on public.people for update to authenticated
  using ((select private.is_pm())) with check ((select private.is_pm()));
drop policy if exists people_delete on public.people;
create policy people_delete on public.people for delete to authenticated using ((select private.is_pm()));

drop policy if exists cards_select on public.cards;
create policy cards_select on public.cards for select to authenticated using ((select private.is_member()));
drop policy if exists cards_insert on public.cards;
create policy cards_insert on public.cards for insert to authenticated with check ((select private.is_member()));
drop policy if exists cards_update on public.cards;
create policy cards_update on public.cards for update to authenticated
  using ((select private.is_member())) with check ((select private.is_member()));
drop policy if exists cards_delete on public.cards;
create policy cards_delete on public.cards for delete to authenticated
  using ((select private.is_pm()) or created_by = (select private.me()));

drop policy if exists events_select on public.card_events;
create policy events_select on public.card_events for select to authenticated using ((select private.is_member()));
alter table public.card_comments enable row level security;
drop policy if exists comments_select on public.card_comments;
create policy comments_select on public.card_comments for select to authenticated using ((select private.is_member()));
drop policy if exists comments_insert on public.card_comments;
create policy comments_insert on public.card_comments for insert to authenticated with check ((select private.is_member()));
drop policy if exists comments_delete on public.card_comments;
create policy comments_delete on public.card_comments for delete to authenticated
  using ((select private.is_pm()) or author_id = (select private.me()));

drop policy if exists history_select on public.cycle_history;
create policy history_select on public.cycle_history for select to authenticated using ((select private.is_member()));

drop policy if exists notifications_select on public.notifications;
create policy notifications_select on public.notifications for select to authenticated
  using (recipient_id = (select private.me()));
drop policy if exists notifications_update on public.notifications;
create policy notifications_update on public.notifications for update to authenticated
  using (recipient_id = (select private.me())) with check (recipient_id = (select private.me()));

drop policy if exists settings_select on public.notify_settings;
create policy settings_select on public.notify_settings for select to authenticated using ((select private.is_pm()));
drop policy if exists settings_update on public.notify_settings;
create policy settings_update on public.notify_settings for update to authenticated
  using ((select private.is_pm())) with check ((select private.is_pm()));

-- What teammates may see about each other: names, never emails.
drop view if exists public.team;
create view public.team with (security_invoker = false) as
  select id, name, role, timezone, active, away_until, security
    from public.people
   where (select private.is_member());

-- ---------------------------------------------------------------------
-- Privileges: start from nothing, grant only what the app needs
-- ---------------------------------------------------------------------

revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;
revoke all on all tables in schema private from public, anon, authenticated;
revoke all on all functions in schema private from public, anon, authenticated;

grant select on public.board, public.cards, public.card_events, public.cycle_history, public.notifications, public.team to authenticated;
grant update (name, timezone, wip_limit, stale_days, cycle_days, default_reviewer_id, security_reviewer_id, cycle_goals, updated_at) on public.board to authenticated;
grant select (id, name, email, role, timezone, notify_mode, pm_instant, active, muted_until, created_at, user_id, join_code, away_until, security) on public.people to authenticated;
grant insert (name, email, role, timezone, notify_mode, pm_instant, active, security) on public.people to authenticated;
grant update (name, email, role, timezone, notify_mode, pm_instant, active, muted_until, away_until, security) on public.people to authenticated;
grant delete on public.people to authenticated;
grant insert (id, title, notes, status, prio, assignee_id, reviewer_id, due, tags, checks, blocked, horizon, size, waiting_on, block_note) on public.cards to authenticated;
grant update (title, notes, status, prio, assignee_id, reviewer_id, due, tags, checks, blocked, horizon, size, waiting_on, block_note) on public.cards to authenticated;
grant delete on public.cards to authenticated;
grant update (read_at) on public.notifications to authenticated;
grant select, delete on public.card_comments to authenticated;
grant insert (card_id, body, mentions) on public.card_comments to authenticated;
grant select on public.notify_settings to authenticated;
grant update (emails_enabled, provider, from_name, from_email, app_url, hide_titles, updated_at) on public.notify_settings to authenticated;

grant execute on function private.me() to authenticated;
grant execute on function private.is_member() to authenticated;
grant execute on function private.is_pm() to authenticated;
grant execute on function private.is_system() to authenticated;
grant execute on function private.now_utc() to authenticated;
grant execute on function private.valid_checks(jsonb) to authenticated;

grant execute on function public.whoami() to authenticated;
grant execute on function public.roll_cycle_if_due() to authenticated;
grant execute on function public.roll_cycle_now() to authenticated;
grant execute on function public.update_my_prefs(text, text, text) to authenticated;
grant execute on function public.email_status() to authenticated;
grant execute on function public.send_test_email() to authenticated;
grant execute on function public.mute_by_token(uuid, text) to anon, authenticated;
grant execute on function public.start_join(text, text) to anon, authenticated;
grant execute on function public.finish_join(text) to authenticated;
grant execute on function public.reset_join_code(uuid) to authenticated;
grant execute on function public.claude_outbox_take(text, int) to anon;
grant execute on function public.set_my_away(date) to authenticated;
grant execute on function public.github_status() to authenticated;
grant execute on function public.cycle_report_preview(int, text) to authenticated;
grant execute on function public.github_sync(text, jsonb) to anon;
grant execute on function public.claude_outbox_done(text, uuid, boolean, text) to anon;

-- ---------------------------------------------------------------------
-- Live updates and schedules (Supabase only)
-- ---------------------------------------------------------------------

-- @supabase-only:begin
-- Optional hardening: stop strangers from creating sign-in accounts (and burning your email
-- quota) by refusing any new account whose email is not on the team list. Switch it on in
-- Authentication > Hooks > Before User Created > Postgres function > public.hook_before_user_created
create or replace function public.hook_before_user_created(event jsonb) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if exists (select 1 from public.people where lower(email) = lower(event -> 'user' ->> 'email') and active) then
    return '{}'::jsonb;
  end if;
  return jsonb_build_object('error', jsonb_build_object(
    'message', 'This email is not on the team. Ask your project manager to add it.', 'http_code', 403));
end $$;
revoke execute on function public.hook_before_user_created(jsonb) from public, anon, authenticated;
grant execute on function public.hook_before_user_created(jsonb) to supabase_auth_admin;

-- The app only uses the normal data API and live updates, so switch the GraphQL door off.
do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'graphql_public') then
    revoke usage on schema graphql_public from anon, authenticated;
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'cards') then
    alter publication supabase_realtime add table public.cards;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'board') then
    alter publication supabase_realtime add table public.board;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'notifications') then
    alter publication supabase_realtime add table public.notifications;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'card_comments') then
    alter publication supabase_realtime add table public.card_comments;
  end if;
end $$;

-- Images in descriptions and comments: a private bucket. Only people on the team can see or add them;
-- the person who added an image (or a PM) can remove it. 5 MB each.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('card-images', 'card-images', false, 5242880, array['image/png', 'image/jpeg', 'image/webp', 'image/gif'])
on conflict (id) do nothing;
drop policy if exists nudge_images_read on storage.objects;
create policy nudge_images_read on storage.objects for select to authenticated
  using (bucket_id = 'card-images' and (select private.is_member()));
drop policy if exists nudge_images_add on storage.objects;
create policy nudge_images_add on storage.objects for insert to authenticated
  with check (bucket_id = 'card-images' and (select private.is_member()));
drop policy if exists nudge_images_remove on storage.objects;
create policy nudge_images_remove on storage.objects for delete to authenticated
  using (bucket_id = 'card-images' and ((select private.is_pm()) or owner_id = (select auth.uid())::text));

select cron.schedule('nudge-notify', '* * * * *', $cron$select private.run_notifications()$cron$);
select cron.schedule('nudge-roll-cycle', '7 * * * *', $cron$select private.roll_cycle(false)$cron$);
select cron.schedule('nudge-cron-cleanup', '17 3 * * *',
  $cron$delete from cron.job_run_details where end_time < now() - interval '3 days'$cron$);
-- @supabase-only:end

-- Next: run supabase/first_pm.sql (see docs/SETUP.md, step 3).
