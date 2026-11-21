begin;
alter table public.recon_items add column if not exists evidence_refs jsonb not null default '[]';

create function public.read_period_state(p_period uuid)
returns jsonb language sql stable security invoker set search_path=public as $$
 select jsonb_build_object(
 'period',to_jsonb(p),
 'supplier',(select to_jsonb(s) from suppliers s where s.id=p.supplier_id),
 'documents',coalesce((select jsonb_agg(to_jsonb(d)||jsonb_build_object('link_status',pd.status))
  from documents d join period_documents pd on pd.document_id=d.id where pd.period_id=p.id),'[]'),
 'lines',coalesce((select jsonb_agg(to_jsonb(l)) from doc_lines l join period_documents pd on pd.document_id=l.document_id where pd.period_id=p.id),'[]'),
 'receipts',coalesce((select jsonb_agg(to_jsonb(r)) from receipts r where r.doc_line_id in
   (select l.id from doc_lines l join period_documents pd on pd.document_id=l.document_id where pd.period_id=p.id)),'[]'),
 'confirmations',coalesce((select jsonb_agg(to_jsonb(c)) from confirmations c where c.period_id=p.id),'[]'),
 'memos',coalesce((select jsonb_agg(to_jsonb(m)) from transaction_memos m join recon_items r on r.id=m.transaction_id where r.period_id=p.id),'[]'),
 'approvals',coalesce((select jsonb_agg(to_jsonb(a)) from settlement_versions a where a.period_id=p.id),'[]'),
 'result',(select output from agent_runs where store_id=p.store_id and period_id=p.id and role='RECONCILE' and input_revision=p.input_revision and status='COMPLETED' order by ended_at desc limit 1)
 ) from periods p where p.id=p_period;
$$;

create function public.persist_extraction(p_document uuid,p_fields jsonb,p_lines jsonb)
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
  doc_no=p_fields->>'doc_no',doc_date=(p_fields->>'doc_date')::date,
  period_start=(p_fields->>'period_start')::date,period_end=(p_fields->>'period_end')::date,
  payment_due_on=(p_fields->>'payment_due_on')::date,replaces_doc_no=p_fields->>'replaces_doc_no',
  agreement_text=p_fields->>'agreement_text',agreement_source_location=nullif(p_fields->'agreement_source_location','null'),
  metadata=metadata||jsonb_build_object('doc_type_read',p_fields->>'doc_type'),
  extraction_status='COMPLETED' where id=p_document;
 for item in select value from jsonb_array_elements(p_lines) loop
  lid:=(item->>'id')::uuid;
  insert into doc_lines(id,store_id,document_id,delivery_no,delivery_date,raw_name,raw_spec,raw_unit,qty_read,unit_price_read,amount_read,source_location,extraction_status)
  values(lid,d.store_id,d.id,item->>'delivery_no',(item->>'delivery_date')::date,item->>'item',item->>'spec',item->>'unit',
   (item->>'qty_read')::numeric,(item->>'unit_price_read')::numeric,(item->>'amount_read')::numeric,item->'source_location','COMPLETED');
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

create function public.publish_reconciliation(p_period uuid,p_expected int,p_items jsonb,p_links jsonb,p_result jsonb)
returns jsonb language plpgsql security invoker set search_path=public as $$
declare p periods; item jsonb; link jsonb; rid uuid; result jsonb;
begin
 select * into p from periods where id=p_period for update;
 if not found then raise sqlstate 'PT404' using message='PERIOD_NOT_FOUND'; end if;
 perform assert_revision(p,p_expected);
 if p.status='APPROVED' then
  select output into result from agent_runs where period_id=p.id and role='RECONCILE' and input_revision=p_expected and status='COMPLETED' limit 1;
  return coalesce(result,p_result);
 end if;
 for item in select value from jsonb_array_elements(p_items) loop
  rid:=(item->>'transaction_id')::uuid;
  if exists(select 1 from recon_items where id=rid and (period_id<>p.id or store_id<>p.store_id)) then raise exception 'TRANSACTION_SCOPE_MISMATCH'; end if;
  insert into recon_items(id,store_id,period_id,delivery_no,delivery_date,match_result,fact_status,confirmation_scope,work_status,
    declared_qty,billed_qty,received_qty,unit,delta_qty,check_amount,billed_amount,blockers,evidence_refs)
  values(rid,p.store_id,p.id,item->>'delivery_no',(item->>'delivery_date')::date,(item->>'match_result')::match_result,
    (item->>'fact_status')::fact_status,(p_result->>'confirmation_scope')::confirmation_scope,(item->>'work_status')::work_status,
    (item->>'declared_qty')::numeric,(item->>'billed_qty')::numeric,(item->>'received_qty')::numeric,item->>'unit',
    (item->>'delta_qty')::numeric,(item->>'check_amount')::numeric,(item->>'billed_amount')::numeric,
    coalesce(item->'blockers','[]'),coalesce(item->'evidence_refs','[]'))
  on conflict(id) do update set
    delivery_no=excluded.delivery_no,delivery_date=excluded.delivery_date,match_result=excluded.match_result,
    fact_status=excluded.fact_status,confirmation_scope=excluded.confirmation_scope,work_status=excluded.work_status,
    declared_qty=excluded.declared_qty,billed_qty=excluded.billed_qty,received_qty=excluded.received_qty,unit=excluded.unit,
    delta_qty=excluded.delta_qty,check_amount=excluded.check_amount,billed_amount=excluded.billed_amount,
    blockers=excluded.blockers,evidence_refs=excluded.evidence_refs;
 end loop;
 -- A previously known transaction cannot silently disappear from the approval scope.
 update recon_items set match_result='MISSING_DATA',blockers='["MISSING_DELIVERY_SOURCE"]'
 where period_id=p.id and id not in (select (value->>'transaction_id')::uuid from jsonb_array_elements(p_items));
 delete from recon_links where recon_item_id in (select id from recon_items where period_id=p.id);
 for link in select value from jsonb_array_elements(p_links) loop
  insert into recon_links(store_id,recon_item_id,doc_line_id,receipt_id,link_type)
  values(p.store_id,(link->>'transaction_id')::uuid,(link->>'doc_line_id')::uuid,(link->>'receipt_id')::uuid,link->>'kind')
  on conflict do nothing;
 end loop;
 update periods set reconciled_revision=input_revision where id=p.id;
 insert into agent_runs(store_id,period_id,role,input_revision,request_key,status,output,started_at,ended_at)
 values(p.store_id,p.id,'RECONCILE',p_expected,p.id::text||':'||p_expected::text,'COMPLETED',p_result,now(),now())
 on conflict(store_id,role,request_key) do update set output=excluded.output,status='COMPLETED',ended_at=now();
 return p_result;
end $$;
revoke all on function public.read_period_state(uuid),public.persist_extraction(uuid,jsonb,jsonb),public.publish_reconciliation(uuid,int,jsonb,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.read_period_state(uuid),public.persist_extraction(uuid,jsonb,jsonb),public.publish_reconciliation(uuid,int,jsonb,jsonb,jsonb) to service_role;
commit;
