create or replace function public.validate_recon_link() returns trigger language plpgsql security invoker set search_path=public as $$
declare p periods; doc_id uuid; target_store uuid;
begin
 if num_nonnulls(new.doc_line_id,new.receipt_id,new.return_id)<>1 then raise check_violation using message='EXACTLY_ONE_EVIDENCE_REQUIRED'; end if;
 select per.* into p from recon_items r join periods per on per.id=r.period_id where r.id=new.recon_item_id;
 if new.doc_line_id is not null then select document_id into doc_id from doc_lines where id=new.doc_line_id;
 elsif new.receipt_id is not null then select l.document_id into doc_id from receipts r join doc_lines l on l.id=r.doc_line_id where r.id=new.receipt_id;
 else select source_document_id into doc_id from returns where id=new.return_id; end if;
 if not exists(select 1 from period_documents pd join documents d on d.id=pd.document_id where pd.period_id=p.id and pd.document_id=doc_id and d.store_id=new.store_id
  and d.supplier_id is not distinct from p.supplier_id) then raise exception 'LINK_PERIOD_OR_SUPPLIER_MISMATCH'; end if;
 return new;
end $$;
