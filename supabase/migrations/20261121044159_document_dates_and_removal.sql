alter table public.documents add column trade_date date, add column issued_on date,
  add column quoted_on date, add column source_date_text text;
alter table public.doc_lines add column tax_amount_read bigint, add column line_date_text text;

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
 update documents set supplier_name_read=p_fields->>'supplier_name_read',
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
 fields:=(p_draft-'_review_dates')||coalesce(p_draft->'_review_dates','{}'::jsonb)||jsonb_build_object('supplier_id',p_supplier,'doc_type',p_type);
 for i in 0..jsonb_array_length(p_edits)-1 loop
  src:=p_draft->'lines'->i; edit:=p_edits->i;
  lines:=lines||jsonb_build_array(src||edit||jsonb_build_object('id',gen_random_uuid()));
 end loop;
 perform persist_extraction((reg->>'id')::uuid,fields,lines);
 -- Preserve the original machine reading and explicit human choices, including intentional nulls.
 update documents set metadata=metadata||jsonb_build_object(
   'photo_review',jsonb_build_object('draft',p_draft-'_review_dates','confirmed_dates',p_draft->'_review_dates','confirmed_lines',p_edits,'supplier_id',p_supplier,
                                    'doc_type',p_type,'confirmed_at',now()))
 where id=(reg->>'id')::uuid;
 return jsonb_build_object('document_id',reg->>'id','period_id',p_period,'duplicate',false);
end $$;

-- A removal receipt keeps retries safe without storing document contents.
create table public.document_removals (
  document_id uuid primary key, store_id uuid not null, period_id uuid not null,
  base_path text not null, retired_path text unique, created_at timestamptz not null default clock_timestamp(),
  purged_at timestamptz
);
alter table public.document_removals enable row level security;
revoke all on public.document_removals from public, anon, authenticated;
grant select, insert, update on public.document_removals to service_role;
create index document_removals_path_idx on public.document_removals(base_path, created_at desc);
create index document_removals_pending_idx on public.document_removals(period_id) where purged_at is null;

-- Never attach a file at a key for which a delayed Storage DELETE could still arrive.
create function public.check_original_path() returns trigger language plpgsql set search_path=public as $$
begin
 if new.source_mode='FILE' then
  perform pg_advisory_xact_lock(hashtextextended(new.storage_path,21));
  if exists(select from document_removals where retired_path=new.storage_path) then
   raise sqlstate 'PT409' using message='ORIGINAL_PATH_RETIRED';
  end if;
 end if;
 return new;
end $$;
create trigger check_original_path before insert or update of storage_path on public.documents
for each row execute function public.check_original_path();

