-- Team ERD plus persistence requirements from the shared API contract.
begin;
create type public.match_result as enum ('MATCHED','MISMATCH','MISSING_DATA');
create type public.fact_status as enum ('UNCONFIRMED','OWNER_CONFIRMED','COUNTERPARTY_CONFIRMED','CONFLICTING');
create type public.work_status as enum ('OPEN','NEEDS_INFO','WAITING_REPLY','CARRIED_OVER','ON_HOLD','APPROVED');
create type public.confirmation_scope as enum ('DOCUMENTS_ONLY','RECEIPTS_INCLUDED');
create type public.evidence_role as enum ('ORIGINAL','ANSWER');
create type public.document_source_mode as enum ('FILE','TYPED_TEXT','VOICE_MEMO');
create table public.store_items (
 id uuid primary key default gen_random_uuid(),
 store_id uuid not null,
 name text not null,
 spec text,
 base_unit text,
 unique(store_id, id)
);
create table public.item_aliases (
 id uuid primary key default gen_random_uuid(),
 store_id uuid not null,
 supplier_id uuid not null,
 store_item_id uuid not null,
 raw_name text not null,
 raw_spec text,
 raw_unit text,
 unit_factor numeric,
 confirmed_by uuid,
 confirmed_at timestamptz
);
alter table public.documents add column supplier_id uuid;
alter table public.documents add column source_mode document_source_mode not null default 'FILE';
alter table public.documents add column file_path text;
alter table public.documents add column source_text text;
alter table public.documents add column created_by uuid;
alter table public.documents add column request_key text;
alter table public.documents add column doc_no text;
alter table public.documents add column doc_date date;
alter table public.documents add column supersedes_id uuid;
alter table public.documents add unique(store_id,id);
alter table public.documents add unique(store_id,request_key);
create table public.doc_lines (
 id uuid primary key default gen_random_uuid(),
 store_id uuid not null,
 document_id uuid not null,
 store_item_id uuid,
 raw_name text,
 raw_spec text,
 raw_unit text,
 qty_read numeric,
 qty_corrected numeric,
 unit_price_read numeric,
 unit_price_corrected numeric,
 amount_read numeric,
 amount_corrected numeric,
 tax_basis text,
 source_location jsonb,
 extraction_status text,
 unique(store_id, id)
);
create table public.receipts (
 id uuid primary key default gen_random_uuid(),
 store_id uuid not null,
 doc_line_id uuid not null,
 received_qty numeric,
 received_at timestamptz,
 confirmed_by uuid,
 confirmed_at timestamptz,
 supersedes_id uuid,
 unique(store_id, id)
);
create table public.recon_items (
 id uuid primary key default gen_random_uuid(),
 store_id uuid not null,
 period_id uuid not null,
 store_item_id uuid,
 billed_amount numeric,
 expected_amount numeric,
 diff_amount numeric,
 match_result match_result not null,
 fact_status fact_status not null default 'UNCONFIRMED',
 confirmation_scope confirmation_scope not null default 'DOCUMENTS_ONLY',
 work_status work_status not null default 'OPEN',
 unique(store_id, id)
);
create table public.returns (
 id uuid primary key default gen_random_uuid(),
 store_id uuid not null,
 supplier_id uuid not null,
 doc_line_id uuid,
 source_document_id uuid not null,
 qty numeric,
 unit text,
 returned_at timestamptz,
 accepted_status text,
 deduct_status text,
 expected_credit_amount numeric,
 scheduled_period_id uuid,
 applied_period_id uuid,
 applied_recon_item_id uuid,
 next_check_at timestamptz,
 unique(store_id, id)
);
create table public.recon_links (
 id uuid primary key default gen_random_uuid(),
 store_id uuid not null,
 recon_item_id uuid not null,
 doc_line_id uuid,
 receipt_id uuid,
 return_id uuid,
 link_type text not null,
 allocated_qty numeric,
 allocated_amount numeric
);
create table public.questions (
 id uuid primary key default gen_random_uuid(),
 store_id uuid not null,
 period_id uuid,
 recon_item_id uuid,
 return_id uuid,
 question text not null,
 inquiry_draft text,
 status work_status not null,
 next_check_at timestamptz,
 resolved_at timestamptz,
 unique(store_id, id)
);
create table public.question_evidence (
 id uuid primary key default gen_random_uuid(),
 store_id uuid not null,
 question_id uuid not null,
 document_id uuid not null,
 doc_line_id uuid,
 evidence_role evidence_role not null,
 source_location jsonb
);
create table public.settlement_versions (
 id uuid primary key default gen_random_uuid(),
 store_id uuid not null,
 period_id uuid not null,
 version_no integer not null,
 input_revision integer not null,
 confirmation_scope confirmation_scope not null,
 confirmed_total numeric,
 carried_total numeric,
 held_total numeric,
 snapshot jsonb not null,
 approved_by uuid,
 approved_at timestamptz not null default now(),
 request_key text not null,
 unique(period_id, version_no),
 unique(period_id, request_key)
);
create table public.agent_runs (
 id uuid primary key default gen_random_uuid(),
 store_id uuid not null,
 period_id uuid,
 role text not null,
 input_revision integer not null,
 next_action text,
 output jsonb,
 request_key text not null,
 status text not null,
 attempts integer not null default 0,
 started_at timestamptz,
 ended_at timestamptz
);
create table public.payments (
 id uuid primary key default gen_random_uuid(),
 store_id uuid not null,
 supplier_id uuid not null,
 amount numeric not null,
 paid_at timestamptz not null,
 source_document_id uuid,
 unique(store_id, id)
);
create table public.payment_applications (
 id uuid primary key default gen_random_uuid(),
 store_id uuid not null,
 payment_id uuid not null,
 billing_document_id uuid not null,
 amount numeric not null,
 unique(payment_id, billing_document_id)
);
alter table public.store_items add constraint erd_fk_1 foreign key (store_id) references public.stores(id);
create index erd_fk_1_idx on public.store_items(store_id);
alter table public.item_aliases add constraint erd_fk_2 foreign key (store_id) references public.stores(id);
create index erd_fk_2_idx on public.item_aliases(store_id);
alter table public.doc_lines add constraint erd_fk_4 foreign key (store_id) references public.stores(id);
create index erd_fk_4_idx on public.doc_lines(store_id);
alter table public.receipts add constraint erd_fk_5 foreign key (store_id) references public.stores(id);
create index erd_fk_5_idx on public.receipts(store_id);
alter table public.recon_items add constraint erd_fk_7 foreign key (store_id) references public.stores(id);
create index erd_fk_7_idx on public.recon_items(store_id);
alter table public.returns add constraint erd_fk_8 foreign key (store_id) references public.stores(id);
create index erd_fk_8_idx on public.returns(store_id);
alter table public.recon_links add constraint erd_fk_9 foreign key (store_id) references public.stores(id);
create index erd_fk_9_idx on public.recon_links(store_id);
alter table public.questions add constraint erd_fk_10 foreign key (store_id) references public.stores(id);
create index erd_fk_10_idx on public.questions(store_id);
alter table public.question_evidence add constraint erd_fk_11 foreign key (store_id) references public.stores(id);
create index erd_fk_11_idx on public.question_evidence(store_id);
alter table public.settlement_versions add constraint erd_fk_12 foreign key (store_id) references public.stores(id);
create index erd_fk_12_idx on public.settlement_versions(store_id);
alter table public.agent_runs add constraint erd_fk_13 foreign key (store_id) references public.stores(id);
create index erd_fk_13_idx on public.agent_runs(store_id);
alter table public.payments add constraint erd_fk_14 foreign key (store_id) references public.stores(id);
create index erd_fk_14_idx on public.payments(store_id);
alter table public.payment_applications add constraint erd_fk_15 foreign key (store_id) references public.stores(id);
create index erd_fk_15_idx on public.payment_applications(store_id);
alter table public.item_aliases add constraint erd_fk_16 foreign key (store_id, supplier_id) references public.suppliers(store_id, id);
create index erd_fk_16_idx on public.item_aliases(store_id, supplier_id);
alter table public.item_aliases add constraint erd_fk_17 foreign key (store_id, store_item_id) references public.store_items(store_id, id);
create index erd_fk_17_idx on public.item_aliases(store_id, store_item_id);
alter table public.documents add constraint erd_fk_18 foreign key (store_id, supplier_id) references public.suppliers(store_id, id);
create index erd_fk_18_idx on public.documents(store_id, supplier_id);
alter table public.documents add constraint erd_fk_19 foreign key (store_id, supersedes_id) references public.documents(store_id, id);
create index erd_fk_19_idx on public.documents(store_id, supersedes_id);
alter table public.doc_lines add constraint erd_fk_20 foreign key (store_id, document_id) references public.documents(store_id, id);
create index erd_fk_20_idx on public.doc_lines(store_id, document_id);
alter table public.doc_lines add constraint erd_fk_21 foreign key (store_id, store_item_id) references public.store_items(store_id, id);
create index erd_fk_21_idx on public.doc_lines(store_id, store_item_id);
alter table public.receipts add constraint erd_fk_22 foreign key (store_id, doc_line_id) references public.doc_lines(store_id, id);
create index erd_fk_22_idx on public.receipts(store_id, doc_line_id);
alter table public.receipts add constraint erd_fk_23 foreign key (store_id, supersedes_id) references public.receipts(store_id, id);
create index erd_fk_23_idx on public.receipts(store_id, supersedes_id);
alter table public.recon_items add constraint erd_fk_25 foreign key (store_id, period_id) references public.periods(store_id, id);
create index erd_fk_25_idx on public.recon_items(store_id, period_id);
alter table public.recon_items add constraint erd_fk_26 foreign key (store_id, store_item_id) references public.store_items(store_id, id);
create index erd_fk_26_idx on public.recon_items(store_id, store_item_id);
alter table public.returns add constraint erd_fk_27 foreign key (store_id, supplier_id) references public.suppliers(store_id, id);
create index erd_fk_27_idx on public.returns(store_id, supplier_id);
alter table public.returns add constraint erd_fk_28 foreign key (store_id, doc_line_id) references public.doc_lines(store_id, id);
create index erd_fk_28_idx on public.returns(store_id, doc_line_id);
alter table public.returns add constraint erd_fk_29 foreign key (store_id, source_document_id) references public.documents(store_id, id);
create index erd_fk_29_idx on public.returns(store_id, source_document_id);
alter table public.returns add constraint erd_fk_30 foreign key (store_id, scheduled_period_id) references public.periods(store_id, id);
create index erd_fk_30_idx on public.returns(store_id, scheduled_period_id);
alter table public.returns add constraint erd_fk_31 foreign key (store_id, applied_period_id) references public.periods(store_id, id);
create index erd_fk_31_idx on public.returns(store_id, applied_period_id);
alter table public.returns add constraint erd_fk_32 foreign key (store_id, applied_recon_item_id) references public.recon_items(store_id, id);
create index erd_fk_32_idx on public.returns(store_id, applied_recon_item_id);
alter table public.recon_links add constraint erd_fk_33 foreign key (store_id, recon_item_id) references public.recon_items(store_id, id);
create index erd_fk_33_idx on public.recon_links(store_id, recon_item_id);
alter table public.recon_links add constraint erd_fk_34 foreign key (store_id, doc_line_id) references public.doc_lines(store_id, id);
create index erd_fk_34_idx on public.recon_links(store_id, doc_line_id);
alter table public.recon_links add constraint erd_fk_35 foreign key (store_id, receipt_id) references public.receipts(store_id, id);
create index erd_fk_35_idx on public.recon_links(store_id, receipt_id);
alter table public.recon_links add constraint erd_fk_36 foreign key (store_id, return_id) references public.returns(store_id, id);
create index erd_fk_36_idx on public.recon_links(store_id, return_id);
alter table public.questions add constraint erd_fk_37 foreign key (store_id, period_id) references public.periods(store_id, id);
create index erd_fk_37_idx on public.questions(store_id, period_id);
alter table public.questions add constraint erd_fk_38 foreign key (store_id, recon_item_id) references public.recon_items(store_id, id);
create index erd_fk_38_idx on public.questions(store_id, recon_item_id);
alter table public.questions add constraint erd_fk_39 foreign key (store_id, return_id) references public.returns(store_id, id);
create index erd_fk_39_idx on public.questions(store_id, return_id);
alter table public.question_evidence add constraint erd_fk_40 foreign key (store_id, question_id) references public.questions(store_id, id);
create index erd_fk_40_idx on public.question_evidence(store_id, question_id);
alter table public.question_evidence add constraint erd_fk_41 foreign key (store_id, document_id) references public.documents(store_id, id);
create index erd_fk_41_idx on public.question_evidence(store_id, document_id);
alter table public.question_evidence add constraint erd_fk_42 foreign key (store_id, doc_line_id) references public.doc_lines(store_id, id);
create index erd_fk_42_idx on public.question_evidence(store_id, doc_line_id);
alter table public.settlement_versions add constraint erd_fk_43 foreign key (store_id, period_id) references public.periods(store_id, id);
create index erd_fk_43_idx on public.settlement_versions(store_id, period_id);
alter table public.agent_runs add constraint erd_fk_44 foreign key (store_id, period_id) references public.periods(store_id, id);
create index erd_fk_44_idx on public.agent_runs(store_id, period_id);
alter table public.payments add constraint erd_fk_45 foreign key (store_id, supplier_id) references public.suppliers(store_id, id);
create index erd_fk_45_idx on public.payments(store_id, supplier_id);
alter table public.payments add constraint erd_fk_46 foreign key (store_id, source_document_id) references public.documents(store_id, id);
create index erd_fk_46_idx on public.payments(store_id, source_document_id);
alter table public.payment_applications add constraint erd_fk_47 foreign key (store_id, payment_id) references public.payments(store_id, id);
create index erd_fk_47_idx on public.payment_applications(store_id, payment_id);
alter table public.payment_applications add constraint erd_fk_48 foreign key (store_id, billing_document_id) references public.documents(store_id, id);
create index erd_fk_48_idx on public.payment_applications(store_id, billing_document_id);

