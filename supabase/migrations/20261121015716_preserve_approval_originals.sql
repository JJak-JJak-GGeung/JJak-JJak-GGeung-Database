begin;
create index approval_snapshot_lookup on public.settlement_versions using gin(snapshot jsonb_path_ops);
create function public.preserve_approved_original() returns trigger language plpgsql security invoker set search_path=public as $$
begin
 if exists(select 1 from settlement_versions where snapshot @> jsonb_build_object(
   'documents',jsonb_build_array(jsonb_build_object('id',old.id))))
 then raise exception 'IMMUTABLE_APPROVAL_ORIGINAL'; end if;
 return old;
end $$;
create trigger a_approved_original before delete on public.documents for each row execute function public.preserve_approved_original();
revoke all on function public.preserve_approved_original() from public,anon,authenticated;
grant execute on function public.preserve_approved_original() to service_role;
commit;
