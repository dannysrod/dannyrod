-- Uncomment if you want to remove tables before create
-- drop table if exists orgs;
-- drop table if exists tracking;
-- drop table if exists profiles;
-- Create a table for Organizations
create table orgs (
  id bigint generated by default as identity primary key,
  created_at timestamp with time zone default timezone('utc' :: text, now()) not null,
  updated_at timestamp with time zone default timezone('utc' :: text, now()) not null,
  name varchar unique not null
);

alter table
  orgs enable row level security;

create
or replace function auth.org() returns text as 
$$
select
  nullif(
    (
      (
        current_setting('request.jwt.claims') :: jsonb ->> 'app_metadata'
      ) :: jsonb ->> 'org'
    ),
    ''
  ) :: text 
$$ 
language sql;

-- Create a table for Public Profiles
create table profiles (
  id uuid references auth.users not null,
  updated_at timestamp with time zone,
  username text unique,
  -- avatar_url text,
  -- website text,
  primary key (id),
  unique(username),
  constraint username_length check (char_length(username) >= 3)
);

alter table
  profiles enable row level security;

create policy "Public profiles are viewable by everyone." on profiles for
select
  using (true);

create policy "Users can insert their own profile." on profiles for
insert
  with check (auth.uid() = id);

create policy "Users can update own profile." on profiles for
update
  using (auth.uid() = id);

-- -- Set up Realtime!
-- begin;
--   drop publication if exists supabase_realtime;
--   create publication supabase_realtime;
-- commit;
-- alter publication supabase_realtime
--   add table profiles;
-- -- Set up Storage!
-- insert into storage.buckets (id, name)
--   values ('avatars', 'avatars');
-- create policy "Avatar images are publicly accessible." on storage.objects
--   for select using (bucket_id = 'avatars');
-- create policy "Anyone can upload an avatar." on storage.objects
--   for insert with check (bucket_id = 'avatars');
-- create policy "Anyone can update an avatar." on storage.objects
--   for update with check (bucket_id = 'avatars');
-- USER TRACKING TABLE
create table if not exists tracking (
  id bigint generated by default as identity primary key,
  timestamp timestamp with time zone default timezone('utc' :: text, now()) not null,
  event jsonb
);

--CUSTOM CLAIMS FUNCTIONS
--https://github.com/supabase-community/supabase-custom-claims/blob/main/install.sql
CREATE
OR REPLACE FUNCTION is_claims_admin() RETURNS "bool" LANGUAGE "plpgsql" AS $ $ BEGIN IF session_user = 'authenticator' THEN --------------------------------------------
-- To disallow any authenticated app users
-- from editing claims, delete the following
-- block of code and replace it with:
-- RETURN FALSE;
--------------------------------------------
IF extract(
  epoch
  from
    now()
) > coalesce(
  (
    current_setting('request.jwt.claims', true) :: jsonb
  ) ->> 'exp',
  '0'
) :: numeric THEN return false;

-- jwt expired
END IF;

IF coalesce(
  (
    current_setting('request.jwt.claims', true) :: jsonb
  ) -> 'app_metadata' -> 'claims_admin',
  'false'
) :: bool THEN return true;

-- user has claims_admin set to true
ELSE return false;

-- user does NOT have claims_admin set to true
END IF;

--------------------------------------------
-- End of block 
--------------------------------------------
ELSE -- not a user session, probably being called from a trigger or something
return true;

END IF;

END;

$ $;

CREATE
OR REPLACE FUNCTION get_my_claims() RETURNS "jsonb" LANGUAGE "sql" STABLE AS $ $
select
  coalesce(
    nullif(current_setting('request.jwt.claims', true), '') :: jsonb -> 'app_metadata',
    '{}' :: jsonb
  ) :: jsonb $ $;

CREATE
OR REPLACE FUNCTION get_my_claim(claim TEXT) RETURNS "jsonb" LANGUAGE "sql" STABLE AS $ $
select
  coalesce(
    nullif(current_setting('request.jwt.claims', true), '') :: jsonb -> 'app_metadata' -> claim,
    null
  ) $ $;

CREATE
OR REPLACE FUNCTION get_claims(uid uuid) RETURNS "jsonb" LANGUAGE "plpgsql" SECURITY DEFINER
SET
  search_path = public AS $ $ DECLARE retval jsonb;

BEGIN IF NOT is_claims_admin() THEN RETURN '{"error":"access denied"}' :: jsonb;

ELSE
select
  raw_app_meta_data
from
  auth.users into retval
where
  id = uid :: uuid;

return retval;

END IF;

END;

$ $;

CREATE
OR REPLACE FUNCTION get_claim(uid uuid, claim text) RETURNS "jsonb" LANGUAGE "plpgsql" SECURITY DEFINER
SET
  search_path = public AS $ $ DECLARE retval jsonb;

BEGIN IF NOT is_claims_admin() THEN RETURN '{"error":"access denied"}' :: jsonb;

ELSE
select
  coalesce(raw_app_meta_data -> claim, null)
from
  auth.users into retval
where
  id = uid :: uuid;

return retval;

END IF;

END;

$ $;

CREATE
OR REPLACE FUNCTION set_claim(uid uuid, claim text, value jsonb) RETURNS "text" LANGUAGE "plpgsql" SECURITY DEFINER
SET
  search_path = public AS $ $ BEGIN IF NOT is_claims_admin() THEN RETURN 'error: access denied';

ELSE
update
  auth.users
set
  raw_app_meta_data = raw_app_meta_data || json_build_object(claim, value) :: jsonb
where
  id = uid;

return 'OK';

END IF;

END;

$ $;

CREATE
OR REPLACE FUNCTION delete_claim(uid uuid, claim text) RETURNS "text" LANGUAGE "plpgsql" SECURITY DEFINER
SET
  search_path = public AS $ $ BEGIN IF NOT is_claims_admin() THEN RETURN 'error: access denied';

ELSE
update
  auth.users
set
  raw_app_meta_data = raw_app_meta_data - claim
where
  id = uid;

return 'OK';

END IF;

END;

$ $;

NOTIFY pgrst,
'reload schema';