-- FILE storage compatibility and confirmed text memos.
alter table public.documents alter column file_hash drop not null;
alter table public.documents alter column storage_path drop not null;
alter table public.documents alter column filename drop not null;
alter table public.documents alter column mime_type drop not null;
alter table public.documents alter column byte_size drop not null;
alter table public.documents drop constraint documents_doc_type_check;
update public.documents set file_path=storage_path where source_mode='FILE';
alter table public.documents add column supplier_name_read text,
 add column selected_supplier_id uuid,
 add column period_start date, add column period_end date,
 add column payment_due_on date, add column replaces_doc_no text,
 add column agreement_text text, add column agreement_source_location jsonb,
 add column metadata jsonb not null default '{}';
alter table public.documents add foreign key(store_id,selected_supplier_id) references public.suppliers(store_id,id);
alter table public.documents add constraint document_source_valid check (
 (source_mode='FILE' and storage_path is not null and file_hash is not null and byte_size>0 and mime_type in ('image/png','image/jpeg','image/webp'))
 or (source_mode in ('TYPED_TEXT','VOICE_MEMO') and nullif(trim(source_text),'') is not null
     and storage_path is null and file_hash is null and doc_type='OWNER_CALL_MEMO')
);
alter table public.documents add check (supersedes_id is distinct from id);
alter table public.documents add check (period_start is null or period_end is null or period_end>=period_start);
create index documents_supplier_number_idx on public.documents(store_id,supplier_id,doc_type,doc_no) where doc_no is not null;

