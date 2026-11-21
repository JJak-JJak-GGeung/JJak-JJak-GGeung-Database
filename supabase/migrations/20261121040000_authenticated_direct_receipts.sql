begin;

alter table public.receipts add column evidence_text text
  check (evidence_text is null or length(trim(evidence_text)) between 1 and 2000);

create function public.save_direct_receipt(
  p_store uuid, p_period uuid, p_expected int, p_key text,
  p_body jsonb, p_actor_label text, p_actor uuid
) returns jsonb language plpgsql security invoker set search_path=public as $$
declare
  p periods;
  target doc_lines;
  prior receipts;
  req operation_requests;
  input jsonb;
  result jsonb;
  rid uuid;
  kind text := p_body->>'kind';
  target_id uuid := (p_body->>'target_id')::uuid;
  previous_id uuid := (p_body->>'supersedes_receipt_id')::uuid;
  qty_text text;
  receipt_unit text;
  proof text := nullif(trim(p_body->>'evidence_text'), '');
begin
  if not exists (select 1 from stores where id=p_store and owner_user_id=p_actor) then
    raise sqlstate 'PT404' using message='STORE_NOT_FOUND';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_store::text||':confirmation:'||coalesce(p_key,''),0));
  select * into p from periods where id=p_period and store_id=p_store for update;
  if not found then raise sqlstate 'PT404' using message='PERIOD_NOT_FOUND'; end if;
  input := jsonb_build_object('period_id',p_period,'expected_revision',p_expected,'body',p_body,
                              'actor_label',p_actor_label,'actor',p_actor);
  select * into req from operation_requests where store_id=p_store and operation='confirmation' and request_key=p_key;
  if found then
    if req.payload<>input then raise sqlstate 'PT409' using message='KEY_REUSE'; end if;
    return req.response;
  end if;
  perform assert_revision(p,p_expected);
  if nullif(trim(p_key),'') is null or nullif(trim(p_actor_label),'') is null or proof is null
      or length(proof)>2000 or kind is null or kind not in ('receipt_entry','line_correction') then
    raise sqlstate 'PT422' using message='INVALID_RECEIPT_ENTRY';
  end if;
  select l.* into target from doc_lines l
  join documents d on d.id=l.document_id and d.store_id=l.store_id
  join period_documents pd on pd.document_id=d.id and pd.store_id=d.store_id
  where l.id=target_id and l.store_id=p_store and pd.period_id=p_period
    and pd.status='ACTIVE' and d.doc_type='DELIVERY' and d.supplier_id=p.supplier_id;
  if not found then raise sqlstate 'PT422' using message='RECEIPT_TARGET_MISMATCH'; end if;

  if kind='line_correction' then
    select * into prior from receipts where id=previous_id and store_id=p_store and doc_line_id=target.id;
    if not found or exists(select 1 from receipts where supersedes_id=previous_id) then
      raise sqlstate 'PT422' using message='INVALID_RECEIPT_CORRECTION';
    end if;
    qty_text := p_body->'corrected_fields'->>'received_qty';
    receipt_unit := trim(p_body->'corrected_fields'->>'unit');
  else
    if previous_id is not null or exists (
        select 1 from receipts r where r.store_id=p_store and r.doc_line_id=target.id
        and not exists(select 1 from receipts n where n.supersedes_id=r.id)) then
      raise sqlstate 'PT409' using message='RECEIPT_ALREADY_CONFIRMED';
    end if;
    qty_text := p_body->>'received_qty';
    receipt_unit := trim(p_body->>'unit');
  end if;
  if qty_text is null or qty_text !~ '^[0-9]{1,18}([.][0-9]{1,9})?$'
      or nullif(receipt_unit,'') is null or length(receipt_unit)>60 then
    raise sqlstate 'PT422' using message='INVALID_RECEIPT_QUANTITY';
  end if;

  insert into receipts(store_id,doc_line_id,source_line_id,received_qty,unit,evidence_text,
                       confirmed_by,confirmed_at,actor_label,supersedes_id)
  values(p_store,target.id,prior.source_line_id,qty_text::numeric,receipt_unit,proof,p_actor,now(),p_actor_label,previous_id)
  returning id into rid;
  select * into p from periods where id=p_period;
  -- This immutable receipt event is itself the direct confirmation record.
  result := jsonb_build_object('confirmation_id',rid,'receipt_id',rid,'input_revision',p.input_revision);
  insert into operation_requests values(p_store,'confirmation',p_key,input,result,now());
  return result;
end $$;
revoke all on function public.save_direct_receipt(uuid,uuid,int,text,jsonb,text,uuid) from public,anon,authenticated;
grant execute on function public.save_direct_receipt(uuid,uuid,int,text,jsonb,text,uuid) to service_role;
create or replace function public.approve_period(p_store uuid,p_period uuid,p_expected int,p_key text,p_actor_label text,p_actor uuid default null)
returns jsonb language plpgsql security invoker set search_path=public as $$
declare p periods; req operation_requests; payload jsonb; result jsonb; approval settlement_versions;
 blockers jsonb:='[]'; total numeric; snap jsonb;
begin
 if p_actor is not null and not exists (select 1 from stores where id=p_store and owner_user_id=p_actor)
  then raise sqlstate 'PT404' using message='STORE_NOT_FOUND'; end if;
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
    (r.match_result<>'MATCHED' or fact_status='CONFLICTING' or confirmation_scope<>'RECEIPTS_INCLUDED'
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
  if exists(select 1 from period_documents pd join documents d on d.id=pd.document_id
   where pd.period_id=p_period and pd.status='ACTIVE' and d.doc_type='CORRECTED_INVOICE' and
    (d.supersedes_id is null or nullif(trim(d.agreement_text),'') is null or d.agreement_source_location is null
     or not exists(select 1 from confirmations c where c.period_id=p_period and c.kind='replacement' and c.document_id=d.id and c.target_id=d.supersedes_id)))
   then blockers:=blockers||'"UNCONFIRMED_REPLACEMENT"'::jsonb; end if;
  if exists(select 1 from recon_links l join recon_items r on r.id=l.recon_item_id
    left join doc_lines dl on dl.id=l.doc_line_id
    left join receipts rc on rc.id=l.receipt_id
    left join doc_lines source on source.id=rc.source_line_id
    where r.period_id=p_period and
     ((l.doc_line_id is not null and (dl.source_location is null or dl.source_location='{}'::jsonb))
      or (l.receipt_id is not null and ((rc.source_line_id is null and nullif(trim(rc.evidence_text), '') is null) or (rc.source_line_id is not null and (source.source_location is null or source.source_location='{}'::jsonb))))))
   then blockers:=blockers||'"MISSING_SOURCE_LOCATION"'::jsonb; end if;
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

commit;
