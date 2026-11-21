begin;
do $$
declare a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); d uuid; p uuid; s uuid; result jsonb; draft jsonb;
 req jsonb:='{"store_name":"fixture","supplier_name":"vendor","week_start":"2026-11-09","doc_type":"DELIVERY","lines":[{"item":"x","qty_read":"1"}]}';
 media jsonb:='{"hash":"fictional","filename":"test.png","path":"fixture/file","mime":"image/png","size":10,"key":"req1","payload":"ok"}';
begin
 draft:='{"trade_date":"2025-01-30","_review_dates":{"trade_date":"2025-01-31"},"source_date_text":"거래일 2025.1.31","lines":[{"item":"x","source_location":{"page":1,"row":1},"line_date_text":"1/31","tax_amount_read":0}]}';
 result:=confirm_photo_with_context(a,req,media,draft);
 d:=(result->>'document_id')::uuid; p:=(result->>'period_id')::uuid; s:=(result->>'store_id')::uuid;
 if not exists(select from documents where id=d and trade_date=date '2025-01-31' and issued_on is null and metadata->'photo_review'->'draft'->>'trade_date'='2025-01-30')
 or not exists(select from periods where id=p and period_start=date '2026-11-09')
 or not exists(select from doc_lines where document_id=d and tax_amount_read=0 and line_date_text='1/31')
 then raise exception 'period, edited date, original date or line evidence lost'; end if;
 perform correct_document_trade_date(a,p,d,'2025-01-31','2025-02-01');
 if not exists(select from documents where id=d and trade_date=date '2025-02-01') then raise exception 'date correction lost'; end if;
 begin perform remove_uploaded_document(b,p,d); raise exception 'foreign removal'; exception when sqlstate 'PT404' then null; end;
 begin
  insert into settlement_versions(store_id,period_id,version_no,input_revision,confirmation_scope,snapshot,request_key,actor_label)
  values(s,p,1,1,'DOCUMENTS_ONLY',jsonb_build_object('documents',jsonb_build_array(jsonb_build_object('id',d))),'snap','tester');
  perform remove_uploaded_document(a,p,d); raise exception 'approved source deleted';
 exception when sqlstate 'PT409' then null; end;
 if (remove_uploaded_document(a,p,d)->>'path') is distinct from 'fixture/file' then raise exception 'retired path missing'; end if;
 if exists(select from period_documents where document_id=d) then raise exception 'membership survived'; end if;
 if exists(select from documents where id=d) or exists(select from doc_lines where document_id=d) then raise exception 'document survived'; end if;
 if remove_uploaded_document(a,p,d)->>'path' is distinct from 'fixture/file' then raise exception 'retry'; end if;
 begin perform confirm_photo_with_context(a,req,media||'{"key":"again"}',draft);
 raise exception 'reused retired path'; exception when sqlstate 'PT409' then null; end;
 result:=confirm_photo_with_context(a,req,media||jsonb_build_object('key','again','path','fixture/file~'||d::text),draft);
 if result->>'document_id'=d::text then raise exception 're-upload failed'; end if;
end $$;
rollback;