alter table public.periods add column reconciled_revision int;
alter table public.periods add check(input_revision>=0);
alter table public.doc_lines add column delivery_no text, add column delivery_date date,
 add column corrected_by uuid, add column corrected_at timestamptz;
alter table public.receipts add column source_line_id uuid, add column unit text, add column actor_label text,
 add foreign key(store_id,source_line_id) references public.doc_lines(store_id,id),
 add check(received_qty is null or received_qty>=0), add check(supersedes_id is distinct from id);
create unique index receipts_superseded_once on public.receipts(supersedes_id) where supersedes_id is not null;
alter table public.item_aliases add check(unit_factor is null or unit_factor>0);
create unique index alias_identity on public.item_aliases(store_id,supplier_id,raw_name,coalesce(raw_spec,''),coalesce(raw_unit,''));
alter table public.recon_items add column delivery_no text, add column delivery_date date,
 add column declared_qty numeric, add column billed_qty numeric, add column received_qty numeric,
 add column unit text, add column delta_qty numeric, add column check_amount numeric,
 add column blockers jsonb not null default '[]';
alter table public.recon_items add check(jsonb_typeof(blockers)='array');
alter table public.recon_links add check(num_nonnulls(doc_line_id,receipt_id,return_id)=1);
create unique index recon_line_once on public.recon_links(recon_item_id,doc_line_id,link_type) where doc_line_id is not null;
create unique index recon_receipt_once on public.recon_links(receipt_id) where receipt_id is not null;
create unique index recon_return_once on public.recon_links(return_id) where return_id is not null;
alter table public.settlement_versions add column actor_label text not null,
 add column payment_status text not null default 'UNCONFIRMED' check(payment_status='UNCONFIRMED'),
 add unique(period_id,input_revision), add check(version_no>0), add check(input_revision>=0),
 add check(confirmed_total is null or confirmed_total>=0);
