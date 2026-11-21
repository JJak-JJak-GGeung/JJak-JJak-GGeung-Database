begin;
do $$
declare a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); sg uuid; out1 jsonb; out2 jsonb;
  req jsonb:='{"store_name":"테스트 점포","supplier_name":"새 납품처","week_start":"2026-11-09","doc_type":"DELIVERY","lines":[{"item":"테스트 품목","qty_read":"0","amount_read":0}]}';
  media jsonb:='{"hash":"fixture-vendor","filename":"sample.png","path":"test/sample","mime":"image/png","size":100,"key":"sample-key","payload":"same"}';
  draft jsonb:='{"lines":[{"item":"테스트 품목","qty_read":"1","source_location":{"page":1,"row":1}}]}';
begin
  out1:=confirm_photo_with_context(a,req,media,draft);
  out2:=confirm_photo_with_context(a,req,media,draft);
  if out1->>'document_id' is distinct from out2->>'document_id' or not (out2->>'duplicate')::boolean then raise exception 'replay'; end if;
  sg:=(out1->>'store_id')::uuid;
  if (select count(*) from suppliers where store_id=sg)<>1 then raise exception 'supplier duplicated'; end if;
  if not exists (select from periods where id=(out1->>'period_id')::uuid and period_end=date '2026-11-15') then raise exception 'wrong week'; end if;
  if not exists (select from documents where id=(out1->>'document_id')::uuid and storage_path='test/sample' and metadata->'photo_review'->'draft'=draft) then raise exception 'missing evidence'; end if;
  begin
    perform confirm_photo_with_context(b,(req-'store_name')||jsonb_build_object('store_id',sg),media,draft);
    raise exception 'owner isolation';
  exception when sqlstate 'PT404' then null; end;
  begin
    perform confirm_photo_with_context(a,req||'{"supplier_name":"rollback"}',media||'{"payload":"changed"}',draft);
    raise exception 'expected conflict';
  exception when sqlstate 'PT409' then null; end;
  if exists(select from suppliers where store_id=sg and name='rollback') then raise exception 'partial registration'; end if;
end $$;
rollback;
