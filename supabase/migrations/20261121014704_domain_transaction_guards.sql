begin;
create or replace function public.approve_period(p_store uuid,p_period uuid,p_expected int,p_key text,p_actor_label text,p_actor uuid default null)
returns jsonb language plpgsql security invoker set search_path=public as $$
declare p periods; req operation_requests; payload jsonb; result jsonb; approval settlement_versions;
 blockers jsonb:='[]'; total numeric; snap jsonb;
begin
 perform pg_advisory_xact_lock(hashtextextended(p_store::text||':approval:'||coalesce(p_key,''),0));
 if nullif(trim(p_actor_label),'') is null or nullif(p_key,'') is null then raise sqlstate 'PT422' using message='INVALID_ACTOR_OR_KEY'; end if;
 select * into p from periods where id=p_period and store_id=p_store for update;
 if not found then raise sqlstate 'PT404' using message='PERIOD_NOT_FOUND'; end if;
 payload:=jsonb_build_object('period_id',p_period,'expected_revision',p_expected,'actor',p_actor,'actor_label',p_actor_label);
 select * into req from operation_requests where store_id=p_store and operation='approval' and request_key=p_key;
 if found then
  if req.payload<>payload then raise sqlstate 'PT409' using message='KEY_REUSE'; end if;
  return req.response;
 end if;
 perform assert_revision(p,p_expected);
 select * into approval from settlement_versions where period_id=p_period and input_revision=p_expected;
 if not found then
  if p.reconciled_revision is distinct from p.input_revision then blockers:=blockers||'"RECONCILIATION_STALE"'::jsonb; end if;
  if not exists(select 1 from recon_items where period_id=p_period) then blockers:=blockers||'"MISSING_TRANSACTIONS"'::jsonb; end if;
  if exists(select 1 from recon_items r where r.period_id=p_period and
    (r.match_result<>'MATCHED' or confirmation_scope<>'RECEIPTS_INCLUDED'
     or received_qty is null or billed_qty is null or unit is null
     or billed_qty<>received_qty or check_amount is distinct from 0::numeric
     or billed_amount is null or billed_amount<0 or billed_amount<>trunc(billed_amount)
     or r.blockers<>'[]'::jsonb or work_status in ('ON_HOLD','CARRIED_OVER','NEEDS_INFO','WAITING_REPLY')))
  then blockers:=blockers||'"UNRESOLVED_TRANSACTION"'::jsonb; end if;
  if exists(select 1 from period_documents pd join documents d on d.id=pd.document_id
    where pd.period_id=p_period and pd.status<>'REPLACED' and
     (pd.status<>'ACTIVE' or d.supplier_id is distinct from p.supplier_id
      or (d.source_mode='FILE' and d.extraction_status not in ('COMPLETED','SUCCESS'))))
  then blockers:=blockers||'"UNRESOLVED_DOCUMENT"'::jsonb; end if;
  if exists(select 1 from questions q where
   (q.period_id=p_period or q.recon_item_id in (select id from recon_items where period_id=p_period))
   and q.resolved_at is null) then blockers:=blockers||'"OPEN_QUESTION"'::jsonb; end if;
  if exists(select 1 from recon_items r where r.period_id=p_period and
   (not exists(select 1 from recon_links l join receipts rc on rc.id=l.receipt_id
     where l.recon_item_id=r.id and rc.confirmed_at is not null and not exists(select 1 from receipts next where next.supersedes_id=rc.id))
    or not exists(select 1 from recon_links l join doc_lines dl on dl.id=l.doc_line_id join documents d on d.id=dl.document_id
     where l.recon_item_id=r.id and d.doc_type='DELIVERY')
    or not exists(select 1 from recon_links l join doc_lines dl on dl.id=l.doc_line_id join documents d on d.id=dl.document_id
     join period_documents pd on pd.document_id=d.id and pd.period_id=p_period
     where l.recon_item_id=r.id and d.doc_type in ('INVOICE','CORRECTED_INVOICE') and pd.status='ACTIVE')))
  then blockers:=blockers||'"MISSING_EVIDENCE"'::jsonb; end if;
  if blockers<>'[]'::jsonb then raise sqlstate 'PT422' using message='BLOCKED',detail=jsonb_build_object('blockers',blockers)::text; end if;
  select sum(billed_amount) into total from recon_items where period_id=p_period;
  snap:=jsonb_build_object(
   'period',to_jsonb(p),'approved_amount',total,'payment_status','UNCONFIRMED',
   'documents',coalesce((select jsonb_agg(to_jsonb(d)||jsonb_build_object('period_status',pd.status)) from documents d join period_documents pd on pd.document_id=d.id where pd.period_id=p_period),'[]'),
   'lines',coalesce((select jsonb_agg(to_jsonb(l)) from doc_lines l join period_documents pd on pd.document_id=l.document_id where pd.period_id=p_period),'[]'),
   'items',coalesce((select jsonb_agg(to_jsonb(r)) from recon_items r where r.period_id=p_period),'[]'),
   'links',coalesce((select jsonb_agg(to_jsonb(l)) from recon_links l join recon_items r on r.id=l.recon_item_id where r.period_id=p_period),'[]'),
   'receipts',coalesce((select jsonb_agg(to_jsonb(rc)) from receipts rc where rc.doc_line_id in (select l.id from doc_lines l join period_documents pd on pd.document_id=l.document_id where pd.period_id=p_period)),'[]'),
   'confirmations',coalesce((select jsonb_agg(to_jsonb(c)) from confirmations c where c.period_id=p_period),'[]'),
   'memos',coalesce((select jsonb_agg(to_jsonb(m)) from transaction_memos m join recon_items r on r.id=m.transaction_id where r.period_id=p_period),'[]'),
   'actor_label',p_actor_label,'actor',p_actor,'approved_at',now());
  insert into settlement_versions(store_id,period_id,version_no,input_revision,confirmation_scope,confirmed_total,carried_total,held_total,snapshot,approved_by,approved_at,request_key,actor_label)
  values(p_store,p_period,(select coalesce(max(version_no),0)+1 from settlement_versions where period_id=p_period),p_expected,'RECEIPTS_INCLUDED',total,0,0,snap,p_actor,now(),p_key,p_actor_label)
  returning * into approval;
  update periods set status='APPROVED' where id=p_period;
 end if;
 result:=jsonb_build_object('approval_id',approval.id,'period_id',p_period,'input_revision',approval.input_revision,'version_no',approval.version_no,'approved_amount',approval.confirmed_total);
 insert into operation_requests values(p_store,'approval',p_key,payload,result,now());
 return result;