alter table public.agent_runs add unique(store_id,role,request_key),add check(attempts>=0);
alter table public.payments add check(amount>0 and amount=trunc(amount));
alter table public.payment_applications add check(amount>0 and amount=trunc(amount));
alter table public.period_documents add column store_id uuid;
update public.period_documents pd set store_id=p.store_id from public.periods p where p.id=pd.period_id;
alter table public.period_documents alter column store_id set not null;
alter table public.period_documents add foreign key(store_id,period_id) references public.periods(store_id,id),
 add foreign key(store_id,document_id) references public.documents(store_id,id),
 add column status text not null default 'ACTIVE' check(status in ('ACTIVE','CANDIDATE','UNCLASSIFIED','REPLACED'));


create table public.operation_requests(
 store_id uuid not null references public.stores(id),
 operation text not null, request_key text not null check(length(request_key) between 1 and 200),
 payload jsonb not null, response jsonb not null,
 created_at timestamptz not null default now(),
 primary key(store_id,operation,request_key)
);
create table public.confirmations(
 id uuid primary key default gen_random_uuid(), store_id uuid not null, period_id uuid not null,
 kind text not null check(kind in ('receipt_link','replacement','line_correction')),
 source_line_id uuid, document_id uuid, target_id uuid not null,
 evidence_refs jsonb not null check(jsonb_typeof(evidence_refs)='array' and jsonb_array_length(evidence_refs)>0),
 corrected_fields jsonb, actor_label text not null, confirmed_by uuid, confirmed_at timestamptz not null default now(),
 foreign key(store_id,period_id) references public.periods(store_id,id),
 foreign key(store_id,source_line_id) references public.doc_lines(store_id,id),
 foreign key(store_id,document_id) references public.documents(store_id,id),
 check((kind='replacement' and document_id is not null) or (kind in ('receipt_link','line_correction') and source_line_id is not null)),
 unique(store_id,id)
);
create table public.transaction_memos(
 id uuid primary key default gen_random_uuid(),store_id uuid not null,transaction_id uuid not null,
 document_id uuid not null unique,confirmed_text text not null check(length(trim(confirmed_text))>0),
 source_mode document_source_mode not null check(source_mode in ('VOICE_MEMO','TYPED_TEXT')),
 actor_label text not null,confirmed_by uuid,confirmed_at timestamptz not null default now(),
 foreign key(store_id,transaction_id) references public.recon_items(store_id,id),
 foreign key(store_id,document_id) references public.documents(store_id,id)
);
create index transaction_memos_transaction on public.transaction_memos(store_id,transaction_id);
create index confirmations_period on public.confirmations(store_id,period_id);

