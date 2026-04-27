-- ============================================================
-- Wealth Tracker — Supabase schema + RLS + seed data
-- Run this in: Supabase Dashboard → SQL Editor → New query
-- ============================================================

-- Enable UUID extension
create extension if not exists "uuid-ossp";


-- ────────────────────────────────────────────────────────────
-- 1. HOUSEHOLDS
--    One row per couple. Auth users are linked via household_members.
-- ────────────────────────────────────────────────────────────
create table if not exists households (
  id          uuid primary key default uuid_generate_v4(),
  name        text not null default 'Our Household',
  created_at  timestamptz not null default now()
);

-- ────────────────────────────────────────────────────────────
-- 2. HOUSEHOLD MEMBERS
--    Maps auth.users → household, with a display label (A / B).
-- ────────────────────────────────────────────────────────────
create table if not exists household_members (
  id            uuid primary key default uuid_generate_v4(),
  household_id  uuid not null references households(id) on delete cascade,
  user_id       uuid not null references auth.users(id) on delete cascade,
  display_name  text not null,          -- e.g. "Alex", "Sam"
  label         char(1) not null check (label in ('A','B')),
  created_at    timestamptz not null default now(),
  unique (household_id, user_id),
  unique (household_id, label)
);

-- ────────────────────────────────────────────────────────────
-- 3. ASSETS
-- ────────────────────────────────────────────────────────────
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

