-- ============================================================
-- NEXUS CHAT v3  -  run this WHOLE file in Supabase > SQL Editor
-- Safe to re-run. A dated backup of your old data is made first.
-- PASSWORDS: never stored here. Supabase Auth keeps only a bcrypt
-- hash in auth.users (not readable from the API). No table in this
-- file has a password column.
-- ============================================================
create extension if not exists pgcrypto;

-- ---------- 0. Automatic backup (private: RLS on, no policies) ----------
do $$
declare t text; b text;
begin
  foreach t in array array['profiles','messages','shorts','shorts_likes','shorts_comments'] loop
    if to_regclass('public.' || t) is not null then
      b := format('backup_%s_%s', t, to_char(now(), 'YYYYMMDD'));
      execute format('create table if not exists public.%I as table public.%I', b, t);
      execute format('alter table public.%I enable row level security', b);
    end if;
  end loop;
end $$;

-- ---------- 1. Reset policies on OUR tables + old signup triggers ----------
-- (leftover permissive policies would silently leak data, so ours are rebuilt)
do $$
declare r record;
begin
  for r in select policyname, tablename from pg_policies
           where schemaname='public'
             and tablename in ('profiles','messages','private_info','shorts','shorts_likes',
                               'shorts_comments','call_signals','push_subscriptions')
  loop
    execute format('drop policy %I on public.%I', r.policyname, r.tablename);
  end loop;

  for r in select t.tgname, p.proname from pg_trigger t
           join pg_proc p on p.oid = t.tgfoid
           join pg_namespace n on n.oid = p.pronamespace
           where t.tgrelid = 'auth.users'::regclass and not t.tgisinternal and n.nspname = 'public'
             and (t.tgname = 'on_auth_user_created' or p.proname ilike '%new_user%' or p.proname ilike '%profile%')
  loop
    raise notice 'Dropping old signup trigger % (function %)', r.tgname, r.proname;
    execute format('drop trigger %I on auth.users', r.tgname);
  end loop;
end $$;

-- ---------- 2. Profiles (public info) + private_info (phone) ----------
create table if not exists public.profiles(
  id uuid primary key references auth.users(id) on delete cascade,
  email text, first_name text, last_name text, country text,
  created_at timestamptz default now()
);
alter table public.profiles add column if not exists avatar_url text;
alter table public.profiles add column if not exists bio text;
alter table public.profiles add column if not exists last_seen timestamptz;

create table if not exists public.private_info(
  user_id uuid primary key references auth.users(id) on delete cascade,
  phone text,
  phone_norm text generated always as (right(regexp_replace(coalesce(phone,''),'\D','','g'),9)) stored
);

-- move old phone column (if any) out of the publicly readable table (copied first, backup exists)
do $$
begin
  if exists(select 1 from information_schema.columns
            where table_schema='public' and table_name='profiles' and column_name='phone') then
    insert into public.private_info(user_id, phone)
      select id, phone from public.profiles where phone is not null
      on conflict (user_id) do nothing;
    alter table public.profiles drop column phone;
  end if;
end $$;

alter table public.profiles enable row level security;
alter table public.private_info enable row level security;

create policy "profiles read"   on public.profiles for select to authenticated using (true);
create policy "profiles insert" on public.profiles for insert to authenticated with check (id = auth.uid());
create policy "profiles update" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