alter table public.stores enable row level security;
revoke all on public.stores from anon,authenticated;
grant select,insert,update,delete on public.stores to service_role;
alter table public.suppliers enable row level security;
revoke all on public.suppliers from anon,authenticated;
grant select,insert,update,delete on public.suppliers to service_role;
alter table public.store_items enable row level security;
revoke all on public.store_items from anon,authenticated;
grant select,insert,update,delete on public.store_items to service_role;
alter table public.item_aliases enable row level security;
revoke all on public.item_aliases from anon,authenticated;
grant select,insert,update,delete on public.item_aliases to service_role;
alter table public.documents enable row level security;
revoke all on public.documents from anon,authenticated;
grant select,insert,update,delete on public.documents to service_role;
alter table public.doc_lines enable row level security;
revoke all on public.doc_lines from anon,authenticated;
grant select,insert,update,delete on public.doc_lines to service_role;
alter table public.receipts enable row level security;
revoke all on public.receipts from anon,authenticated;
grant select,insert,update,delete on public.receipts to service_role;
alter table public.periods enable row level security;
revoke all on public.periods from anon,authenticated;
grant select,insert,update,delete on public.periods to service_role;
alter table public.recon_items enable row level security;
revoke all on public.recon_items from anon,authenticated;
grant select,insert,update,delete on public.recon_items to service_role;
alter table public.returns enable row level security;
revoke all on public.returns from anon,authenticated;
grant select,insert,update,delete on public.returns to service_role;
alter table public.recon_links enable row level security;
revoke all on public.recon_links from anon,authenticated;
grant select,insert,update,delete on public.recon_links to service_role;
alter table public.questions enable row level security;
revoke all on public.questions from anon,authenticated;
grant select,insert,update,delete on public.questions to service_role;
alter table public.question_evidence enable row level security;
revoke all on public.question_evidence from anon,authenticated;
grant select,insert,update,delete on public.question_evidence to service_role;
alter table public.settlement_versions enable row level security;
revoke all on public.settlement_versions from anon,authenticated;
grant select,insert,update,delete on public.settlement_versions to service_role;
alter table public.agent_runs enable row level security;
revoke all on public.agent_runs from anon,authenticated;
grant select,insert,update,delete on public.agent_runs to service_role;
alter table public.payments enable row level security;
revoke all on public.payments from anon,authenticated;
grant select,insert,update,delete on public.payments to service_role;
alter table public.payment_applications enable row level security;
revoke all on public.payment_applications from anon,authenticated;
grant select,insert,update,delete on public.payment_applications to service_role;
alter table public.period_documents enable row level security;
revoke all on public.period_documents from anon,authenticated;
grant select,insert,update,delete on public.period_documents to service_role;
alter table public.document_upload_requests enable row level security;
revoke all on public.document_upload_requests from anon,authenticated;
grant select,insert,update,delete on public.document_upload_requests to service_role;
alter table public.operation_requests enable row level security;
revoke all on public.operation_requests from anon,authenticated;
grant select,insert,update,delete on public.operation_requests to service_role;
alter table public.confirmations enable row level security;
revoke all on public.confirmations from anon,authenticated;
grant select,insert,update,delete on public.confirmations to service_role;
alter table public.transaction_memos enable row level security;
revoke all on public.transaction_memos from anon,authenticated;
grant select,insert,update,delete on public.transaction_memos to service_role;
-- Additional transactional functions and triggers follow.
-- Every evidence mutation locks affected periods before the row changes.
create function public.touch_period(p_id uuid) returns void language plpgsql security invoker set search_path=public as $$
begin
 update periods set input_revision=input_revision+1,reconciled_revision=null,status='REVIEWING' where id=p_id;
end $$;

