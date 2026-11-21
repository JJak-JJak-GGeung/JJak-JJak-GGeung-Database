begin;
set local role service_role;
do $$
declare
 owner_id uuid:=gen_random_uuid(); shop uuid; supplier uuid; period_id uuid;
 confirmed jsonb; again jsonb; edits jsonb := '[{"source_row":1,"item":"합성 검수","unit":"kg","qty_read":"2","amount_read":6000}]';
 draft jsonb := '{"lines":[{"source_location":{"page":1,"row":1}}]}';
 fields jsonb := '{"trade_date":"2025-01-31","doc_type":"DELIVERY"}';
begin
 shop:=(register_directory_name(owner_id,null,'합성 검수점')->>'id')::uuid;
 supplier:=(register_directory_name(owner_id,shop,'합성 공급처')->>'id')::uuid;
 insert into periods(store_id,supplier_id,period_start,period_end) values(shop,supplier,'2026-11-16','2026-11-22') returning id into period_id;
 confirmed:=confirm_photo_review_v2(period_id,shop,supplier,'fixture_v2','sample.png','fixture/v2','image/png',123,'fixture_req','payload','DELIVERY',draft,fields,edits,0,'검수',owner_id);
 again:=confirm_photo_review_v2(period_id,shop,supplier,'fixture_v2','sample.png','fixture/v2','image/png',123,'fixture_req','payload','DELIVERY',draft,fields,edits,0,'검수',owner_id);
 if not (again->>'duplicate')::boolean or again->>'document_id'<>confirmed->>'document_id'
 or not exists(select from documents d join doc_lines l on d.id=l.document_id where d.id=(confirmed->>'document_id')::uuid and d.trade_date=date '2025-01-31' and l.amount_read=6000 and l.raw_name='합성 검수') then raise exception 'v2 persistence mismatch';end if;
end $$;
rollback;
