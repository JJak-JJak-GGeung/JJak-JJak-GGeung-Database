create type public.period_status as enum ('OPEN','REVIEWING','APPROVED');
create table public.stores(id uuid primary key default gen_random_uuid(), owner_user_id uuid, name text not null);
create table public.suppliers(id uuid primary key default gen_random_uuid(),store_id uuid not null references public.stores(id),name text not null,contact text,unique(store_id,id));
create table public.periods(id uuid primary key default gen_random_uuid(),store_id uuid not null references public.stores(id),supplier_id uuid not null,period_start date not null,period_end date not null,payment_due_on date,status public.period_status not null default 'OPEN',input_revision int not null default 0,unique(store_id,id),unique(store_id,supplier_id,period_start,period_end),foreign key(store_id,supplier_id) references public.suppliers(store_id,id),check(period_end>=period_start));
alter table public.stores enable row level security;
alter table public.suppliers enable row level security;
alter table public.periods enable row level security;
revoke all on public.stores,public.suppliers,public.periods from anon,authenticated;
grant select on public.stores,public.suppliers,public.periods to service_role;
with s as (insert into public.stores(name) values ('해커톤 검수 점포') returning id),
v as (insert into public.suppliers(store_id,name) select id,'검수 거래처' from s returning id,store_id)
insert into public.periods(store_id,supplier_id,period_start,period_end) select store_id,id,'2026-11-09','2026-11-15' from v;
