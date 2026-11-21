begin;
set local role service_role;
do $$
declare
 a uuid := gen_random_uuid(); b uuid := gen_random_uuid();
 first_store uuid; other_store uuid; v uuid;
begin
 first_store := (register_directory_name(a,null,' 점포 Alpha ')->>'id')::uuid;
 if register_directory_name(a,null,'점포 alpha')->>'created' <> 'false' then raise exception 'duplicate store'; end if;
 other_store := (register_directory_name(b,null,'점포 Alpha')->>'id')::uuid;
 if first_store=other_store then raise exception 'owner scope'; end if;
 v := (register_directory_name(a,first_store,'푸른유통')->>'id')::uuid;
 if (register_directory_name(a,first_store,' 푸른유통 ')->>'id')::uuid<>v then raise exception 'duplicate supplier'; end if;
 if (register_directory_name(b,other_store,'푸른유통')->>'id')::uuid=v then raise exception 'supplier scope'; end if;
 begin perform register_directory_name(b,first_store,'잘못된 점포'); raise exception 'foreign store accepted';
 exception when sqlstate 'PT404' then null; end;
 begin perform register_directory_name(a,null,'  '); raise exception 'blank accepted';
 exception when sqlstate 'PT422' then null; end;
 if (select count(distinct store_id) from directory_samples)<>2 or
    (select count(distinct supplier_id) from directory_samples)<>3 or
    (select sum(qty*unit_price) from directory_samples)<>98500 then raise exception 'sample totals or scopes'; end if;
end $$;
rollback;
