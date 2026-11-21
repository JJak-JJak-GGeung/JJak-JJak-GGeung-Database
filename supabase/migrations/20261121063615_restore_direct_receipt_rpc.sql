-- Reconcile deployments that applied document migrations without the direct-receipt RPC.

alter table public.receipts add column if not exists evidence_text text
  check (evidence_text is null or length(trim(evidence_text)) between 1 and 2000);

create or replace function public.save_direct_receipt(
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