create function public.remove_uploaded_document(p_owner uuid,p_period uuid,p_doc uuid) returns jsonb
language plpgsql security invoker set search_path=public as $$
declare s uuid; d documents; receipt document_removals; path_to_purge text; derived_ids uuid[];
begin
 select p.store_id into s from periods p join stores st on st.id=p.store_id
 where p.id=p_period and st.owner_user_id=p_owner for update of p;
 if not found then raise sqlstate 'PT404' using message='DOCUMENT_NOT_FOUND'; end if;
 perform pg_advisory_xact_lock(hashtextextended(s::text,0));
 select * into receipt from document_removals where document_id=p_doc and store_id=s and period_id=p_period;
 if found then return jsonb_build_object('path',case when receipt.purged_at is null then receipt.retired_path end); end if;
 select x.* into d from documents x join period_documents pd on pd.document_id=x.id
 where x.id=p_doc and x.store_id=s and pd.period_id=p_period for update of x;
 if not found then raise sqlstate 'PT404' using message='DOCUMENT_NOT_FOUND'; end if;
 if d.source_mode<>'FILE' or exists(select from period_documents where document_id=p_doc and period_id<>p_period)
 or exists(select from settlement_versions where store_id=s and snapshot @> jsonb_build_object('documents',jsonb_build_array(jsonb_build_object('id',p_doc))))
 then raise sqlstate 'PT409' using message='DOCUMENT_IN_USE'; end if;
 perform pg_advisory_xact_lock(hashtextextended(d.storage_path,21));
 -- Keep any explicit decisions, references and memos. Derived links alone can be recalculated.
 if exists(select from confirmations c where c.store_id=s and (c.document_id=p_doc or c.target_id=p_doc
  or exists(select from doc_lines l where l.document_id=p_doc and l.id in (c.target_id,c.source_line_id))
  or c.evidence_refs @> jsonb_build_array(jsonb_build_object('document_id',p_doc)))) then
  raise sqlstate 'PT409' using message='DOCUMENT_IN_USE';
 end if;
 select array_agg(r.id) into derived_ids from recon_items r where r.period_id=p_period
   and r.evidence_refs @> jsonb_build_array(jsonb_build_object('document_id',p_doc,'kind','DELIVERY'));
 if exists(select from transaction_memos m join recon_items r on r.id=m.transaction_id where r.period_id=p_period
    and r.evidence_refs @> jsonb_build_array(jsonb_build_object('document_id',p_doc))) then
  raise sqlstate 'PT409' using message='DOCUMENT_IN_USE';
 end if;
 delete from recon_links where doc_line_id in (select id from doc_lines where document_id=p_doc) or recon_item_id=any(derived_ids);
 delete from recon_items where id=any(derived_ids);
 delete from document_upload_requests where document_id=p_doc;
 delete from period_documents where document_id=p_doc;
 delete from doc_lines where document_id=p_doc;
 delete from documents where id=p_doc;
 if not exists(select from documents where storage_path=d.storage_path) then path_to_purge:=d.storage_path; end if;
 insert into document_removals(document_id,store_id,period_id,base_path,retired_path,purged_at)
 values(p_doc,s,p_period,split_part(d.storage_path,'~',1),path_to_purge,case when path_to_purge is null then now() end);
 return jsonb_build_object('path',path_to_purge);
exception when foreign_key_violation then
 raise sqlstate 'PT409' using message='DOCUMENT_IN_USE';
end $$;
revoke all on function public.check_original_path(), public.remove_uploaded_document(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.check_original_path(), public.remove_uploaded_document(uuid,uuid,uuid) to service_role;

create function public.correct_document_trade_date(p_owner uuid,p_period uuid,p_doc uuid,p_expected date,p_date date)
returns void language plpgsql security invoker set search_path=public as $$
declare d documents;
begin
 perform 1 from periods p join stores s on s.id=p.store_id where p.id=p_period and s.owner_user_id=p_owner for update of p;
 if not found then raise sqlstate 'PT404' using message='DOCUMENT_NOT_FOUND'; end if;
 select x.* into d from documents x join period_documents pd on pd.document_id=x.id
 where pd.period_id=p_period and x.id=p_doc and x.source_mode='FILE' for update of x;
 if not found then raise sqlstate 'PT404' using message='DOCUMENT_NOT_FOUND'; end if;
 if d.trade_date is not distinct from p_date then return; end if;
 if d.trade_date is distinct from p_expected then raise sqlstate 'PT409' using message='STALE_REVISION'; end if;
 if exists(select from settlement_versions where store_id=d.store_id and snapshot @> jsonb_build_object(
  'documents',jsonb_build_array(jsonb_build_object('id',d.id)))) then raise sqlstate 'PT409' using message='APPROVED_DOCUMENT'; end if;
 update documents set trade_date=p_date, metadata=metadata||jsonb_build_object('trade_date_history',
  coalesce(metadata->'trade_date_history','[]'::jsonb)||jsonb_build_array(jsonb_build_object(
  'previous',d.trade_date,'confirmed',p_date,'at',now()))) where id=p_doc;
end $$;
revoke all on function public.correct_document_trade_date(uuid,uuid,uuid,date,date) from public,anon,authenticated;
grant execute on function public.correct_document_trade_date(uuid,uuid,uuid,date,date) to service_role;
