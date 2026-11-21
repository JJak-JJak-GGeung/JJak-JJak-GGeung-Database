-- Trainers can open a synthetic original without sharing another browser's evidence.
create table public.directory_samples (
  code text primary key,
  store_id uuid not null references public.stores,
  supplier_id uuid not null,
  period_id uuid not null,
  trade_date date not null,
  item text not null,
  unit text not null,
  qty numeric not null check(qty>0),
  unit_price integer not null check(unit_price>=0),
  foreign key(store_id,supplier_id) references public.suppliers(store_id,id),
  foreign key(store_id,period_id) references public.periods(store_id,id)
);
alter table public.directory_samples enable row level security;
revoke all on public.directory_samples from public,anon,authenticated;
grant select on public.directory_samples to service_role;

do $$
declare
  fixture_owner uuid := gen_random_uuid();
  shop uuid; vendor uuid; week_id uuid; r record;
begin
  for r in select * from (values
    ('S01','예시 봄들식당','예시 푸른채소','2026-11-17'::date,'양배추','망',3,12000),
    ('S02','예시 봄들식당','예시 온샘두부','2026-11-18'::date,'판두부','판',5,8500),
    ('S03','예시 강변분식','예시 푸른채소','2026-11-19'::date,'대파','단',8,2500)
  ) as v(code,shop_name,vendor_name,trade_date,item,unit,qty,unit_price) loop
    shop := (public.register_directory_name(fixture_owner,null,r.shop_name)->>'id')::uuid;
    vendor := (public.register_directory_name(fixture_owner,shop,r.vendor_name)->>'id')::uuid;
    insert into public.periods(store_id,supplier_id,period_start,period_end)
      values(shop,vendor,'2026-11-16','2026-11-22') returning id into week_id;
    insert into public.directory_samples values(r.code,shop,vendor,week_id,r.trade_date,r.item,r.unit,r.qty,r.unit_price);
  end loop;
end $$;
