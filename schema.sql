-- Moe's Songbook – Supabase database setup
-- Run once in Supabase: Dashboard → SQL Editor → paste this file → Run.
-- Then make yourself admin (after signing in once):
--   update public.profiles set role = 'admin' where id = (select id from auth.users where email = 'you@example.com');
-- The rules (premium access, sharing slots, rating limits) live here, in the database,
-- so a modified app cannot get around them.

-- gen_random_uuid() is built into Postgres 13+ (Supabase), no extension needed

-- ---------- tables ----------
create table if not exists public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'User',
  role         text not null default 'user' check (role in ('user','admin')),
  country      text not null default 'OT',
  plan_until   timestamptz,
  created_at   timestamptz not null default now()
);

create table if not exists public.songs (
  key         text primary key,            -- normalised "title|artist"
  title       text not null,
  artist      text not null default '',
  premium     boolean not null default false,
  licensed_by text not null default ''     -- who licensed it; required before premium = true
);

create table if not exists public.arrangements (
  id          uuid primary key default gen_random_uuid(),
  owner       uuid not null references public.profiles(id) on delete cascade,
  song_key    text not null references public.songs(key),
  title       text not null,
  artist      text not null default '',
  music_key   text not null default '',
  visibility  text not null check (visibility in ('public','link','private')),
  status      text not null default 'live' check (status in ('review','live','hidden','rejected')),
  share_code  text not null unique default substr(md5(gen_random_uuid()::text),1,10),
  preview     text not null default '',    -- first part only; always readable
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists arrangements_song on public.arrangements(song_key);
create index if not exists arrangements_owner on public.arrangements(owner);

-- full text lives in its own table so row security can hide premium songs from non-subscribers
create table if not exists public.arrangement_bodies (
  arrangement_id uuid primary key references public.arrangements(id) on delete cascade,
  body           text not null
);

create table if not exists public.ratings (
  arrangement_id uuid not null references public.arrangements(id) on delete cascade,
  user_id        uuid not null references public.profiles(id) on delete cascade,
  stars          int  not null check (stars between 1 and 5),
  created_at     timestamptz not null default now(),
  primary key (arrangement_id, user_id)
);

create table if not exists public.reports (
  id             uuid primary key default gen_random_uuid(),
  arrangement_id uuid not null references public.arrangements(id) on delete cascade,
  user_id        uuid not null references public.profiles(id) on delete cascade,
  reason         text not null,
  open           boolean not null default true,
  created_at     timestamptz not null default now(),
  unique (arrangement_id, user_id)
);

create table if not exists public.payments (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles(id) on delete cascade,
  country    text not null,
  period     text not null,
  months     int  not null check (months between 1 and 12),
  amount     numeric not null,
  currency   text not null,
  method     text not null,
  txn        text not null,
  note       text not null default '',
  status     text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid
);

create table if not exists public.app_config (
  key   text primary key,
  value jsonb not null
);
insert into public.app_config(key,value) values ('wallets','{"kbz":"KBZPay 09-…","wave":"WavePay 09-…"}') on conflict do nothing;

-- ---------- helpers ----------
create or replace function public.is_admin() returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from profiles where id = auth.uid() and role = 'admin')
$$;
create or replace function public.is_premium(u uuid) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select plan_until > now() from profiles where id = u), false)
$$;
create or replace function public.good_ratings(u uuid) returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from ratings r join arrangements a on a.id = r.arrangement_id where a.owner = u and r.stars >= 4
$$;
create or replace function public.used_slots(u uuid) returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from arrangements where owner = u and visibility <> 'private' and status <> 'rejected'
$$;
-- 3 slots to start, +1 per 10 good ratings, max 50; Premium = unlimited
create or replace function public.slot_limit(u uuid) returns int language sql stable security definer set search_path = public as $$
  select case when is_premium(u) then 1000000 else least(50, 3 + good_ratings(u) / 10) end
$$;
create or replace function public.song_key_of(t text, a text) returns text language sql immutable as $$
  select trim(regexp_replace(regexp_replace(lower(normalize(coalesce(t,''), NFC)), '[​-‍﻿]', '', 'g'), '\s+', ' ', 'g'))
      || '|' ||
         trim(regexp_replace(regexp_replace(lower(normalize(coalesce(a,''), NFC)), '[​-‍﻿]', '', 'g'), '\s+', ' ', 'g'))
$$;

