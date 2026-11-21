-- Confirm the displayed photo draft, the chosen supplier and its period in one transaction.
create function public.confirm_photo_review(
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
    and doc.metadata->'photo_review'->'confirmed_lines'=p_edits and
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
 fields:=p_draft||jsonb_build_object('supplier_id',p_supplier,'doc_type',p_type);
 for i in 0..jsonb_array_length(p_edits)-1 loop
  src:=p_draft->'lines'->i; edit:=p_edits->i;
  lines:=lines||jsonb_build_array(src||edit||jsonb_build_object('id',gen_random_uuid()));
 end loop;
 perform persist_extraction((reg->>'id')::uuid,fields,lines);
 -- Preserve the original machine reading and explicit human choices, including intentional nulls.
 update documents set metadata=metadata||jsonb_build_object(
   'photo_review',jsonb_build_object('draft',p_draft,'confirmed_lines',p_edits,'supplier_id',p_supplier,
                                    'doc_type',p_type,'confirmed_at',now()))
 where id=(reg->>'id')::uuid;
 return jsonb_build_object('document_id',reg->>'id','period_id',p_period,'duplicate',false);
end $$;
revoke all on function public.confirm_photo_review(uuid,uuid,uuid,text,text,text,text,int,text,text,text,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.confirm_photo_review(uuid,uuid,uuid,text,text,text,text,int,text,text,text,jsonb,jsonb) to service_role;
