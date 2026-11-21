-- Apply after 20261121055526_statement_amounts.sql.
begin;

alter table public.doc_lines
  add column item_code text,
  add column origin text,
  add column lot_no text,
  add column line_note text,
  add column supply_amount_read bigint,
  add column discount_amount_read bigint,
  add column line_total_read bigint;

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
  insert into doc_lines(id,store_id,document_id,delivery_no,delivery_date,raw_name,raw_spec,raw_unit,qty_read,unit_price_read,amount_read,tax_amount_read,line_date_text,
    item_code,origin,lot_no,line_note,supply_amount_read,discount_amount_read,line_total_read,source_location,extraction_status)
  values(lid,d.store_id,d.id,item->>'delivery_no',(item->>'delivery_date')::date,item->>'item',item->>'spec',item->>'unit',
   (item->>'qty_read')::numeric,(item->>'unit_price_read')::numeric,(item->>'amount_read')::numeric,(item->>'tax_amount_read')::bigint,item->>'line_date_text',
   item->>'item_code',item->>'origin',item->>'lot_no',item->>'line_note',
   (item->>'supply_amount_read')::bigint,(item->>'discount_amount_read')::bigint,
   (item->>'line_total_read')::bigint,item->'source_location','COMPLETED');
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

commit;