-- new sign-up → profile
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into profiles(id, display_name) values (new.id, coalesce(split_part(new.email,'@',1),'User')) on conflict do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

-- ---------- views the app reads ----------
create or replace view public.profile_view as
  select p.id, p.display_name, p.role, p.country, p.plan_until, p.created_at,
         good_ratings(p.id) as good, used_slots(p.id) as used
  from profiles p where p.id = auth.uid();

-- ranking: Bayesian average (5 pseudo-ratings of 3.5); accounts under 30 days count half
create or replace view public.arrangement_full as
  select a.id, a.owner, pr.display_name as owner_name, a.song_key, a.title, a.artist, a.music_key, a.visibility, a.status,
         a.share_code, a.preview, s.premium, s.licensed_by, a.created_at, a.updated_at,
         coalesce(st.n,0) as n, coalesce(st.avg,0) as avg,
         (5*3.5 + coalesce(st.wsum,0)) / (5 + coalesce(st.w,0)) as score,
         lower(a.title || ' ' || a.artist || ' ' || a.preview) as search_text
  from arrangements a
  join songs s on s.key = a.song_key
  join profiles pr on pr.id = a.owner
  left join lateral (
    select count(*) as n, avg(r.stars)::numeric(3,2) as avg,
           sum(r.stars * case when rp.created_at > now() - interval '30 days' then 0.5 else 1 end) as wsum,
           sum(case when rp.created_at > now() - interval '30 days' then 0.5 else 1 end) as w
    from ratings r join profiles rp on rp.id = r.user_id where r.arrangement_id = a.id
  ) st on true;
revoke all on public.arrangement_full from anon, authenticated;

create or replace view public.arrangement_list as
  select * from public.arrangement_full f
  where (f.visibility = 'public' and f.status = 'live') or f.owner = auth.uid() or public.is_admin();
grant select on public.arrangement_list, public.profile_view to anon, authenticated;

-- ---------- functions the app calls ----------
create or replace function public.arrangement_by_share(code text) returns setof public.arrangement_full
language sql stable security definer set search_path = public as $$
  select * from arrangement_full where share_code = code and visibility <> 'private' and status not in ('rejected','hidden')
$$;

create or replace function public.publish_arrangement(p_id uuid, p_title text, p_artist text, p_key text, p_visibility text, p_body text, p_preview text)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); k text; cur arrangements; was_shared boolean := false; st text; new_id uuid;
begin
  if me is null then raise exception 'Sign in first'; end if;
  if coalesce(trim(p_title),'') = '' then raise exception 'Add a title first'; end if;
  if p_visibility not in ('public','link','private') then raise exception 'Bad visibility'; end if;
  k := song_key_of(p_title, p_artist);
  insert into songs(key,title,artist) values (k, p_title, coalesce(p_artist,'')) on conflict do nothing;
  if p_id is not null then
    select * into cur from arrangements where id = p_id and owner = me;
    if not found then raise exception 'Not your arrangement'; end if;
    was_shared := cur.visibility <> 'private' and cur.status <> 'rejected';
  end if;
  if p_visibility <> 'private' and not was_shared and used_slots(me) >= slot_limit(me) then
    raise exception 'You have used all % sharing slots. Earn more with good ratings, or keep it private.', slot_limit(me);
  end if;
  st := case when p_visibility = 'public' and good_ratings(me) < 10 and not is_admin() then 'review' else 'live' end;
  if p_id is null then
    insert into arrangements(owner,song_key,title,artist,music_key,visibility,status,preview)
      values (me,k,p_title,coalesce(p_artist,''),coalesce(p_key,''),p_visibility,st,p_preview) returning id into new_id;
  else
    update arrangements set song_key=k,title=p_title,artist=coalesce(p_artist,''),music_key=coalesce(p_key,''),visibility=p_visibility,preview=p_preview,updated_at=now(),
      status = case when cur.status = 'live' and p_visibility <> 'public' then 'live'
                    when cur.status = 'live' then 'live'
                    when cur.status = 'hidden' then 'hidden'
                    else st end
      where id = p_id;
    new_id := p_id;
  end if;
  insert into arrangement_bodies(arrangement_id, body) values (new_id, p_body)
    on conflict (arrangement_id) do update set body = excluded.body;
  return new_id;
end $$;

