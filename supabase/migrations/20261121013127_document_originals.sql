create table public.documents (
 id uuid primary key default gen_random_uuid(),
 store_id uuid not null references public.stores(id),
 file_hash text not null, storage_path text not null unique,
 filename text not null, mime_type text not null,
 byte_size integer not null check(byte_size>0),
 doc_type text not null check(doc_type in ('DELIVERY','RECEIPT','INVOICE','CORRECTED_INVOICE')),
 extraction_status text not null default 'PENDING',
 created_at timestamptz not null default now(),
 unique(store_id,file_hash)
);
create table public.period_documents (
 period_id uuid not null references public.periods(id),
 document_id uuid not null references public.documents(id),
 primary key(period_id,document_id)
);
create table public.document_upload_requests (
 store_id uuid not null references public.stores(id),
 request_key text not null,
 payload_hash text not null,
 document_id uuid not null references public.documents(id),
 primary key(store_id,request_key)
);
alter table public.documents enable row level security;
alter table public.period_documents enable row level security;
alter table public.document_upload_requests enable row level security;
revoke all on public.documents,public.period_documents,public.document_upload_requests from anon,authenticated;
grant all on public.documents,public.period_documents,public.document_upload_requests to service_role;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('originals','originals',false,10485760,array['image/png','image/jpeg','image/webp'])
on conflict(id) do nothing;

create function public.register_document(p_period uuid,p_hash text,p_path text,p_filename text,p_mime text,p_size int,p_type text,p_key text,p_payload text)
returns jsonb language plpgsql security invoker set search_path=public as $$
declare v_period periods; v_doc documents; v_req document_upload_requests; v_count int; v_duplicate boolean;
begin
 select * into v_period from periods where id=p_period for update;
 if not found then raise exception 'PERIOD_NOT_FOUND'; end if;
 perform pg_advisory_xact_lock(hashtextextended(v_period.store_id::text,0));
 select * into v_req from document_upload_requests where store_id=v_period.store_id and request_key=p_key;
 if found then
  if v_req.payload_hash<>p_payload then raise exception 'KEY_REUSE'; end if;
  select * into v_doc from documents where id=v_req.document_id;
  return to_jsonb(v_doc)||jsonb_build_object('duplicate',true,'input_revision',v_period.input_revision);
 end if;
 select * into v_doc from documents where store_id=v_period.store_id and file_hash=p_hash;
 v_duplicate:=found;
 if not v_duplicate then
  insert into documents(store_id,file_hash,storage_path,filename,mime_type,byte_size,doc_type)
  values(v_period.store_id,p_hash,p_path,p_filename,p_mime,p_size,p_type) returning * into v_doc;
 end if;
 insert into period_documents values(p_period,v_doc.id) on conflict do nothing;
 get diagnostics v_count=row_count;
 if v_count>0 then
  update periods set input_revision=input_revision+1 where id=p_period returning * into v_period;
 end if;
 insert into document_upload_requests values(v_period.store_id,p_key,p_payload,v_doc.id);
 return to_jsonb(v_doc)||jsonb_build_object('duplicate',v_duplicate,'input_revision',v_period.input_revision);
end $$;
revoke all on function public.register_document(uuid,text,text,text,text,int,text,text,text) from public,anon,authenticated;
grant execute on function public.register_document(uuid,text,text,text,text,int,text,text,text) to service_role;
