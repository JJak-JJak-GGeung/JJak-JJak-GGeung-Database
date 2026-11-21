-- Printed statement figures; null is unknown. No balance or payment is inferred.
alter table public.documents
  add column supply_total bigint,
  add column tax_total bigint,
  add column document_total bigint,
  add column previous_balance bigint,
  add column balance_after_dispatch bigint,
  add column deposit_amount bigint,
  add column current_balance bigint;

create or replace function public.persist_extraction(p_document uuid,p_fields jsonb,p_lines jsonb)
returns jsonb language plpgsql security invoker set search_path=public as $$
declare d documents; p uuid; item jsonb; lid uuid;
begin
 for p in select period_id from period_documents where document_id=p_document order by period_id loop
  perform 1 from periods where id=p for update;
 end loop;
 select * into d from documents where id=p_document for update;
 if not found then raise sqlstate 'PT404' using message='DOCUMENT_NOT_FOUND'; end if;
 if d.source_mode<>'FILE' then raise sqlstate 'PT422' using message='FILE_REQUIRED'; end if;
 -- Successful extraction is immutable to retries; corrections have a separate history.
 if d.extraction_status in ('COMPLETED','SUCCESS') then return to_jsonb(d); end if;
 if jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)=0 then
  raise sqlstate 'PT422' using message='NO_EXTRACTED_LINES'; end if;
 update documents set
  supply_total=(p_fields->>'supply_total')::bigint,
  tax_total=(p_fields->>'tax_total')::bigint,
  document_total=(p_fields->>'document_total')::bigint,
  previous_balance=(p_fields->>'previous_balance')::bigint,
  balance_after_dispatch=(p_fields->>'balance_after_dispatch')::bigint,
  deposit_amount=(p_fields->>'deposit_amount')::bigint,
  current_balance=(p_fields->>'current_balance')::bigint,
  supplier_name_read=p_fields->>'supplier_name_read',
  supplier_id=(p_fields->>'supplier_id')::uuid,
  trade_date=(p_fields->>'trade_date')::date, issued_on=(p_fields->>'issued_on')::date,
  quoted_on=(p_fields->>'quoted_on')::date, source_date_text=p_fields->>'source_date_text',
  doc_no=p_fields->>'doc_no',doc_date=(p_fields->>'doc_date')::date,
  period_start=(p_fields->>'period_start')::date,period_end=(p_fields->>'period_end')::date,
  payment_due_on=(p_fields->>'payment_due_on')::date,replaces_doc_no=p_fields->>'replaces_doc_no',
  agreement_text=p_fields->>'agreement_text',agreement_source_location=nullif(p_fields->'agreement_source_location','null'),
  metadata=metadata||jsonb_build_object('doc_type_read',p_fields->>'doc_type'),
  extraction_status='COMPLETED' where id=p_document;
 for item in select value from jsonb_array_elements(p_lines) loop
  lid:=(item->>'id')::uuid;
  insert into doc_lines(id,store_id,document_id,delivery_no,delivery_date,raw_name,raw_spec,raw_unit,qty_read,unit_price_read,amount_read,tax_amount_read,line_date_text,source_location,extraction_status)
  values(lid,d.store_id,d.id,item->>'delivery_no',(item->>'delivery_date')::date,item->>'item',item->>'spec',item->>'unit',
   (item->>'qty_read')::numeric,(item->>'unit_price_read')::numeric,(item->>'amount_read')::numeric,(item->>'tax_amount_read')::bigint,item->>'line_date_text',item->'source_location','COMPLETED');
 end loop;
 update period_documents pd set status=case
  when (p_fields->>'supplier_id')::uuid is distinct from per.supplier_id then 'UNCLASSIFIED'
  when exists(select 1 from documents other join period_documents op on op.document_id=other.id
    where op.period_id=pd.period_id and other.id<>pd.document_id
      and other.doc_type=d.doc_type and other.doc_no=p_fields->>'doc_no'
      and other.supplier_id=(p_fields->>'supplier_id')::uuid) then 'CANDIDATE'
  else 'ACTIVE' end
 from periods per where pd.period_id=per.id and pd.document_id=p_document;
 select * into d from documents where id=p_document;
 return to_jsonb(d);
end $$;