create or replace function public.decide_payment(p_id uuid, p_ok boolean) returns void
language plpgsql security definer set search_path = public as $$
declare p payments;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  select * into p from payments where id = p_id and status = 'pending' for update;
  if not found then return; end if;
  update payments set status = case when p_ok then 'approved' else 'rejected' end, decided_at = now(), decided_by = auth.uid() where id = p_id;
  if p_ok then
    update profiles set plan_until = greatest(now(), coalesce(plan_until, now())) + make_interval(months => p.months) where id = p.user_id;
  end if;
end $$;

create or replace function public.decide_report(p_id uuid, p_hide boolean) returns void
language plpgsql security definer set search_path = public as $$
declare a uuid;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  select arrangement_id into a from reports where id = p_id;
  update reports set open = false where arrangement_id = a;
  update arrangements set status = case when p_hide then 'hidden' else 'live' end where id = a;
end $$;

-- ---------- rules on ratings and reports ----------
create or replace function public.check_rating() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists(select 1 from arrangements where id = new.arrangement_id and owner = new.user_id) then
    raise exception 'You can''t rate your own arrangement'; end if;
  if (select created_at from profiles where id = new.user_id) > now() - interval '7 days' then
    raise exception 'New accounts can rate after 7 days'; end if;
  return new;
end $$;
drop trigger if exists ratings_check on public.ratings;
create trigger ratings_check before insert or update on public.ratings for each row execute function public.check_rating();

create or replace function public.auto_hide() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from reports where arrangement_id = new.arrangement_id and open) >= 3 then
    update arrangements set status = 'hidden' where id = new.arrangement_id and status = 'live';
  end if;
  return new;
end $$;
drop trigger if exists reports_hide on public.reports;
create trigger reports_hide after insert on public.reports for each row execute function public.auto_hide();

-- ---------- row-level security ----------
alter table public.profiles           enable row level security;
alter table public.songs              enable row level security;
alter table public.arrangements       enable row level security;
alter table public.arrangement_bodies enable row level security;
alter table public.ratings            enable row level security;
alter table public.reports            enable row level security;
alter table public.payments           enable row level security;
alter table public.app_config         enable row level security;

create policy profiles_read   on public.profiles for select using (id = auth.uid() or public.is_admin());
create policy profiles_update on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());
revoke update on public.profiles from anon, authenticated;
grant update (display_name, country) on public.profiles to authenticated;   -- role and plan_until cannot be changed by users

create policy songs_read  on public.songs for select using (true);
create policy songs_admin on public.songs for update using (public.is_admin());

create policy arr_read   on public.arrangements for select using ((visibility = 'public' and status = 'live') or owner = auth.uid() or public.is_admin());
create policy arr_admin  on public.arrangements for update using (public.is_admin());
create policy arr_delete on public.arrangements for delete using (owner = auth.uid() or public.is_admin());
-- inserts and owner edits go through publish_arrangement() only

create or replace function public.can_read_body(arr uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from arrangements a join songs s on s.key = a.song_key
          where a.id = arr
            and (a.owner = auth.uid() or is_admin()
                 or (a.visibility <> 'private' and a.status = 'live'
                     and (not s.premium or is_premium(auth.uid())))))
$$;
create policy bodies_read on public.arrangement_bodies for select using (public.can_read_body(arrangement_id));

create policy ratings_own_read on public.ratings for select using (user_id = auth.uid());
create policy ratings_insert   on public.ratings for insert with check (user_id = auth.uid());
create policy ratings_update   on public.ratings for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy ratings_delete   on public.ratings for delete using (user_id = auth.uid());

create policy reports_insert on public.reports for insert with check (user_id = auth.uid());
create policy reports_read   on public.reports for select using (user_id = auth.uid() or public.is_admin());

create policy payments_insert on public.payments for insert with check (user_id = auth.uid() and status = 'pending');
create policy payments_read   on public.payments for select using (user_id = auth.uid() or public.is_admin());

create policy config_read   on public.app_config for select using (true);
create policy config_insert on public.app_config for insert with check (public.is_admin());
create policy config_update on public.app_config for update using (public.is_admin());

-- ---------- favorites (added) ----------
create table if not exists public.favorites (
  user_id        uuid not null references public.profiles(id) on delete cascade,
  arrangement_id uuid not null references public.arrangements(id) on delete cascade,
  created_at     timestamptz not null default now(),
  primary key (user_id, arrangement_id)
);
alter table public.favorites enable row level security;
create policy favorites_read   on public.favorites for select using (user_id = auth.uid());
create policy favorites_insert on public.favorites for insert with check (user_id = auth.uid());
create policy favorites_delete on public.favorites for delete using (user_id = auth.uid());