create function public.evidence_changed() returns trigger language plpgsql security invoker set search_path=public as $$
declare v jsonb; ids uuid[]; p uuid;
begin
 if TG_OP='UPDATE' and to_jsonb(new)=to_jsonb(old) then return new; end if;
 for v in select value from jsonb_array_elements(
   case when TG_OP='INSERT' then jsonb_build_array(to_jsonb(new))
        when TG_OP='DELETE' then jsonb_build_array(to_jsonb(old))
        else jsonb_build_array(to_jsonb(old),to_jsonb(new)) end)
 loop
  if TG_TABLE_NAME in ('period_documents','confirmations') then
   ids:=array_append(ids,(v->>'period_id')::uuid);
  elsif TG_TABLE_NAME='documents' then
   ids:=ids||array(select period_id from period_documents where document_id=(v->>'id')::uuid);
  elsif TG_TABLE_NAME='doc_lines' then
   ids:=ids||array(select period_id from period_documents where document_id=(v->>'document_id')::uuid);
  elsif TG_TABLE_NAME='receipts' then
   ids:=ids||array(select pd.period_id from period_documents pd join doc_lines l on l.document_id=pd.document_id where l.id in ((v->>'doc_line_id')::uuid,(v->>'source_line_id')::uuid));
  elsif TG_TABLE_NAME='transaction_memos' then
   ids:=ids||array(select period_id from recon_items where id=(v->>'transaction_id')::uuid);
  elsif TG_TABLE_NAME in ('questions','returns') then
   ids:=ids||array(select id from periods where id in ((v->>'period_id')::uuid,(v->>'scheduled_period_id')::uuid,(v->>'applied_period_id')::uuid));
   ids:=ids||array(select period_id from recon_items where id=(v->>'recon_item_id')::uuid);
  end if;
 end loop;
 for p in select distinct unnest(ids) order by 1 loop perform touch_period(p); end loop;
 if TG_OP='DELETE' then return old; end if;
 return new;
end $$;

create function public.prepare_period_document() returns trigger language plpgsql security invoker set search_path=public as $$
declare p periods; d documents;
begin
 select * into strict p from periods where id=new.period_id;
 select * into strict d from documents where id=new.document_id;
 new.store_id:=p.store_id;
 if d.store_id<>p.store_id then raise exception 'STORE_MISMATCH'; end if;
 if d.supplier_id is not null and d.supplier_id<>p.supplier_id then new.status:='UNCLASSIFIED'; end if;
 return new;
end $$;
create trigger a_prepare before insert or update on public.period_documents for each row execute function public.prepare_period_document();

create function public.validate_document() returns trigger language plpgsql security invoker set search_path=public as $$
declare prior documents;
begin
 if new.source_mode='FILE' then new.file_path:=new.storage_path; end if;
 if new.supersedes_id is not null then
  select * into prior from documents where id=new.supersedes_id;
  if prior.store_id<>new.store_id or prior.supplier_id is distinct from new.supplier_id
   or prior.period_start is distinct from new.period_start or prior.period_end is distinct from new.period_end then
   raise exception 'REPLACEMENT_SCOPE_MISMATCH';
  end if;
  if exists(with recursive chain as (
    select id,supersedes_id from documents where id=new.supersedes_id
    union select d.id,d.supersedes_id from documents d join chain c on d.id=c.supersedes_id
   ) select 1 from chain where id=new.id) then raise exception 'REPLACEMENT_CYCLE'; end if;
 end if;
 return new;
end $$;
create trigger a_document_valid before insert or update on public.documents for each row execute function public.validate_document();

create function public.validate_evidence_line() returns trigger language plpgsql security invoker set search_path=public as $$
begin
 if new.doc_line_id is not null and not exists(select 1 from doc_lines where id=new.doc_line_id and document_id=new.document_id and store_id=new.store_id) then
  raise exception 'EVIDENCE_DOCUMENT_MISMATCH';
 end if;
 return new;
end $$;
create trigger evidence_line_valid before insert or update on public.question_evidence for each row execute function public.validate_evidence_line();

create function public.validate_receipt() returns trigger language plpgsql security invoker set search_path=public as $$
declare prior receipts;
begin
 if new.supersedes_id is not null then
  select * into prior from receipts where id=new.supersedes_id;
  if prior.doc_line_id<>new.doc_line_id or prior.store_id<>new.store_id then raise exception 'RECEIPT_SCOPE_MISMATCH'; end if;
  if exists(with recursive chain as (
    select id,supersedes_id from receipts where id=new.supersedes_id
    union select r.id,r.supersedes_id from receipts r join chain c on r.id=c.supersedes_id
  ) select 1 from chain where id=new.id) then raise exception 'RECEIPT_CYCLE'; end if;
 end if;
 return new;
end $$;
create trigger a_receipt_valid before insert or update on public.receipts for each row execute function public.validate_receipt();

create function public.freeze_record() returns trigger language plpgsql security invoker set search_path=public as $$
begin raise exception 'IMMUTABLE_HISTORY'; end $$;
create trigger immutable_approval before update or delete on public.settlement_versions for each row execute function public.freeze_record();
create trigger immutable_confirmation before update or delete on public.confirmations for each row execute function public.freeze_record();
create trigger immutable_memo before update or delete on public.transaction_memos for each row execute function public.freeze_record();
create trigger immutable_receipt before update or delete on public.receipts for each row execute function public.freeze_record();
create trigger immutable_request before update or delete on public.operation_requests for each row execute function public.freeze_record();

