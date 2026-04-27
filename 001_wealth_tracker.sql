-- ============================================================
-- Wealth Tracker — Updated Schema + RLS + Permissions
-- ============================================================

-- Enable UUID extension
create extension if not exists "uuid-ossp";

-- 1. HOUSEHOLDS
create table if not exists households (
  id          uuid primary key default uuid_generate_v4(),
  name        text not null default 'Our Household',
  created_at  timestamptz not null default now()
);

-- 2. HOUSEHOLD MEMBERS
create table if not exists household_members (
  id            uuid primary key default uuid_generate_v4(),
  household_id  uuid not null references households(id) on delete cascade,
  user_id       uuid not null references auth.users(id) on delete cascade,
  display_name  text not null,
  label         char(1) not null check (label in ('A','B')),
  created_at    timestamptz not null default now(),
  unique (household_id, user_id),
  unique (household_id, label)
);

-- 3. ASSETS
create table if not exists assets (
  id            uuid primary key default uuid_generate_v4(),
  household_id  uuid not null references households(id) on delete cascade,
  name          text not null,
  owner         text not null check (owner in ('A','B','Both')),
  institution   text not null,
  currency      text not null check (currency in ('USD','SGD','INR')),
  asset_type    text not null check (asset_type in ('Equity','Cash','Retirement','Alternative','Real Estate')),
  geography     text not null check (geography in ('US','SG','IN')),
  value         numeric(18,2) not null check (value >= 0),
  notes         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- 4. MORTGAGES
create table if not exists mortgages (
  id                uuid primary key default uuid_generate_v4(),
  household_id      uuid not null references households(id) on delete cascade,
  name              text not null,
  owner             text not null check (owner in ('A','B','Both')),
  currency          text not null check (currency in ('USD','SGD','INR')),
  property_value    numeric(18,2) not null check (property_value >= 0),
  pending_balance   numeric(18,2) not null check (pending_balance >= 0),
  interest_rate     numeric(5,2),
  notes             text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

-- 5. SNAPSHOTS
create table if not exists net_worth_snapshots (
  id                uuid primary key default uuid_generate_v4(),
  household_id      uuid not null references households(id) on delete cascade,
  snapshot_date     date not null default current_date,
  total_assets_usd    numeric(18,2) not null,
  total_liabilities_usd numeric(18,2) not null,
  net_worth_usd     numeric(18,2) not null,
  fx_usd_sgd      numeric(10,6) not null,
  fx_usd_inr      numeric(10,6) not null,
  created_at        timestamptz not null default now(),
  unique (household_id, snapshot_date)
);

-- 6. GOALS
create table if not exists goal_settings (
  id                  uuid primary key default uuid_generate_v4(),
  household_id        uuid not null references households(id) on delete cascade unique,
  retirement_goal_usd numeric(18,2) not null default 3000000,
  annual_savings_usd  numeric(18,2) not null default 80000,
  expected_return_pct numeric(5,2)  not null default 7.0,
  inflation_pct       numeric(5,2)  not null default 3.0,
  current_age_a       int,
  current_age_b       int,
  updated_at          timestamptz not null default now()
);

-- 7. FX RATES
create table if not exists fx_rates (
  id          uuid primary key default uuid_generate_v4(),
  base        text not null default 'USD',
  currency    text not null,
  rate        numeric(14,6) not null,
  fetched_at  timestamptz not null default now(),
  unique (base, currency)
);

-- ════════════════════════════════════════════════════════════
-- PERMISSIONS & RLS
-- ════════════════════════════════════════════════════════════

-- Grant API access to the schema
grant usage on schema public to anon, authenticated;
grant all on all tables in schema public to anon, authenticated;
grant all on all sequences in schema public to anon, authenticated;
grant all on all functions in schema public to anon, authenticated;

alter table households enable row level security;
alter table household_members enable row level security;
alter table assets enable row level security;
alter table mortgages enable row level security;
alter table net_worth_snapshots enable row level security;
alter table goal_settings enable row level security;
alter table fx_rates enable row level security;

-- Helper Function
create or replace function is_household_member(hh_id uuid)
returns boolean language sql security definer as $$
  select exists (
    select 1 from household_members
    where household_id = hh_id
      and user_id = auth.uid()
  );
$$;

-- Policies
create policy "members can view their household" on households for select using (is_household_member(id));
create policy "members can update their household" on households for update using (is_household_member(id));
create policy "members can view membership" on household_members for select using (is_household_member(household_id));
create policy "user can insert themselves" on household_members for insert with check (user_id = auth.uid());
create policy "members can CRUD assets" on assets for all using (is_household_member(household_id));
create policy "members can CRUD mortgages" on mortgages for all using (is_household_member(household_id));
create policy "members can view snapshots" on net_worth_snapshots for select using (is_household_member(household_id));
create policy "members can CRUD goals" on goal_settings for all using (is_household_member(household_id));
create policy "anyone can read fx rates" on fx_rates for select using (true);

-- ════════════════════════════════════════════════════════════
-- REFRESH CACHE & SEED
-- ════════════════════════════════════════════════════════════

-- Force the API to detect new tables
notify pgrst, 'reload schema';

-- Insert Demo Data
insert into households (id, name) values ('00000000-0000-0000-0000-000000000001', 'Demo Household') on conflict do nothing;

insert into fx_rates (base, currency, rate) values ('USD', 'USD', 1.0), ('USD', 'SGD', 1.345), ('USD', 'INR', 83.5) on conflict do nothing;

-- NOTE: To see the demo data in your app, run the following line manually in the SQL editor 
-- replacing 'YOUR_USER_ID' with your ID from the Auth > Users tab:
-- insert into household_members (household_id, user_id, display_name, label) 
-- values ('00000000-0000-0000-0000-000000000001', 'YOUR_USER_ID', 'User', 'A');
