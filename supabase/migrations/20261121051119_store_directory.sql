-- Both entry points take the same owner lock and apply identical name matching.
create function public.register_directory_name(p_owner uuid, p_store uuid, p_name text)
returns jsonb language plpgsql security invoker set search_path=public as $$
declare
  clean text := btrim(p_name);
  matches uuid[];
  found_id uuid;
  saved_name text;
begin
  if p_owner is null or coalesce(length(clean),0) not between 1 and 150 then
    raise sqlstate 'PT422' using message='NAME_REQUIRED';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_owner::text,1));
  if p_store is null then
    select array_agg(id), min(name) into matches, saved_name from stores
      where owner_user_id=p_owner and lower(btrim(name))=lower(clean);
    if cardinality(matches)>1 then raise sqlstate 'PT409' using message='CHOOSE_EXISTING_STORE'; end if;
    if matches is null then
      insert into stores(owner_user_id,name) values(p_owner,clean) returning id,name into found_id,saved_name;
    end if;
  else
    perform 1 from stores where id=p_store and owner_user_id=p_owner for update;
    if not found then raise sqlstate 'PT404' using message='STORE_NOT_FOUND'; end if;
    select array_agg(id), min(name) into matches, saved_name from suppliers
      where store_id=p_store and lower(btrim(name))=lower(clean);
    if cardinality(matches)>1 then raise sqlstate 'PT409' using message='CHOOSE_EXISTING_SUPPLIER'; end if;
    if matches is null then
      insert into suppliers(store_id,name) values(p_store,clean) returning id,name into found_id,saved_name;
    end if;
  end if;
  return jsonb_build_object('id',coalesce(found_id,matches[1]),'name',saved_name,'created',found_id is not null);
end $$;
revoke all on function public.register_directory_name(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.register_directory_name(uuid,uuid,text) to service_role;

create or replace function public.confirm_photo_with_context(p_owner uuid, p_review jsonb, p_file jsonb, p_draft jsonb)
returns jsonb language plpgsql security invoker set search_path=public as $$
declare
  shop uuid := (p_review->>'store_id')::uuid;
  vendor uuid := (p_review->>'supplier_id')::uuid;
  week date := (p_review->>'week_start')::date;
  shop_name text := trim(p_review->>'store_name');
  vendor_name text := trim(p_review->>'supplier_name');
  period_id uuid;
  result jsonb;
begin
  if p_owner is null or week is null or extract(isodow from week)<>1 then
    raise sqlstate 'PT422' using message='REVIEW_WEEK_REQUIRED';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_owner::text,1));
  if shop is null then
    shop := (register_directory_name(p_owner,null,shop_name)->>'id')::uuid;
  end if;
  perform 1 from stores where id=shop and owner_user_id=p_owner for update;
  if not found then raise sqlstate 'PT404' using message='STORE_NOT_FOUND'; end if;
  if vendor is null then
    vendor := (register_directory_name(p_owner,shop,vendor_name)->>'id')::uuid;
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