create function public.check_payment_allocation() returns trigger language plpgsql security invoker set search_path=public as $$
declare p payments; supplier uuid; total numeric; pid uuid;
begin
 for pid in select distinct unnest(
  case when TG_OP='INSERT' then array[new.payment_id] when TG_OP='DELETE' then array[old.payment_id] else array[old.payment_id,new.payment_id] end
 ) order by 1 loop perform 1 from payments where id=pid for update; end loop;
 if TG_OP='DELETE' then return old; end if;
 select * into strict p from payments where id=new.payment_id;
 select supplier_id into supplier from documents where id=new.billing_document_id;
 if p.store_id<>new.store_id or supplier is distinct from p.supplier_id then raise exception 'PAYMENT_SCOPE_MISMATCH'; end if;
 select coalesce(sum(amount),0) into total from payment_applications where payment_id=new.payment_id and id<>new.id;
 if total+new.amount>p.amount then raise exception 'PAYMENT_OVERALLOCATED'; end if;
 return new;
end $$;
create trigger payment_allocation before insert or update or delete on public.payment_applications for each row execute function public.check_payment_allocation();
create function public.check_payment_total() returns trigger language plpgsql security invoker set search_path=public as $$
begin
 if exists(select 1 from payment_applications where payment_id=new.id) and
 (new.store_id<>old.store_id or new.supplier_id<>old.supplier_id or new.amount<(select sum(amount) from payment_applications where payment_id=new.id)) then
 raise exception 'PAYMENT_OVERALLOCATED'; end if;
 return new;
end $$;
create trigger payment_total before update on public.payments for each row execute function public.check_payment_total();

create function public.lock_reconciliation() returns trigger language plpgsql security invoker set search_path=public as $$
declare p uuid; v_status period_status;
begin
 if TG_TABLE_NAME='recon_items' then
  if TG_OP='DELETE' then p:=old.period_id; else p:=new.period_id; end if;
 else
  if TG_OP='DELETE' then select period_id into p from recon_items where id=old.recon_item_id;
  else select period_id into p from recon_items where id=new.recon_item_id; end if;
 end if;
 select status into v_status from periods where id=p for update;
 if v_status='APPROVED' then raise exception 'FROZEN_REVISION'; end if;
 update periods set reconciled_revision=null where id=p;
 if TG_OP='DELETE' then return old; end if; return new;
end $$;
create trigger recon_lock before insert or update or delete on public.recon_items for each row execute function public.lock_reconciliation();
create trigger link_lock before insert or update or delete on public.recon_links for each row execute function public.lock_reconciliation();
create trigger z_evidence_revision before insert or update or delete on public.documents for each row execute function public.evidence_changed();
create trigger z_evidence_revision before insert or update or delete on public.doc_lines for each row execute function public.evidence_changed();
create trigger z_evidence_revision before insert or update or delete on public.receipts for each row execute function public.evidence_changed();
create trigger z_evidence_revision before insert or update or delete on public.period_documents for each row execute function public.evidence_changed();
create trigger z_evidence_revision before insert or update or delete on public.confirmations for each row execute function public.evidence_changed();
create trigger z_evidence_revision before insert or update or delete on public.transaction_memos for each row execute function public.evidence_changed();
create trigger z_evidence_revision before insert or update or delete on public.questions for each row execute function public.evidence_changed();
create trigger z_evidence_revision before insert or update or delete on public.returns for each row execute function public.evidence_changed();
create function public.assert_revision(p periods,p_expected int) returns void language plpgsql security invoker set search_path=public as $$
begin
 if p.input_revision<>p_expected then
  raise sqlstate 'PT409' using message='STALE_REVISION',detail=jsonb_build_object('input_revision',p.input_revision)::text;
 end if;
end $$;

create function public.finish_reconciliation(p_store uuid,p_period uuid,p_expected int)
returns jsonb language plpgsql security invoker set search_path=public as $$
declare p periods;
begin
 select * into p from periods where id=p_period and store_id=p_store for update;
 if not found then raise sqlstate 'PT404' using message='PERIOD_NOT_FOUND'; end if;
 perform assert_revision(p,p_expected);
 if p.status='APPROVED' then raise sqlstate 'PT409' using message='FROZEN_REVISION'; end if;
 update periods set reconciled_revision=input_revision where id=p_period;
 return jsonb_build_object('input_revision',p.input_revision);
end $$;

create function public.approve_period(p_store uuid,p_period uuid,p_expected int,p_key text,p_actor_label text,p_actor uuid default null)
returns jsonb language plpgsql security invoker set search_path=public as $$
declare p periods; req operation_requests; payload jsonb; result jsonb; approval settlement_versions;
 blockers jsonb:='[]'; total numeric; snap jsonb;
