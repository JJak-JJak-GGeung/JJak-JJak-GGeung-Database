-- Only an administrator can reserve an existing store for a verified email.
create table public.store_owner_invitations (
  store_id uuid primary key references public.stores(id) on delete cascade,
  email text not null check (email=lower(trim(email)) and email<>'')
);
alter table public.store_owner_invitations enable row level security;
revoke all on public.store_owner_invitations from public, anon, authenticated, service_role;

create function public.claim_store_invitations(p_owner uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
  with claimed as (
    update public.stores s set owner_user_id=p_owner
      from public.store_owner_invitations i, auth.users u
      where i.store_id=s.id and s.owner_user_id is null and u.id=p_owner
      and u.confirmation_sent_at is not null and u.email_confirmed_at >= u.confirmation_sent_at
      and lower(u.email)=i.email returning s.id
  )
  delete from public.store_owner_invitations i using claimed c where i.store_id=c.id;
end $$;
revoke all on function public.claim_store_invitations(uuid) from public, anon, authenticated;
grant execute on function public.claim_store_invitations(uuid) to service_role;

-- Resolve only within the authenticated owner's scope, then persist evidence atomically.
create function public.confirm_photo_with_context(p_owner uuid, p_review jsonb, p_file jsonb, p_draft jsonb)
returns jsonb language plpgsql security invoker set search_path=public as $$
declare
  shop uuid := (p_review->>'store_id')::uuid;
  vendor uuid := (p_review->>'supplier_id')::uuid;
  week date := (p_review->>'week_start')::date;
  shop_name text := trim(p_review->>'store_name');
  vendor_name text := trim(p_review->>'supplier_name');
  matches uuid[];
  period_id uuid;
  result jsonb;
begin
  if p_owner is null or week is null or extract(isodow from week)<>1 then
    raise sqlstate 'PT422' using message='REVIEW_WEEK_REQUIRED';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_owner::text,1));
  if shop is null then
    if coalesce(length(shop_name),0) not between 1 and 150 then raise sqlstate 'PT422' using message='STORE_NAME_REQUIRED'; end if;
    select array_agg(id) into matches from stores where owner_user_id=p_owner and lower(trim(name))=lower(shop_name);
    if cardinality(matches)>1 then raise sqlstate 'PT409' using message='CHOOSE_EXISTING_STORE'; end if;
    shop:=matches[1];
    if shop is null then insert into stores(owner_user_id,name) values(p_owner,shop_name) returning id into shop; end if;
  end if;
  perform 1 from stores where id=shop and owner_user_id=p_owner for update;
  if not found then raise sqlstate 'PT404' using message='STORE_NOT_FOUND'; end if;
  if vendor is null then
    if coalesce(length(vendor_name),0) not between 1 and 150 then raise sqlstate 'PT422' using message='SUPPLIER_NAME_REQUIRED'; end if;
    select array_agg(id) into matches from suppliers where store_id=shop and lower(trim(name))=lower(vendor_name);
    if cardinality(matches)>1 then raise sqlstate 'PT409' using message='CHOOSE_EXISTING_SUPPLIER'; end if;
    vendor:=matches[1];
    if vendor is null then insert into suppliers(store_id,name) values(shop,vendor_name) returning id into vendor; end if;
  end if;
  if not exists(select from suppliers where id=vendor and store_id=shop) then raise sqlstate 'PT422' using message='REVIEW_SCOPE_MISMATCH'; end if;
  insert into periods(store_id,supplier_id,period_start,period_end) values(shop,vendor,week,week+6)
    on conflict (store_id,supplier_id,period_start,period_end) do nothing;
  select id into strict period_id from periods where store_id=shop and supplier_id=vendor and period_start=week and period_end=week+6;
  result:=confirm_photo_review(period_id,shop,vendor,p_file->>'hash',p_file->>'filename',p_file->>'path',
     p_file->>'mime',(p_file->>'size')::int,p_file->>'key',p_file->>'payload',p_review->>'doc_type',p_draft,p_review->'lines');
  return result||jsonb_build_object('store_id',shop,'supplier_id',vendor,'period_id',period_id);
end $$;
revoke all on function public.confirm_photo_with_context(uuid,jsonb,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.confirm_photo_with_context(uuid,jsonb,jsonb,jsonb) to service_role;
