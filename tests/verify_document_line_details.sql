begin;
set local role service_role;

do $$
declare
  owner_id uuid := gen_random_uuid();
  shop uuid;
  supplier uuid;
  period_id uuid;
  revision int;
  confirmed jsonb;
  draft jsonb := '{"document_total":9900,"lines":[{"item":"사과","spec":"기존 규격","origin":"국내산",
     "source_location":{"page":1,"row":1}}]}';
  edits jsonb := '[{"item":"사과","spec":"1kg","item_code":"0012","lot_no":"LOT-03","line_note":"냉장",
     "amount_read":9000,"supply_amount_read":9000,"discount_amount_read":0,
     "tax_amount_read":900,"line_total_read":9900}]';
begin
  shop := (register_directory_name(owner_id,null,'품목 검증 점포')->>'id')::uuid;
  supplier := (register_directory_name(owner_id,shop,'품목 검증 공급처')->>'id')::uuid;
  insert into periods(store_id,supplier_id,period_start,period_end)
    values(shop,supplier,'2026-11-16','2026-11-22') returning id into period_id;

  confirmed := confirm_photo_review(period_id,shop,supplier,'fixture_details_v1','sample.png',
    'fixture/details-v1','image/png',123,'details_v1','payload','DELIVERY',draft,edits);
  if not exists (
    select from doc_lines where document_id=(confirmed->>'document_id')::uuid
      and raw_spec='1kg' and item_code='0012' and origin='국내산' and lot_no='LOT-03'
      and line_note='냉장' and amount_read=9000 and supply_amount_read=9000
      and discount_amount_read=0 and tax_amount_read=900 and line_total_read=9900
  ) or not exists (
    select from documents where id=(confirmed->>'document_id')::uuid and document_total=9900
  ) then raise exception 'v1 did not persist item details and statement total'; end if;

  select p.input_revision into revision from periods p where p.id=period_id;
  confirmed := confirm_photo_review_v2(period_id,shop,supplier,'fixture_details_v2','sample.png',
    'fixture/details-v2','image/png',123,'details_v2','payload','DELIVERY',draft,'{}',
    jsonb_build_array((edits->0)||'{"source_row":1,"origin":null}'::jsonb,
                      '{"item":"이전 형식의 품목","source_row":null}'::jsonb),
    revision,'검수',owner_id);
  if not exists (
    select from doc_lines where document_id=(confirmed->>'document_id')::uuid
      and item_code='0012' and origin is null and discount_amount_read=0 and line_total_read=9900
  ) or not exists (
    select from doc_lines where document_id=(confirmed->>'document_id')::uuid
      and raw_name='이전 형식의 품목' and item_code is null and line_total_read is null
  ) then raise exception 'v2 did not preserve item details and nulls'; end if;
end $$;

rollback;
