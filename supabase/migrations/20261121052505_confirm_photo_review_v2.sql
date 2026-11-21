-- Apply in the Database repository AFTER main AND db-workflow-bridge (20261121020330).
-- No deployment or DB writes are performed by adding this file.
begin;
do $$ begin
 if to_regprocedure('public.persist_extraction(uuid,jsonb,jsonb)') is null then
  raise exception 'Apply 20261121020330_workflow_api_bridge.sql before photo review';
 end if;
end $$;
create or replace function public.confirm_photo_review_v2(
 p_period uuid,p_store uuid,p_supplier uuid,p_hash text,p_filename text,p_path text,
 p_mime text,p_size int,p_key text,p_payload text,p_type text,p_draft jsonb,p_fields jsonb,
 p_edits jsonb,p_expected int,p_actor_label text,p_owner uuid)
returns jsonb language plpgsql security invoker set search_path=public as $$
declare
 reg jsonb; doc documents; per periods; src jsonb; edit jsonb; lines jsonb := '[]';
 fields jsonb; row_number int; previous document_upload_requests; source_index int;
begin
 if not exists(select 1 from stores where id=p_store and owner_user_id=p_owner) then
  raise sqlstate 'PT404' using message='STORE_NOT_FOUND'; end if;
 -- Match register_document: period first, then store advisory lock.
 select * into per from periods where id=p_period and store_id=p_store for update;
 if not found or per.supplier_id<>p_supplier then
  raise sqlstate 'PT422' using message='REVIEW_SCOPE_MISMATCH'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_store::text,0));
 if nullif(trim(p_actor_label),'') is null or nullif(p_key,'') is null
   or p_type not in ('DELIVERY','RECEIPT','INVOICE','CORRECTED_INVOICE') then
  raise sqlstate 'PT422' using message='INVALID_REVIEW'; end if;
 select * into previous from document_upload_requests where store_id=p_store and request_key=p_key;
 if found then
  if previous.payload_hash<>p_payload then raise sqlstate 'PT409' using message='KEY_REUSE'; end if;
  return jsonb_build_object('document_id',previous.document_id,'period_id',p_period,'duplicate',true,
                           'input_revision',per.input_revision);
 end if;
 perform assert_revision(per,p_expected);
 -- Re-review never mutates an existing extraction, its references or an approval snapshot.
 select * into doc from documents where store_id=p_store and file_hash=p_hash for update;
 if found then raise sqlstate 'PT409' using message='PHOTO_ALREADY_REGISTERED'; end if;
 if jsonb_typeof(p_edits) is distinct from 'array' or jsonb_typeof(p_draft->'lines') is distinct from 'array'
   or jsonb_typeof(p_fields) is distinct from 'object' then
  raise sqlstate 'PT422' using message='INVALID_REVIEW'; end if;
 if jsonb_array_length(p_edits) not between 1 and 300 then
  raise sqlstate 'PT422' using message='INVALID_REVIEW_LINES'; end if;
 reg:=register_document(p_period,p_hash,p_path,p_filename,p_mime,p_size,p_type,p_key,p_payload);
 fields:=p_fields||jsonb_build_object('supplier_id',p_supplier,'doc_type',p_type,
  'agreement_source_location',case when nullif(p_fields->>'agreement_text','') is not null
    then jsonb_build_object('page',1,'row',null,'region',null) else null end);
 row_number:=0;
 for edit in select value from jsonb_array_elements(p_edits) loop
  row_number:=row_number+1;
  source_index:=(edit->>'source_row')::int;
  if source_index is not null and (source_index<1 or source_index>jsonb_array_length(p_draft->'lines')) then
   raise sqlstate 'PT422' using message='INVALID_SOURCE_ROW'; end if;
  src:=case when source_index is null then '{}'::jsonb else p_draft->'lines'->(source_index-1) end;
  lines:=lines||jsonb_build_array((edit-'source_row')||jsonb_build_object(
    'id',gen_random_uuid(),'source_location',
    case when source_index is null then jsonb_build_object('page',1,'row',null,'region',null)
    else src->'source_location' end));
 end loop;
 perform persist_extraction((reg->>'id')::uuid,fields,lines);
 update documents set metadata=metadata||jsonb_build_object('photo_review',jsonb_build_object(
   'draft',p_draft,'confirmed_fields',p_fields,'confirmed_lines',p_edits,
   'supplier_id',p_supplier,'confirmed_at',now(),'actor_label',p_actor_label,'owner_user_id',p_owner))
 where id=(reg->>'id')::uuid;
 select * into per from periods where id=p_period;
 return jsonb_build_object('document_id',reg->>'id','period_id',p_period,'duplicate',false,
                          'input_revision',per.input_revision);
end $$;
revoke all on function public.confirm_photo_review_v2(uuid,uuid,uuid,text,text,text,text,int,text,text,text,jsonb,jsonb,jsonb,int,text,uuid) from public,anon,authenticated;
grant execute on function public.confirm_photo_review_v2(uuid,uuid,uuid,text,text,text,text,int,text,text,text,jsonb,jsonb,jsonb,int,text,uuid) to service_role;
commit;
