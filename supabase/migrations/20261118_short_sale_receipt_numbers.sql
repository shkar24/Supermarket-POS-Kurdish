lock table public.sales in access exclusive mode;
alter table public.sales add column legacy_receipt_number text unique;
create sequence private.sale_receipt_seq as bigint;
with numbered as (
 select id, row_number() over(order by created_at,id)::text as digits from public.sales
)
update public.sales s set legacy_receipt_number=s.receipt_number,
 receipt_number='POS-'||lpad(n.digits,greatest(6,length(n.digits)), '0')
from numbered n where n.id=s.id;
select setval('private.sale_receipt_seq', count(*)+1,false) from public.sales;
create function private.assign_sale_receipt() returns trigger language plpgsql
security definer set search_path='' as $$
declare digits text:=nextval('private.sale_receipt_seq')::text;
begin
 new.receipt_number:='POS-'||lpad(digits,greatest(6,length(digits)),'0');
 return new;
end $$;
revoke all on function private.assign_sale_receipt() from public,anon,authenticated;
create trigger short_receipt before insert on public.sales for each row execute function private.assign_sale_receipt();