begin
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
  if exists(select 1 from recon_items where period_id=p_period and
    (match_result<>'MATCHED' or confirmation_scope<>'RECEIPTS_INCLUDED'
     or received_qty is null or billed_qty is null or unit is null
     or billed_qty<>received_qty or check_amount is distinct from 0::numeric
     or billed_amount is null or billed_amount<0 or billed_amount<>trunc(billed_amount)
     or blockers<>'[]'::jsonb or work_status in ('ON_HOLD','CARRIED_OVER','NEEDS_INFO','WAITING_REPLY')))
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

create function public.save_confirmed_memo(p_store uuid,p_transaction uuid,p_text text,p_mode document_source_mode,p_expected int,p_key text,p_actor_label text,p_actor uuid default null)
returns jsonb language plpgsql security invoker set search_path=public as $$
declare p periods; r recon_items; req operation_requests; payload jsonb; result jsonb; doc uuid; memo uuid;
begin
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
create function public.save_confirmation(p_store uuid,p_period uuid,p_expected int,p_key text,p_body jsonb,p_actor_label text,p_actor uuid default null)
returns jsonb language plpgsql security invoker set search_path=public as $$
declare p periods; req operation_requests; payload jsonb; result jsonb; cid uuid;
 kind text:=p_body->>'kind'; src doc_lines; target doc_lines; doc documents; previous documents;
 target_id uuid:=(p_body->>'target_id')::uuid; evidence jsonb:=p_body->'evidence_refs'; e jsonb; receipt uuid;
begin
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

-- Preserve the existing upload RPC signature used by the deployed API.
create or replace function public.register_document(p_period uuid,p_hash text,p_path text,p_filename text,p_mime text,p_size int,p_type text,p_key text,p_payload text)
returns jsonb language plpgsql security invoker set search_path=public as $$
declare p periods; d documents; req document_upload_requests; duplicate boolean; link_status text:='ACTIVE';
begin
 select * into p from periods where id=p_period for update;
 if not found then raise exception 'PERIOD_NOT_FOUND'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p.store_id::text,0));
 select * into req from document_upload_requests where store_id=p.store_id and request_key=p_key;
 if found then
  if req.payload_hash<>p_payload then raise exception 'KEY_REUSE'; end if;
  select * into d from documents where id=req.document_id;
  return to_jsonb(d)||jsonb_build_object('duplicate',true,'input_revision',p.input_revision);
 end if;
 select * into d from documents where store_id=p.store_id and file_hash=p_hash;
 duplicate:=found;
 if not duplicate then
  insert into documents(store_id,file_hash,storage_path,filename,mime_type,byte_size,doc_type,selected_supplier_id)
  values(p.store_id,p_hash,p_path,p_filename,p_mime,p_size,p_type,p.supplier_id) returning * into d;
 elsif d.selected_supplier_id is not null and d.selected_supplier_id<>p.supplier_id then link_status:='CANDIDATE';
 end if;
 insert into period_documents(period_id,document_id,status) values(p_period,d.id,link_status) on conflict do nothing;
 insert into document_upload_requests values(p.store_id,p_key,p_payload,d.id);
 select * into p from periods where id=p_period;
 return to_jsonb(d)||jsonb_build_object('duplicate',duplicate,'input_revision',p.input_revision);
end $$;

create function public.validate_recon_link() returns trigger language plpgsql security invoker set search_path=public as $$
declare p periods; doc_id uuid; target_store uuid;
begin
 select per.* into p from recon_items r join periods per on per.id=r.period_id where r.id=new.recon_item_id;
 if new.doc_line_id is not null then select document_id into doc_id from doc_lines where id=new.doc_line_id;
 elsif new.receipt_id is not null then select l.document_id into doc_id from receipts r join doc_lines l on l.id=r.doc_line_id where r.id=new.receipt_id;
 else select source_document_id into doc_id from returns where id=new.return_id; end if;
 if not exists(select 1 from period_documents pd join documents d on d.id=pd.document_id where pd.period_id=p.id and pd.document_id=doc_id and d.store_id=new.store_id
  and d.supplier_id is not distinct from p.supplier_id) then raise exception 'LINK_PERIOD_OR_SUPPLIER_MISMATCH'; end if;
 return new;
end $$;
create trigger a_link_valid before insert or update on public.recon_links for each row execute function public.validate_recon_link();

-- Backend-only RPCs and triggers. Public clients cannot call privileged operations.
do $$
declare f record;
begin
 for f in select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname in (
   'touch_period','evidence_changed','prepare_period_document','validate_document','validate_evidence_line','validate_receipt',
   'freeze_record','check_payment_allocation','check_payment_total','lock_reconciliation','assert_revision',
   'finish_reconciliation','approve_period','save_confirmed_memo','save_confirmation','register_document','validate_recon_link')
 loop
  execute format('revoke all on function %s from public,anon,authenticated',f.signature);
  execute format('grant execute on function %s to service_role',f.signature);
 end loop;
end $$;
commit;
