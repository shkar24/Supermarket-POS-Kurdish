create or replace function public.market_checkout(p_items jsonb,p_discount numeric,p_payment_method text,p_request uuid) returns jsonb language sql security definer set search_path='' as $$select public.checkout_with_credit(p_items,p_discount,p_payment_method,p_request,null,0)$$;
CREATE OR REPLACE FUNCTION public.market_return(p_sale_item_id uuid, p_quantity numeric, p_reason text, p_restock boolean, p_request uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare i public.sale_items;previous numeric;amount numeric;rid uuid;lot record;needed numeric:=p_quantity;taken numeric;
begin perform private.require_manager();
select * into strict i from public.sale_items where id=p_sale_item_id for update;
if exists(select 1 from public.sale_returns where id=p_request) then return (select jsonb_build_object('return_id',id,'amount',r.amount,'cash',coalesce(r.cash_refunded,r.amount),'relief',r.amount-coalesce(r.cash_refunded,r.amount)) from public.sale_returns r where id=p_request);end if;
select coalesce(sum(quantity),0) into previous from public.sale_return_items where sale_item_id=i.id;
if p_quantity is null or p_quantity<=0 or p_quantity<>round(p_quantity,3) or (coalesce(i.unit_snapshot,'piece') not in ('kg','litre') and p_quantity<>trunc(p_quantity)) or previous+p_quantity>i.quantity or p_restock is null then raise exception 'Invalid return quantity';end if;
amount:=round(i.net_amount*(previous+p_quantity)/i.quantity,2)-round(i.net_amount*previous/i.quantity,2);
insert into public.sale_returns(id,sale_id,created_by,reason,amount) values(p_request,i.sale_id,auth.uid(),coalesce(p_reason,''),amount);
insert into public.sale_return_items(return_id,sale_item_id,quantity,restocked) values(p_request,i.id,p_quantity,p_restock) returning id into rid;
perform 1 from public.products where id=i.product_id for update;
for lot in select * from public.sale_lots where sale_item_id=i.id and restored<quantity order by purchase_item_id for update loop
taken:=least(needed,lot.quantity-lot.restored);
update public.sale_lots set restored=restored+taken where sale_item_id=i.id and purchase_item_id=lot.purchase_item_id;
if p_restock then update public.purchase_items set remaining=remaining+taken where id=lot.purchase_item_id;end if;
needed:=needed-taken;exit when needed=0;end loop;
if p_restock then
perform set_config('market.return_item',rid::text,true);perform set_config('market.reason','return',true);
update public.products set stock_quantity=stock_quantity+p_quantity,updated_at=now() where id=i.product_id;
end if;
return (select jsonb_build_object('return_id',r.id,'amount',r.amount,'cash',r.cash_refunded,'relief',r.amount-r.cash_refunded) from public.sale_returns r where r.id=p_request);end $function$
;