end $$;
create or replace function public.save_confirmation(p_store uuid,p_period uuid,p_expected int,p_key text,p_body jsonb,p_actor_label text,p_actor uuid default null)
returns jsonb language plpgsql security invoker set search_path=public as $$
declare p periods; req operation_requests; payload jsonb; result jsonb; cid uuid;
 kind text:=p_body->>'kind'; src doc_lines; target doc_lines; doc documents; previous documents;
 target_id uuid:=(p_body->>'target_id')::uuid; evidence jsonb:=p_body->'evidence_refs'; e jsonb; receipt uuid;
begin
 perform pg_advisory_xact_lock(hashtextextended(p_store::text||':confirmation:'||coalesce(p_key,''),0));
 select * into p from periods where id=p_period and store_id=p_store for update;
 if not found then raise sqlstate 'PT404' using message='PERIOD_NOT_FOUND'; end if;
 if nullif(trim(p_actor_label),'') is null or kind not in ('receipt_link','replacement','line_correction') or target_id is null
  or jsonb_typeof(evidence) is distinct from 'array' then raise sqlstate 'PT422' using message='INVALID_CONFIRMATION'; end if;
 if jsonb_array_length(evidence)=0 then raise sqlstate 'PT422' using message='MISSING_EVIDENCE'; end if;
 payload:=jsonb_build_object('period_id',p_period,'expected_revision',p_expected,'body',p_body,'actor_label',p_actor_label,'actor',p_actor);
 select * into req from operation_requests where store_id=p_store and operation='confirmation' and request_key=p_key;
 if found then
  if req.payload<>payload then raise sqlstate 'PT409' using message='KEY_REUSE'; end if;
  return req.response;
 end if;
 perform assert_revision(p,p_expected);
 for e in select value from jsonb_array_elements(evidence) loop
  if not exists(select 1 from period_documents pd where pd.period_id=p_period and pd.store_id=p_store and pd.document_id=(e->>'document_id')::uuid)
    or e->'source_location' is null or e->'source_location'='null'::jsonb then raise sqlstate 'PT422' using message='INVALID_EVIDENCE'; end if;
  if e->>'line_id' is not null and not exists(select 1 from doc_lines where id=(e->>'line_id')::uuid and document_id=(e->>'document_id')::uuid and store_id=p_store)
    then raise sqlstate 'PT422' using message='INVALID_EVIDENCE_LINE'; end if;
 end loop;
 if kind in ('receipt_link','line_correction') then
  select * into src from doc_lines where id=(p_body->>'source_line_id')::uuid and store_id=p_store;
  if not found or not exists(select 1 from period_documents where period_id=p_period and document_id=src.document_id) then raise sqlstate 'PT422' using message='SOURCE_SCOPE_MISMATCH'; end if;
 end if;
 if kind='receipt_link' then
  select * into target from doc_lines where id=target_id and store_id=p_store;
  if not found or not exists(select 1 from period_documents where period_id=p_period and document_id=target.document_id)
   or not exists(select 1 from documents where id=target.document_id and doc_type='DELIVERY')
   or not exists(select 1 from documents where id=src.document_id and doc_type='RECEIPT')
   then raise sqlstate 'PT422' using message='RECEIPT_TARGET_MISMATCH'; end if;
  if coalesce(src.qty_corrected,src.qty_read) is null or src.raw_unit is null then raise sqlstate 'PT422' using message='MISSING_RECEIPT_QUANTITY'; end if;
  if exists(select 1 from receipts r where r.source_line_id=src.id and not exists(select 1 from receipts n where n.supersedes_id=r.id))
   and p_body->>'supersedes_receipt_id' is null then raise sqlstate 'PT409' using message='RECEIPT_ALREADY_CONFIRMED'; end if;
  insert into receipts(store_id,doc_line_id,source_line_id,received_qty,unit,confirmed_by,confirmed_at,actor_label,supersedes_id)
  values(p_store,target.id,src.id,coalesce(src.qty_corrected,src.qty_read),src.raw_unit,p_actor,now(),p_actor_label,(p_body->>'supersedes_receipt_id')::uuid)
  returning id into receipt;
 elsif kind='line_correction' then
  if target_id<>src.id or jsonb_typeof(p_body->'corrected_fields') is distinct from 'object'
   or p_body->'corrected_fields'='{}'::jsonb or exists(select 1 from jsonb_object_keys(p_body->'corrected_fields') k where k not in ('qty_corrected','unit_price_corrected','amount_corrected'))
   then raise sqlstate 'PT422' using message='INVALID_CORRECTION'; end if;
  update doc_lines set
   qty_corrected=case when p_body->'corrected_fields' ? 'qty_corrected' then (p_body->'corrected_fields'->>'qty_corrected')::numeric else qty_corrected end,
   unit_price_corrected=case when p_body->'corrected_fields' ? 'unit_price_corrected' then (p_body->'corrected_fields'->>'unit_price_corrected')::numeric else unit_price_corrected end,
   amount_corrected=case when p_body->'corrected_fields' ? 'amount_corrected' then (p_body->'corrected_fields'->>'amount_corrected')::numeric else amount_corrected end,
   corrected_by=p_actor,corrected_at=now() where id=src.id;
 elsif kind='replacement' then
  select * into doc from documents where id=(p_body->>'document_id')::uuid and store_id=p_store;
  select * into previous from documents where id=target_id and store_id=p_store;
  if doc.id is null or previous.id is null or doc.id=previous.id or doc.doc_type<>'CORRECTED_INVOICE'
    or previous.doc_type not in ('INVOICE','CORRECTED_INVOICE')
    or doc.supplier_id is distinct from p.supplier_id or previous.supplier_id is distinct from p.supplier_id
    or doc.period_start is distinct from previous.period_start or doc.period_end is distinct from previous.period_end
    or doc.period_start is distinct from p.period_start or doc.period_end is distinct from p.period_end
    or not exists(select 1 from period_documents where period_id=p_period and document_id=doc.id)
    or not exists(select 1 from period_documents where period_id=p_period and document_id=previous.id)
   then raise sqlstate 'PT422' using message='REPLACEMENT_SCOPE_MISMATCH'; end if;
  update documents set supersedes_id=previous.id where id=doc.id;
  update period_documents set status='REPLACED' where period_id=p_period and document_id=previous.id;
 end if;
 insert into confirmations(store_id,period_id,kind,source_line_id,document_id,target_id,evidence_refs,corrected_fields,actor_label,confirmed_by)
 values(p_store,p_period,kind,src.id,doc.id,target_id,evidence,p_body->'corrected_fields',p_actor_label,p_actor) returning id into cid;
 select * into p from periods where id=p_period;
 result:=jsonb_build_object('confirmation_id',cid,'receipt_id',receipt,'input_revision',p.input_revision);
 insert into operation_requests values(p_store,'confirmation',p_key,payload,result,now());
 return result;