-- Confirm the displayed photo draft, the chosen supplier and its period in one transaction.
create or replace function public.confirm_photo_review(
 p_period uuid,p_store uuid,p_supplier uuid,p_hash text,p_filename text,p_path text,
 p_mime text,p_size int,p_key text,p_payload text,p_type text,p_draft jsonb,p_edits jsonb)
returns jsonb language plpgsql security invoker set search_path=public as $$
declare
 reg jsonb; doc documents; per periods; src jsonb; edit jsonb; lines jsonb := '[]';
 fields jsonb; i int; previous document_upload_requests;
begin
 select * into per from periods where id=p_period for update;
 if not found or per.store_id<>p_store or per.supplier_id<>p_supplier then
  raise sqlstate 'PT422' using message='REVIEW_SCOPE_MISMATCH'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_store::text,0));
 select * into previous from document_upload_requests where store_id=p_store and request_key=p_key;
 if found then
  if previous.payload_hash<>p_payload then raise sqlstate 'PT409' using message='KEY_REUSE'; end if;
  return jsonb_build_object('document_id',previous.document_id,'period_id',p_period,'duplicate',true);
 end if;
 select * into doc from documents where store_id=p_store and file_hash=p_hash for update;
 if found and doc.doc_type=p_type and doc.supplier_id=p_supplier
    and doc.metadata->'photo_review'->'confirmed_lines'=p_edits
    and (not (p_draft ? '_review_dates') or doc.trade_date is not distinct from (p_draft->'_review_dates'->>'trade_date')::date) and
    not exists(select 1 from jsonb_each((p_draft||coalesce(p_draft->'_review_amounts','{}'::jsonb))) a
      where a.key=any(array['supply_total','tax_total','document_total','previous_balance','balance_after_dispatch','deposit_amount','current_balance'])
        and (to_jsonb(doc)->a.key) is distinct from a.value) and
    exists(select 1 from period_documents where document_id=doc.id and period_id=p_period) then
  insert into document_upload_requests(store_id,request_key,payload_hash,document_id)
    values(p_store,p_key,p_payload,doc.id);
  return jsonb_build_object('document_id',doc.id,'period_id',p_period,'duplicate',true);
 end if;
 if found and (doc.doc_type<>p_type or doc.selected_supplier_id is distinct from p_supplier
     or doc.extraction_status in ('COMPLETED','SUCCESS')) then
  raise sqlstate 'PT409' using message='PHOTO_ALREADY_REGISTERED'; end if;
 if jsonb_typeof(p_edits) is distinct from 'array' or jsonb_typeof(p_draft->'lines') is distinct from 'array'
    or jsonb_array_length(p_edits)=0 or jsonb_array_length(p_edits)<>jsonb_array_length(p_draft->'lines') then
  raise sqlstate 'PT422' using message='REVIEW_LINE_COUNT'; end if;
 reg:=register_document(p_period,p_hash,p_path,p_filename,p_mime,p_size,p_type,p_key,p_payload);
 fields:=(p_draft-'_review_dates'-'_review_amounts')||coalesce(p_draft->'_review_amounts','{}'::jsonb)||coalesce(p_draft->'_review_dates','{}'::jsonb)||jsonb_build_object('supplier_id',p_supplier,'doc_type',p_type);
 for i in 0..jsonb_array_length(p_edits)-1 loop
  src:=p_draft->'lines'->i; edit:=p_edits->i;
  lines:=lines||jsonb_build_array(src||edit||jsonb_build_object('id',gen_random_uuid()));
 end loop;
 perform persist_extraction((reg->>'id')::uuid,fields,lines);
 -- Preserve the original machine reading and explicit human choices, including intentional nulls.
 update documents set metadata=metadata||jsonb_build_object(
   'photo_review',jsonb_build_object('draft',p_draft-'_review_dates'-'_review_amounts','amount_overrides',p_draft->'_review_amounts','confirmed_dates',p_draft->'_review_dates','confirmed_lines',p_edits,'supplier_id',p_supplier,
                                    'doc_type',p_type,'confirmed_at',now()))
 where id=(reg->>'id')::uuid;
 return jsonb_build_object('document_id',reg->>'id','period_id',p_period,'duplicate',false);
end $$;
