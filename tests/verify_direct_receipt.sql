-- Runs against a disposable database after applying all migrations.
begin;
do $$
declare
  owner uuid := gen_random_uuid();
  p periods;
  d uuid;
  line uuid := gen_random_uuid();
  first_body jsonb;
  correction jsonb;
  saved jsonb;
  changed jsonb;
  approval jsonb;
  invoice uuid;
  invoice_line uuid := gen_random_uuid();
  transaction_id uuid := gen_random_uuid();
  revision int;
begin
  select * into strict p from periods limit 1;
  update stores set owner_user_id=owner where id=p.store_id;
  d := (register_document(p.id,'qa-direct-hash','qa/direct','test.png','image/png',
                          120,'DELIVERY','qa-doc','qa-doc')->>'id')::uuid;
  perform persist_extraction(d, jsonb_build_object('supplier_id',p.supplier_id,'doc_type','DELIVERY'),
    jsonb_build_array(jsonb_build_object('id',line,'delivery_no','QA-1','item','sample','unit','kg',
      'qty_read','5','source_location',jsonb_build_object('page',1,'row',1))));
  select input_revision into revision from periods where id=p.id;
  first_body := jsonb_build_object('kind','receipt_entry','target_id',line,'received_qty','0',
                                   'unit','kg','evidence_text','점주 계량 기록');
  begin
    perform save_direct_receipt(p.store_id,p.id,revision,'manual-1',first_body,'점주',gen_random_uuid());
    raise exception 'wrong owner accepted';
  exception when sqlstate 'PT404' then null;
  end;
  saved := save_direct_receipt(p.store_id,p.id,revision,'manual-1',first_body,'점주',owner);
  if saved is distinct from save_direct_receipt(p.store_id,p.id,revision,'manual-1',first_body,'점주',owner) then
    raise exception 'request replay changed receipt';
  end if;
  if (saved->>'input_revision')::int <= revision or not exists(
      select 1 from receipts where id=(saved->>'receipt_id')::uuid and received_qty=0
        and evidence_text='점주 계량 기록' and source_line_id is null and confirmed_by=owner) then
    raise exception 'receipt or revision not saved';
  end if;
  begin
    perform save_direct_receipt(p.store_id,p.id,revision,'manual-2',first_body,'점주',owner);
    raise exception 'stale revision accepted';
  exception when sqlstate 'PT409' then null;
  end;
  correction := jsonb_build_object('kind','line_correction','target_id',line,
    'supersedes_receipt_id',saved->>'receipt_id','evidence_text','점주 재계량',
    'corrected_fields',jsonb_build_object('received_qty','5','unit','kg'));
  changed := save_direct_receipt(p.store_id,p.id,(saved->>'input_revision')::int,
                                'manual-fix',correction,'점주',owner);
  if not exists (select 1 from receipts where id=(changed->>'receipt_id')::uuid
      and supersedes_id=(saved->>'receipt_id')::uuid and received_qty=5 and evidence_text='점주 재계량')
    or not exists (select 1 from receipts where id=(saved->>'receipt_id')::uuid and received_qty=0) then
    raise exception 'receipt correction history missing';
  end if;
  invoice := (register_document(p.id,'qa-invoice-hash','qa/invoice','invoice.png','image/png',
                               120,'INVOICE','qa-invoice','qa-invoice')->>'id')::uuid;
  perform persist_extraction(invoice, jsonb_build_object('supplier_id',p.supplier_id,'doc_type','INVOICE'),
    jsonb_build_array(jsonb_build_object('id',invoice_line,'delivery_no','QA-1','item','sample','unit','kg',
      'qty_read','5','source_location',jsonb_build_object('page',1,'row',1))));
  select input_revision into revision from periods where id=p.id;
  perform publish_reconciliation(p.id, revision,
    jsonb_build_array(jsonb_build_object('transaction_id',transaction_id,'delivery_no','QA-1',
      'match_result','MATCHED','fact_status','OWNER_CONFIRMED','work_status','OPEN','unit','kg',
      'declared_qty',5,'billed_qty',5,'received_qty',5,'delta_qty',0,'check_amount',0,'billed_amount',100000)),
    jsonb_build_array(jsonb_build_object('transaction_id',transaction_id,'doc_line_id',line,'kind','DELIVERY'),
      jsonb_build_object('transaction_id',transaction_id,'doc_line_id',invoice_line,'kind','INVOICE'),
      jsonb_build_object('transaction_id',transaction_id,'receipt_id',changed->>'receipt_id','kind','RECEIPT')),
    '{"confirmation_scope":"RECEIPTS_INCLUDED"}');
  approval := approve_period(p.store_id,p.id,revision,'qa-approve','점주',owner);
  if (approval->>'approved_amount')::int <> 100000 or
    approval->>'approval_id' is distinct from
      (approve_period(p.store_id,p.id,revision,'qa-approve-retry','점주',owner)->>'approval_id') or
    not exists (select 1 from settlement_versions sv, jsonb_array_elements(sv.snapshot->'receipts') r
      where sv.id=(approval->>'approval_id')::uuid and sv.approved_by=owner
        and r->>'id'=changed->>'receipt_id' and r->>'evidence_text'='점주 재계량') then
    raise exception 'approval or immutable direct evidence missing';
  end if;
end $$;
rollback;