end $$;
create or replace function public.save_confirmed_memo(p_store uuid,p_transaction uuid,p_text text,p_mode document_source_mode,p_expected int,p_key text,p_actor_label text,p_actor uuid default null)
returns jsonb language plpgsql security invoker set search_path=public as $$
declare p periods; r recon_items; req operation_requests; payload jsonb; result jsonb; doc uuid; memo uuid;
begin
 perform pg_advisory_xact_lock(hashtextextended(p_store::text||':memo:'||coalesce(p_key,''),0));
 select * into r from recon_items where id=p_transaction and store_id=p_store;
 if not found then raise sqlstate 'PT404' using message='TRANSACTION_NOT_FOUND'; end if;
 select * into p from periods where id=r.period_id and store_id=p_store for update;
 if nullif(trim(p_text),'') is null or nullif(trim(p_actor_label),'') is null or p_mode not in ('TYPED_TEXT','VOICE_MEMO') then raise sqlstate 'PT422' using message='INVALID_MEMO'; end if;
 payload:=jsonb_build_object('transaction_id',p_transaction,'text',p_text,'mode',p_mode,'expected_revision',p_expected,'actor_label',p_actor_label,'actor',p_actor);
 select * into req from operation_requests where store_id=p_store and operation='memo' and request_key=p_key;
 if found then
  if req.payload<>payload then raise sqlstate 'PT409' using message='KEY_REUSE'; end if;
  return req.response;
 end if;
 perform assert_revision(p,p_expected);
 insert into documents(store_id,supplier_id,doc_type,source_mode,source_text,created_by,metadata)
 values(p_store,p.supplier_id,'OWNER_CALL_MEMO',p_mode,p_text,p_actor,jsonb_build_object('actor_label',p_actor_label)) returning id into doc;
 insert into period_documents(period_id,document_id) values(p.id,doc);
 insert into transaction_memos(store_id,transaction_id,document_id,confirmed_text,source_mode,actor_label,confirmed_by)
 values(p_store,p_transaction,doc,p_text,p_mode,p_actor_label,p_actor) returning id into memo;
 update recon_items set fact_status='CONFLICTING',work_status='WAITING_REPLY',blockers='["CONFIRMED_MEMO_REQUIRES_REVIEW"]' where id=p_transaction;
 select * into p from periods where id=p.id;
 result:=jsonb_build_object('memo_id',memo,'transaction_id',p_transaction,'input_revision',p.input_revision);
 insert into operation_requests values(p_store,'memo',p_key,payload,result,now());
 return result;
