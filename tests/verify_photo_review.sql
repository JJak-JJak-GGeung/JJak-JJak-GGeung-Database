-- Run after migrations on a test database with one period. Leave the fixture unchanged.
begin;
do $$
declare p periods; first_doc jsonb; replay jsonb; draft jsonb; edits jsonb;
begin
 select * into strict p from periods limit 1;
 draft := '{"lines":[{"item":"sample","qty_read":"50","source_location":{"page":1,"row":1}}]}';
 edits := '[{"item":"sample","qty_read":"5","unit_price_read":null,"amount_read":0}]';
 first_doc := confirm_photo_review(p.id,p.store_id,p.supplier_id,'qa-photo','test.png','qa/photo','image/png',123,'review-1','payload','DELIVERY',draft,edits);
 replay := confirm_photo_review(p.id,p.store_id,p.supplier_id,'qa-photo','test.png','qa/photo','image/png',123,'review-1','payload','DELIVERY',draft,edits);
 if first_doc->>'document_id' is distinct from replay->>'document_id' or not (replay->>'duplicate')::boolean then raise exception 'duplicate review'; end if;
 if not exists (select from doc_lines where document_id=(first_doc->>'document_id')::uuid and qty_read=5 and amount_read=0 and unit_price_read is null) then raise exception 'incorrect confirmed line'; end if;
 if not exists (select from documents where id=(first_doc->>'document_id')::uuid and metadata->'photo_review'->'draft'=draft) then raise exception 'missing reading'; end if;
end $$;
rollback;