create policy "private read"   on public.private_info for select to authenticated using (user_id = auth.uid());
create policy "private insert" on public.private_info for insert to authenticated with check (user_id = auth.uid());
create policy "private update" on public.private_info for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles(id,email,first_name,last_name,country)
  values (new.id, new.email, new.raw_user_meta_data->>'first_name',
          new.raw_user_meta_data->>'last_name', new.raw_user_meta_data->>'country')
  on conflict (id) do update set email = excluded.email;
  insert into public.private_info(user_id, phone)
  values (new.id, new.raw_user_meta_data->>'phone')
  on conflict (user_id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
for each row execute function public.handle_new_user();

-- ---------- 3. Messages ----------
create table if not exists public.messages(
  id uuid primary key default gen_random_uuid(),
  conversation_id text not null,
  sender_id uuid not null references auth.users(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  text text default '',
  created_at timestamptz default now()
);
alter table public.messages alter column text drop not null;
alter table public.messages alter column text set default '';
alter table public.messages add column if not exists type text not null default 'text';
alter table public.messages add column if not exists media_path text;
alter table public.messages add column if not exists media_meta jsonb;
alter table public.messages add column if not exists status text not null default 'sent';
alter table public.messages add column if not exists delivered_at timestamptz;
alter table public.messages add column if not exists read_at timestamptz;
alter table public.messages add column if not exists reactions jsonb not null default '{}'::jsonb;
alter table public.messages add column if not exists deleted boolean not null default false;
do $$
begin
  execute format('alter table public.messages add column if not exists reply_to %s',
    (select format_type(atttypid, atttypmod) from pg_attribute
      where attrelid='public.messages'::regclass and attname='id'));
end $$;

create index if not exists messages_conv_idx on public.messages(conversation_id, created_at);
create index if not exists messages_recipient_idx on public.messages(recipient_id, status);

alter table public.messages enable row level security;

create policy "messages read" on public.messages for select to authenticated
  using (auth.uid() in (sender_id, recipient_id));

create policy "messages insert" on public.messages for insert to authenticated
  with check (
    sender_id = auth.uid() and recipient_id <> sender_id and
    conversation_id = case when sender_id::text collate "C" < recipient_id::text collate "C"
                           then sender_id::text || '_' || recipient_id::text
                           else recipient_id::text || '_' || sender_id::text end
  );

create policy "messages update" on public.messages for update to authenticated
  using (auth.uid() in (sender_id, recipient_id))
  with check (auth.uid() in (sender_id, recipient_id));

create or replace function public.messages_guard() returns trigger
language plpgsql as $$
begin
  if new.id is distinct from old.id
     or new.conversation_id is distinct from old.conversation_id
     or new.sender_id is distinct from old.sender_id
     or new.recipient_id is distinct from old.recipient_id
     or new.text is distinct from old.text
     or new.type is distinct from old.type
     or new.media_path is distinct from old.media_path
     or new.media_meta is distinct from old.media_meta
     or new.created_at is distinct from old.created_at
     or new.reply_to is distinct from old.reply_to then
    raise exception 'message content is immutable';
  end if;
  if new.deleted is distinct from old.deleted and auth.uid() is distinct from old.sender_id then
    raise exception 'only the sender can delete';
  end if;
  if (new.status is distinct from old.status or new.delivered_at is distinct from old.delivered_at
      or new.read_at is distinct from old.read_at) and auth.uid() is distinct from old.recipient_id then
    raise exception 'only the recipient can update receipts';
  end if;
  if old.status = 'read' and new.status <> 'read' then new.status := 'read'; end if;
  return new;
end $$;
drop trigger if exists messages_guard_trg on public.messages;
create trigger messages_guard_trg before update on public.messages
for each row execute function public.messages_guard();

-- ---------- 4. Call signalling (authenticated, un-spoofable: from_id must be you) ----------
create table if not exists public.call_signals(
  id uuid primary key default gen_random_uuid(),
  from_id uuid not null references auth.users(id) on delete cascade,
  to_id   uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in ('offer','answer','ice','end','reject')),
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists call_signals_to_idx on public.call_signals(to_id, created_at);
alter table public.call_signals enable row level security;
create policy "signals insert" on public.call_signals for insert to authenticated
  with check (from_id = auth.uid() and to_id <> auth.uid());
create policy "signals read" on public.call_signals for select to authenticated
  using (to_id = auth.uid() or from_id = auth.uid());
create policy "signals delete" on public.call_signals for delete to authenticated
  using (to_id = auth.uid() or from_id = auth.uid());

-- ---------- 5. Push notification subscriptions ----------
create table if not exists public.push_subscriptions(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now()
);
alter table public.push_subscriptions enable row level security;
create policy "push read"   on public.push_subscriptions for select to authenticated using (user_id = auth.uid());
create policy "push delete" on public.push_subscriptions for delete to authenticated using (user_id = auth.uid());

-- upsert that also handles a shared device (endpoint moves to the newly signed-in user)
create or replace function public.register_push(p_endpoint text, p_p256dh text, p_auth text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  insert into public.push_subscriptions(user_id, endpoint, p256dh, auth)
  values (auth.uid(), p_endpoint, p_p256dh, p_auth)
  on conflict (endpoint) do update set user_id = auth.uid(), p256dh = excluded.p256dh, auth = excluded.auth;
end $$;
create or replace function public.unregister_push(p_endpoint text)
returns void language sql security definer set search_path = public as $$
  delete from public.push_subscriptions where endpoint = p_endpoint and user_id = auth.uid();
$$;
revoke all on function public.register_push(text,text,text) from public;
revoke all on function public.unregister_push(text) from public;
grant execute on function public.register_push(text,text,text) to authenticated;
grant execute on function public.unregister_push(text) to authenticated;

-- ---------- 6. Shorts (short videos) ----------
create table if not exists public.shorts(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  video_path text not null,
  video_url text not null,
  caption text default '',
  created_at timestamptz default now()
);
create table if not exists public.shorts_likes(
  short_id uuid not null references public.shorts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  primary key (short_id, user_id)
);
create table if not exists public.shorts_comments(
  id uuid primary key default gen_random_uuid(),
  short_id uuid not null references public.shorts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  text text not null check (char_length(text) between 1 and 500),
  created_at timestamptz default now()
);
create index if not exists shorts_created_idx on public.shorts(created_at desc);
create index if not exists shorts_comments_idx on public.shorts_comments(short_id, created_at);

alter table public.shorts enable row level security;
alter table public.shorts_likes enable row level security;
alter table public.shorts_comments enable row level security;

create policy "shorts read"   on public.shorts for select to authenticated using (true);
create policy "shorts insert" on public.shorts for insert to authenticated with check (user_id = auth.uid());
create policy "shorts delete" on public.shorts for delete to authenticated using (user_id = auth.uid());

create policy "likes read"   on public.shorts_likes for select to authenticated using (true);
create policy "likes insert" on public.shorts_likes for insert to authenticated with check (user_id = auth.uid());
create policy "likes delete" on public.shorts_likes for delete to authenticated using (user_id = auth.uid());

create policy "comments read"   on public.shorts_comments for select to authenticated using (true);
create policy "comments insert" on public.shorts_comments for insert to authenticated with check (user_id = auth.uid());
create policy "comments delete" on public.shorts_comments for delete to authenticated using (user_id = auth.uid());

-- ---------- 7. Find people by phone (numbers never listed; lookups are rate-limited) ----------
create table if not exists public.contact_lookups(
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null,
  n int not null default 0,
  primary key (user_id, day)
);
alter table public.contact_lookups enable row level security;   -- no policies: only the function below touches it

create or replace function public.match_contacts(phones text[])
returns table(user_id uuid, phone_norm text)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v int;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if phones is null or cardinality(phones) = 0 then return; end if;
  if cardinality(phones) > 500 then raise exception 'Too many numbers at once (max 500)'; end if;
  insert into public.contact_lookups as c(user_id, day, n)
  values (auth.uid(), current_date, cardinality(phones))
  on conflict (user_id, day) do update set n = c.n + excluded.n
  returning c.n into v;
  if v > 3000 then raise exception 'Daily contact lookup limit reached. Try again tomorrow.'; end if;
  return query
    select p.user_id, p.phone_norm
    from public.private_info p
    where p.user_id <> auth.uid()
      and p.phone_norm <> ''
      and p.phone_norm = any (select right(regexp_replace(x,'\D','','g'),9) from unnest(phones) x);
end $$;
revoke all on function public.match_contacts(text[]) from public;
grant execute on function public.match_contacts(text[]) to authenticated;

-- ---------- 8. Storage buckets (50 MB = Supabase free-plan maximum per file) ----------
insert into storage.buckets (id, name, public, file_size_limit) values
  ('avatars',   'avatars',   true,  5242880),
  ('chat-media','chat-media',false, 52428800),
  ('shorts',    'shorts',    true,  52428800)
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit;

drop policy if exists "nexus avatars read"   on storage.objects;
drop policy if exists "nexus avatars write"  on storage.objects;
drop policy if exists "nexus avatars update" on storage.objects;
drop policy if exists "nexus avatars delete" on storage.objects;
drop policy if exists "nexus shorts read"    on storage.objects;
drop policy if exists "nexus shorts write"   on storage.objects;
drop policy if exists "nexus shorts delete"  on storage.objects;
drop policy if exists "nexus chat read"      on storage.objects;
drop policy if exists "nexus chat write"     on storage.objects;

create policy "nexus avatars read"   on storage.objects for select using (bucket_id = 'avatars');
create policy "nexus avatars write"  on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "nexus avatars update" on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "nexus avatars delete" on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "nexus shorts read"   on storage.objects for select using (bucket_id = 'shorts');
create policy "nexus shorts write"  on storage.objects for insert to authenticated
  with check (bucket_id = 'shorts' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "nexus shorts delete" on storage.objects for delete to authenticated
  using (bucket_id = 'shorts' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "nexus chat read"  on storage.objects for select to authenticated
  using (bucket_id = 'chat-media' and position(auth.uid()::text in (storage.foldername(name))[1]) > 0);
create policy "nexus chat write" on storage.objects for insert to authenticated
  with check (bucket_id = 'chat-media' and position(auth.uid()::text in (storage.foldername(name))[1]) > 0);

-- ---------- 9. Realtime: tables ----------
do $$
declare t text;
begin
  foreach t in array array['messages','profiles','shorts','call_signals'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;

-- ---------- 10. Realtime: PRIVATE channels (typing + online presence) ----------
-- After running this: Dashboard > Realtime > Settings > turn OFF "Allow public access".
do $$
begin
  execute 'drop policy if exists "nexus rt read" on realtime.messages';
  execute 'drop policy if exists "nexus rt write" on realtime.messages';
  -- chat-<uidA>_<uidB> : only those two people. online : any signed-in user.
  execute $p$create policy "nexus rt read" on realtime.messages for select to authenticated
    using ( realtime.messages.extension in ('broadcast','presence')
            and ( realtime.topic() = 'online'
                  or ( realtime.topic() like 'chat-%' and position(auth.uid()::text in realtime.topic()) > 0 ) ) )$p$;
  execute $p$create policy "nexus rt write" on realtime.messages for insert to authenticated
    with check ( realtime.messages.extension in ('broadcast','presence')
            and ( realtime.topic() = 'online'
                  or ( realtime.topic() like 'chat-%' and position(auth.uid()::text in realtime.topic()) > 0 ) ) )$p$;
exception when others then
  raise notice 'Could not create realtime policies (%). Update Supabase / enable Realtime Authorization, then re-run.', sqlerrm;
end $$;