-- ────────────────────────────────────────────────────────────
-- 4. MORTGAGES / LIABILITIES
-- ────────────────────────────────────────────────────────────
create table if not exists mortgages (
  id                uuid primary key default uuid_generate_v4(),
  household_id      uuid not null references households(id) on delete cascade,
  name              text not null,
  owner             text not null check (owner in ('A','B','Both')),
  currency          text not null check (currency in ('USD','SGD','INR')),
  property_value    numeric(18,2) not null check (property_value >= 0),
  pending_balance   numeric(18,2) not null check (pending_balance >= 0),
  interest_rate     numeric(5,2),          -- annual %, optional
  notes             text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

-- ────────────────────────────────────────────────────────────
-- 5. NET WORTH SNAPSHOTS  (append-only history log)
--    Call the snapshot function (see below) on a schedule or
--    on each save to build the history chart.
-- ────────────────────────────────────────────────────────────
create table if not exists net_worth_snapshots (
  id              uuid primary key default uuid_generate_v4(),
  household_id    uuid not null references households(id) on delete cascade,
  snapshot_date   date not null default current_date,
  total_assets_usd    numeric(18,2) not null,
  total_liabilities_usd numeric(18,2) not null,
  net_worth_usd   numeric(18,2) not null,
  fx_usd_sgd      numeric(10,6) not null,
  fx_usd_inr      numeric(10,6) not null,
  created_at      timestamptz not null default now(),
  unique (household_id, snapshot_date)   -- one snapshot per day
);

-- ────────────────────────────────────────────────────────────
-- 6. GOAL SETTINGS  (one row per household, upserted)
-- ────────────────────────────────────────────────────────────
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

-- ────────────────────────────────────────────────────────────
-- 7. FX RATE CACHE  (write from edge function on schedule)
-- ────────────────────────────────────────────────────────────
create table if not exists fx_rates (
  id          uuid primary key default uuid_generate_v4(),
  base        text not null default 'USD',
  currency    text not null,
  rate        numeric(14,6) not null,
  fetched_at  timestamptz not null default now(),
  unique (base, currency)
);

-- Insert fallback rates (overwritten by live fetch)
insert into fx_rates (base, currency, rate) values
  ('USD', 'USD', 1.0),
  ('USD', 'SGD', 1.345),
  ('USD', 'INR', 83.5)
on conflict (base, currency) do nothing;


-- ════════════════════════════════════════════════════════════
-- ROW LEVEL SECURITY
-- ════════════════════════════════════════════════════════════

alter table households          enable row level security;
alter table household_members   enable row level security;
alter table assets              enable row level security;
alter table mortgages           enable row level security;
alter table net_worth_snapshots enable row level security;
alter table goal_settings       enable row level security;
alter table fx_rates            enable row level security;

-- Helper: is the calling user a member of this household?
create or replace function is_household_member(hh_id uuid)
returns boolean language sql security definer as $$
  select exists (
    select 1 from household_members
    where household_id = hh_id
      and user_id = auth.uid()
  );
$$;

-- households: members can read; only creators can update
create policy "members can view their household"
  on households for select using (is_household_member(id));

create policy "members can update their household"
  on households for update using (is_household_member(id));

-- household_members: members can view; users can insert themselves
create policy "members can view membership"
  on household_members for select using (is_household_member(household_id));

create policy "user can insert themselves"
  on household_members for insert with check (user_id = auth.uid());

-- assets: full CRUD for household members
create policy "members can view assets"
  on assets for select using (is_household_member(household_id));

create policy "members can insert assets"
  on assets for insert with check (is_household_member(household_id));

create policy "members can update assets"
  on assets for update using (is_household_member(household_id));

create policy "members can delete assets"
  on assets for delete using (is_household_member(household_id));

-- mortgages: full CRUD for household members
create policy "members can view mortgages"
  on mortgages for select using (is_household_member(household_id));

create policy "members can insert mortgages"
  on mortgages for insert with check (is_household_member(household_id));

create policy "members can update mortgages"
  on mortgages for update using (is_household_member(household_id));

create policy "members can delete mortgages"
  on mortgages for delete using (is_household_member(household_id));

-- snapshots: read-only for members; inserts via service role only
create policy "members can view snapshots"
  on net_worth_snapshots for select using (is_household_member(household_id));

-- goal settings: full CRUD for members
create policy "members can view goals"
  on goal_settings for select using (is_household_member(household_id));

create policy "members can upsert goals"
  on goal_settings for insert with check (is_household_member(household_id));

create policy "members can update goals"
  on goal_settings for update using (is_household_member(household_id));

-- fx_rates: public read (no auth needed)
create policy "anyone can read fx rates"
  on fx_rates for select using (true);


-- ════════════════════════════════════════════════════════════
-- TRIGGERS — auto-update updated_at
-- ════════════════════════════════════════════════════════════
create or replace function set_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end;
$$;

create trigger assets_updated_at
  before update on assets
  for each row execute function set_updated_at();

create trigger mortgages_updated_at
  before update on mortgages
  for each row execute function set_updated_at();

create trigger goal_settings_updated_at
  before update on goal_settings
  for each row execute function set_updated_at();


-- ════════════════════════════════════════════════════════════
-- SNAPSHOT FUNCTION
-- Call this daily via pg_cron or a Supabase Edge Function cron.
-- Example cron (pg_cron):
--   select cron.schedule('daily-snapshot','0 18 * * *',
--     $$select take_net_worth_snapshot()$$);
-- ════════════════════════════════════════════════════════════
create or replace function take_net_worth_snapshot()
returns void language plpgsql security definer as $$
declare
  hh record;
  fx_sgd numeric; fx_inr numeric;
  total_assets numeric; total_liab numeric;
begin
  select rate into fx_sgd from fx_rates where base='USD' and currency='SGD';
  select rate into fx_inr from fx_rates where base='USD' and currency='INR';

  for hh in select id from households loop
    select coalesce(sum(
      case currency
        when 'USD' then value
        when 'SGD' then value / fx_sgd
        when 'INR' then value / fx_inr
      end
    ), 0) into total_assets
    from assets where household_id = hh.id;

    select coalesce(sum(
      case currency
        when 'USD' then pending_balance
        when 'SGD' then pending_balance / fx_sgd
        when 'INR' then pending_balance / fx_inr
      end
    ), 0) into total_liab
    from mortgages where household_id = hh.id;

    insert into net_worth_snapshots
      (household_id, snapshot_date, total_assets_usd, total_liabilities_usd, net_worth_usd, fx_usd_sgd, fx_usd_inr)
    values
      (hh.id, current_date, total_assets, total_liab, total_assets - total_liab, fx_sgd, fx_inr)
    on conflict (household_id, snapshot_date)
    do update set
      total_assets_usd      = excluded.total_assets_usd,
      total_liabilities_usd = excluded.total_liabilities_usd,
      net_worth_usd         = excluded.net_worth_usd,
      fx_usd_sgd            = excluded.fx_usd_sgd,
      fx_usd_inr            = excluded.fx_usd_inr,
      created_at            = now();
  end loop;
end;
$$;


-- ════════════════════════════════════════════════════════════
-- SEED DATA  (demo household — remove before production)
-- ════════════════════════════════════════════════════════════

-- Insert a demo household (no real auth user linked)
insert into households (id, name) values
  ('00000000-0000-0000-0000-000000000001', 'Demo Household')
on conflict do nothing;

insert into assets (household_id, name, owner, institution, currency, asset_type, geography, value) values
  ('00000000-0000-0000-0000-000000000001','US Brokerage (IBKR)','A','IBKR','USD','Equity','US',280000),
  ('00000000-0000-0000-0000-000000000001','Morgan Stanley Managed','B','Morgan Stanley','USD','Equity','US',195000),
  ('00000000-0000-0000-0000-000000000001','Joint S&P ETF','Both','IBKR','USD','Equity','US',320000),
  ('00000000-0000-0000-0000-000000000001','DBS Savings SGD','A','Local Bank','SGD','Cash','SG',85000),
  ('00000000-0000-0000-0000-000000000001','CPF OA','A','CPF','SGD','Retirement','SG',210000),
  ('00000000-0000-0000-0000-000000000001','CPF SA','B','CPF','SGD','Retirement','SG',175000),
  ('00000000-0000-0000-0000-000000000001','HDFC FD','B','Local Bank','INR','Cash','IN',3500000),
  ('00000000-0000-0000-0000-000000000001','Mutual Funds (Zerodha)','B','IBKR','INR','Equity','IN',4200000),
  ('00000000-0000-0000-0000-000000000001','Art Collection','Both','Art','USD','Alternative','US',45000),
  ('00000000-0000-0000-0000-000000000001','Gold ETF','A','IBKR','USD','Alternative','US',32000)
on conflict do nothing;

insert into mortgages (household_id, name, owner, currency, property_value, pending_balance, interest_rate) values
  ('00000000-0000-0000-0000-000000000001','Singapore Condo','Both','SGD',1250000,620000,2.75)
on conflict do nothing;

insert into goal_settings (household_id, retirement_goal_usd, annual_savings_usd, expected_return_pct, inflation_pct, current_age_a, current_age_b) values
  ('00000000-0000-0000-0000-000000000001', 3000000, 80000, 7.0, 3.0, 38, 36)
on conflict do nothing;

-- Seed 6 years of historical snapshots for the demo
insert into net_worth_snapshots (household_id, snapshot_date, total_assets_usd, total_liabilities_usd, net_worth_usd, fx_usd_sgd, fx_usd_inr) values
  ('00000000-0000-0000-0000-000000000001','2020-12-31',580000,160000,420000,1.34,73.0),
  ('00000000-0000-0000-0000-000000000001','2021-12-31',740000,180000,560000,1.35,74.5),
  ('00000000-0000-0000-0000-000000000001','2022-12-31',900000,190000,710000,1.36,82.0),
  ('00000000-0000-0000-0000-000000000001','2023-12-31',1090000,210000,880000,1.34,83.1),
  ('00000000-0000-0000-0000-000000000001','2024-12-31',1280000,230000,1050000,1.34,83.6),
  ('00000000-0000-0000-0000-000000000001','2025-12-31',1460000,250000,1210000,1.345,83.5)
on conflict do nothing;
