-- de caf shared map: run once in the Supabase SQL editor.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.de_caf_invites (
  id bigint generated always as identity primary key,
  code_hash text not null unique,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.de_caf_members (
  user_id uuid primary key references auth.users (id) on delete cascade,
  display_name text,
  joined_at timestamptz not null default now(),
  constraint de_caf_members_name_length check (display_name is null or char_length(display_name) between 1 and 32)
);

create table if not exists public.de_caf_cafes (
  id text primary key check (id like 'custom:%'),
  name text not null check (char_length(trim(name)) between 1 and 100),
  address text not null default '' check (char_length(address) <= 140),
  lat double precision not null check (lat between 50.05 and 50.85),
  lon double precision not null check (lon between 29.9 and 31.05),
  created_by uuid not null default auth.uid() references auth.users (id),
  created_at timestamptz not null default now()
);

create table if not exists public.de_caf_removed_cafes (
  cafe_id text primary key,
  removed_by uuid not null default auth.uid() references auth.users (id),
  created_at timestamptz not null default now()
);

create table if not exists public.de_caf_reviews (
  id uuid primary key default gen_random_uuid(),
  cafe_id text not null,
  cafe_name text not null,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  author_name text not null default '',
  rating numeric(2, 1) not null check (rating >= 0.5 and rating <= 5 and rating * 2 = trunc(rating * 2)),
  drinks text[] not null check (cardinality(drinks) > 0),
  decaf boolean not null default false,
  price integer check (price is null or price between 0 and 9999),
  body text not null default '' check (char_length(body) <= 280),
  photo_path text,
  created_at timestamptz not null default now()
);

create index if not exists de_caf_reviews_created_at_idx on public.de_caf_reviews (created_at desc);
create index if not exists de_caf_reviews_cafe_id_idx on public.de_caf_reviews (cafe_id);

alter table public.de_caf_invites enable row level security;
alter table public.de_caf_members enable row level security;
alter table public.de_caf_cafes enable row level security;
alter table public.de_caf_removed_cafes enable row level security;
alter table public.de_caf_reviews enable row level security;

revoke all on public.de_caf_invites from anon, authenticated;
revoke all on public.de_caf_members from anon, authenticated;
revoke all on public.de_caf_cafes from anon, authenticated;
revoke all on public.de_caf_removed_cafes from anon, authenticated;
revoke all on public.de_caf_reviews from anon, authenticated;

grant select on public.de_caf_members to authenticated;
grant select, insert on public.de_caf_cafes to authenticated;
grant select on public.de_caf_removed_cafes to authenticated;
grant select, insert, delete on public.de_caf_reviews to authenticated;
grant update (rating, drinks, decaf, price, body, photo_path) on public.de_caf_reviews to authenticated;

create or replace function public.de_caf_is_member()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
set row_security = off
as $$
  select exists (
    select 1 from public.de_caf_members where user_id = auth.uid()
  );
$$;

revoke all on function public.de_caf_is_member() from public, anon;
grant execute on function public.de_caf_is_member() to authenticated;

create or replace function public.de_caf_join(p_invite_code text, p_display_name text default null)
returns table (display_name text)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
set row_security = off
as $$
declare
  clean_name text := nullif(trim(coalesce(p_display_name, '')), '');
  invite_hash text;
begin
  if auth.uid() is null then
    raise exception 'Sign in is required';
  end if;
  if clean_name is not null and char_length(clean_name) > 32 then
    raise exception 'Name must be 32 characters or fewer';
  end if;

  invite_hash := encode(extensions.digest(convert_to(trim(coalesce(p_invite_code, '')), 'UTF8'), 'sha256'), 'hex');
  if not exists (
    select 1 from public.de_caf_invites
    where code_hash = invite_hash and active = true
  ) then
    raise exception 'Invite link is invalid or disabled';
  end if;

  insert into public.de_caf_members as existing (user_id, display_name)
  values (auth.uid(), clean_name)
  on conflict (user_id) do update
    set display_name = coalesce(excluded.display_name, existing.display_name);

  return query select m.display_name from public.de_caf_members as m where m.user_id = auth.uid();
end;
$$;

revoke all on function public.de_caf_join(text, text) from public, anon;
grant execute on function public.de_caf_join(text, text) to authenticated;

create or replace function public.de_caf_set_review_author()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
set row_security = off
as $$
begin
  new.user_id := auth.uid();
  new.created_at := now();
  select m.display_name into new.author_name
  from public.de_caf_members as m
  where m.user_id = auth.uid();
  if new.author_name is null then
    raise exception 'Join the shared map before posting';
  end if;
  return new;
end;
$$;

drop trigger if exists de_caf_review_author on public.de_caf_reviews;
create trigger de_caf_review_author
before insert on public.de_caf_reviews
for each row execute function public.de_caf_set_review_author();

create or replace function public.de_caf_remove_cafe(p_cafe_id text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
set row_security = off
as $$
begin
  if not public.de_caf_is_member() then
    raise exception 'Shared-map membership is required';
  end if;
  if p_cafe_id is null or trim(p_cafe_id) = '' then
    raise exception 'Cafe id is required';
  end if;

  if p_cafe_id like 'custom:%' then
    delete from public.de_caf_cafes where id = p_cafe_id;
  else
    insert into public.de_caf_removed_cafes (cafe_id, removed_by)
    values (p_cafe_id, auth.uid())
    on conflict (cafe_id) do update set removed_by = excluded.removed_by, created_at = now();
  end if;
end;
$$;

revoke all on function public.de_caf_remove_cafe(text) from public, anon;
grant execute on function public.de_caf_remove_cafe(text) to authenticated;

drop policy if exists de_caf_members_read_self on public.de_caf_members;
create policy de_caf_members_read_self on public.de_caf_members
for select to authenticated using (user_id = auth.uid());

drop policy if exists de_caf_cafes_read_members on public.de_caf_cafes;
create policy de_caf_cafes_read_members on public.de_caf_cafes
for select to authenticated using (public.de_caf_is_member());

drop policy if exists de_caf_cafes_add_members on public.de_caf_cafes;
create policy de_caf_cafes_add_members on public.de_caf_cafes
for insert to authenticated with check (public.de_caf_is_member() and created_by = auth.uid());

drop policy if exists de_caf_removed_read_members on public.de_caf_removed_cafes;
create policy de_caf_removed_read_members on public.de_caf_removed_cafes
for select to authenticated using (public.de_caf_is_member());

drop policy if exists de_caf_reviews_read_members on public.de_caf_reviews;
create policy de_caf_reviews_read_members on public.de_caf_reviews
for select to authenticated using (public.de_caf_is_member());

drop policy if exists de_caf_reviews_add_members on public.de_caf_reviews;
create policy de_caf_reviews_add_members on public.de_caf_reviews
for insert to authenticated with check (public.de_caf_is_member() and user_id = auth.uid());

drop policy if exists de_caf_reviews_delete_own on public.de_caf_reviews;
create policy de_caf_reviews_delete_own on public.de_caf_reviews
for delete to authenticated using (public.de_caf_is_member() and user_id = auth.uid());

drop policy if exists de_caf_reviews_update_own on public.de_caf_reviews;
create policy de_caf_reviews_update_own on public.de_caf_reviews
for update to authenticated
using (public.de_caf_is_member() and user_id = auth.uid())
with check (public.de_caf_is_member() and user_id = auth.uid());

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('de-caf-photos', 'de-caf-photos', false, 12582912, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists de_caf_photos_read_members on storage.objects;
create policy de_caf_photos_read_members on storage.objects
for select to authenticated
using (bucket_id = 'de-caf-photos' and public.de_caf_is_member());

drop policy if exists de_caf_photos_add_own on storage.objects;
create policy de_caf_photos_add_own on storage.objects
for insert to authenticated
with check (
  bucket_id = 'de-caf-photos'
  and public.de_caf_is_member()
  and split_part(name, '/', 1) = auth.uid()::text
);

drop policy if exists de_caf_photos_delete_own on storage.objects;
create policy de_caf_photos_delete_own on storage.objects
for delete to authenticated
using (
  bucket_id = 'de-caf-photos'
  and public.de_caf_is_member()
  and split_part(name, '/', 1) = auth.uid()::text
);

do $$
begin
  alter publication supabase_realtime add table public.de_caf_cafes;
exception when duplicate_object then null;
end;
$$;

do $$
begin
  alter publication supabase_realtime add table public.de_caf_removed_cafes;
exception when duplicate_object then null;
end;
$$;

do $$
begin
  alter publication supabase_realtime add table public.de_caf_reviews;
exception when duplicate_object then null;
end;
$$;