end $$;

create function public.preserve_original_identity() returns trigger language plpgsql security invoker set search_path=public as $$
begin
 if old.source_mode='FILE' and (new.store_id,new.storage_path,new.file_hash,new.byte_size,new.mime_type,new.source_mode)
   is distinct from (old.store_id,old.storage_path,old.file_hash,old.byte_size,old.mime_type,old.source_mode)
 then raise exception 'IMMUTABLE_ORIGINAL'; end if;
 if old.source_mode<>'FILE' and (new.source_text,new.source_mode,new.store_id) is distinct from (old.source_text,old.source_mode,old.store_id)
 then raise exception 'IMMUTABLE_CONFIRMED_TEXT'; end if;
 return new;
end $$;
create trigger a_original_identity before update on public.documents for each row execute function public.preserve_original_identity();
create function public.period_scope_changed() returns trigger language plpgsql security invoker set search_path=public as $$
begin
 if (new.store_id,new.supplier_id,new.period_start,new.period_end,new.payment_due_on)
   is distinct from (old.store_id,old.supplier_id,old.period_start,old.period_end,old.payment_due_on) then
  if (new.store_id,new.supplier_id) is distinct from (old.store_id,old.supplier_id)
   and exists(select 1 from period_documents where period_id=old.id) then raise exception 'PERIOD_SCOPE_IN_USE'; end if;
  new.input_revision:=old.input_revision+1;
  new.reconciled_revision:=null;
  new.status:='REVIEWING';
 end if;
 return new;
end $$;
create trigger period_scope_guard before update on public.periods for each row execute function public.period_scope_changed();
revoke all on function public.preserve_original_identity(),public.period_scope_changed() from public,anon,authenticated;
grant execute on function public.preserve_original_identity(),public.period_scope_changed() to service_role;
commit;
