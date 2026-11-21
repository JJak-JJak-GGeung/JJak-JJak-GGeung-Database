begin;
do $$
declare a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); sg uuid; out1 jsonb; out2 jsonb;
  req jsonb:='{"store_name":"테스트 점포","supplier_name":"새 납품처","week_start":"2026-11-09","doc_type":"DELIVERY","lines":[{"item":"테스트 품목","qty_read":"0","amount_read":0}]}';
  media jsonb:='{"hash":"fixture-vendor","filename":"sample.png","path":"test/sample","mime":"image/png","size":100,"key":"sample-key","payload":"same"}';
  draft jsonb:='{"lines":[{"item":"테스트 품목","qty_read":"1","source_location":{"page":1,"row":1}}]}';
begin
  draft:=draft||'{"trade_date":"2025-01-31","tax_total":15,"document_total":5500,"previous_balance":45,"balance_after_dispatch":5545,"deposit_amount":88,"current_balance":5545,"_review_amounts":{"tax_total":0,"deposit_amount":null}}'::jsonb;
  out1:=confirm_photo_with_context(a,req,media,draft);
  out2:=confirm_photo_with_context(a,req,media,draft);
  if out1->>'document_id' is distinct from out2->>'document_id' or not (out2->>'duplicate')::boolean then raise exception 'replay'; end if;
  if not exists(select from documents where id=(out1->>'document_id')::uuid
    and trade_date=date '2025-01-31' and tax_total=0 and document_total=5500 and previous_balance=45
    and balance_after_dispatch=5545 and deposit_amount is null and current_balance=5545 and supply_total is null
    and metadata->'photo_review'->'draft'->>'deposit_amount'='88'
    and metadata->'photo_review'->'amount_overrides'->'deposit_amount'='null'::jsonb)
  then raise exception 'reviewed statement header mismatch'; end if;
  begin
    perform confirm_photo_with_context(a,req,media||'{"key":"next","payload":"changed"}'::jsonb,
      jsonb_set(draft,'{_review_amounts,tax_total}','123'));
    raise exception 'silent duplicate with different tax';
  exception when sqlstate 'PT409' then null; end;
end $$;

do $$
declare
 owner_id uuid:=gen_random_uuid(); shop uuid; supplier uuid; period_id uuid;
 confirmed jsonb; again jsonb; edits jsonb := '[{"source_row":1,"item":"합성 검수","unit":"kg","qty_read":"2","amount_read":6000}]';
 draft jsonb := '{"lines":[{"source_location":{"page":1,"row":1}}]}';
 fields jsonb := '{"trade_date":"2025-01-31","doc_type":"DELIVERY","supply_total":6000,"tax_total":600,"document_total":6600,"deposit_amount":0}';
begin
 shop:=(register_directory_name(owner_id,null,'합성 검수점')->>'id')::uuid;
 supplier:=(register_directory_name(owner_id,shop,'합성 공급처')->>'id')::uuid;
 insert into periods(store_id,supplier_id,period_start,period_end) values(shop,supplier,'2026-11-16','2026-11-22') returning id into period_id;
 confirmed:=confirm_photo_review_v2(period_id,shop,supplier,'fixture_v2','sample.png','fixture/v2','image/png',123,'fixture_req','payload','DELIVERY',draft,fields,edits,0,'검수',owner_id);
 again:=confirm_photo_review_v2(period_id,shop,supplier,'fixture_v2','sample.png','fixture/v2','image/png',123,'fixture_req','payload','DELIVERY',draft,fields,edits,0,'검수',owner_id);
 if not (again->>'duplicate')::boolean or again->>'document_id'<>confirmed->>'document_id'
 or not exists(select from documents d join doc_lines l on d.id=l.document_id where d.id=(confirmed->>'document_id')::uuid and d.trade_date=date '2025-01-31' and d.supply_total=6000 and d.tax_total=600 and d.document_total=6600 and d.deposit_amount=0 and d.current_balance is null and l.amount_read=6000 and l.raw_name='합성 검수') then raise exception 'v2 persistence mismatch';end if;
end $$;
rollback;
