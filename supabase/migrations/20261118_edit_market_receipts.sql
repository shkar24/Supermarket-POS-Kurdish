CREATE OR REPLACE FUNCTION private.stock_journal()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare delta numeric; sid uuid;rid uuid;pid uuid; lot record; needed numeric;taken numeric;
begin
delta:=new.stock_quantity-case when tg_op='INSERT' then 0 else old.stock_quantity end;
if delta=0 then return new;end if;
if new.unit not in ('kg','litre') and new.stock_quantity<>trunc(new.stock_quantity) then raise exception 'Whole pieces required';end if;
sid:=nullif(current_setting('market.sale_item',true),'')::uuid;
rid:=nullif(current_setting('market.return_item',true),'')::uuid;
pid:=nullif(current_setting('market.purchase_item',true),'')::uuid;
insert into public.inventory_movements(product_id,actor_id,quantity_change,reason,sale_item_id,return_item_id,purchase_item_id)
values(new.id,auth.uid(),delta,coalesce(nullif(current_setting('market.reason',true),''),'adjustment'),sid,rid,pid);
if delta<0 and pid is null then
needed:=-delta;
for lot in select id,remaining from public.purchase_items where product_id=new.id and remaining>0 and (sid is null or expires_on is null or expires_on >= (now() at time zone 'Asia/Baghdad')::date) order by expires_on nulls last,id for update loop
taken:=least(needed,lot.remaining);
update public.purchase_items set remaining=remaining-taken where id=lot.id;
if sid is not null then insert into public.sale_lots values(sid,lot.id,taken,0) on conflict (sale_item_id,purchase_item_id) do update set quantity=public.sale_lots.quantity+excluded.quantity;end if;
needed:=needed-taken;exit when needed=0;
end loop;
if sid is not null and new.stock_quantity<(select coalesce(sum(remaining),0) from public.purchase_items where product_id=new.id) then raise exception 'Available unexpired stock is insufficient';end if;
end if;
perform set_config('market.sale_item','',true);perform set_config('market.purchase_item','',true);perform set_config('market.return_item','',true);perform set_config('market.reason','',true);
return new;end $function$
;
create table public.receipt_edits(
 id uuid primary key,kind text not null, receipt_id uuid not null,
 actor uuid not null references public.profiles(id),edited_at timestamptz not null default now(),
 reason text not null, original jsonb not null, revised jsonb not null
);
create index receipt_edits_history on public.receipt_edits(kind,receipt_id,edited_at desc);
alter table public.receipt_edits enable row level security;
revoke all on public.receipt_edits from public,anon,authenticated;
grant select on public.receipt_edits to authenticated;
create policy manager_receipt_history on public.receipt_edits for select to authenticated using ((select private.staff_role()) in ('owner','admin'));

create function public.receipt_edit_data(p_kind text,p_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare doc jsonb;
begin
 perform private.require_manager();
 if p_kind='sale' then
 select jsonb_build_object('number',s.receipt_number,'total',s.final_amount,'discount',s.discount,'lines',
 (select jsonb_agg(jsonb_build_object('id',i.id,'name',i.name_snapshot,'units',i.quantity,'size',1,'price',i.unit_price,'discount',0) order by i.id) from public.sale_items i where i.sale_id=s.id),'payments','[]'::jsonb)
 into strict doc from public.sales s where s.id=p_id;
 elsif p_kind='purchase' then
 select jsonb_build_object('number',s.invoice_number,'total',s.total,'discount',0,'lines',
 (select jsonb_agg(jsonb_build_object('id',i.id,'name',i.name_snapshot,'units',i.packs,'size',i.pack_size,'price',i.pack_price,'discount',i.discount) order by i.id) from public.purchase_items i where i.purchase_id=s.id),
 'payments',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'amount',p.amount,'source',p.funding_source,'date',p.created_at) order by p.id),'[]'::jsonb) from public.supplier_payments p where p.purchase_id=s.id))
 into strict doc from public.purchases s where s.id=p_id;
 else raise exception 'Unknown receipt type';end if;
 return doc;
end $$;

create function public.edit_receipt(p_kind text,p_id uuid,p_before jsonb,p_lines jsonb,p_discount numeric,p_payments jsonb,p_reason text,p_request uuid)
returns void language plpgsql security definer set search_path='' as $$
declare original jsonb; revised jsonb; line record; entry record; item public.sale_items; batch public.purchase_items; product public.products; lot record;
 qty numeric;delta numeric;leftover numeric;take_qty numeric;line_net numeric;gross numeric:=0;paid numeric:=0;new_value numeric;discount numeric:=p_discount;
begin
 perform private.require_manager();
 if p_kind='sale' then
 perform 1 from public.sales where id=p_id for update;
 perform 1 from public.sale_items where sale_id=p_id order by id for update;
 elsif p_kind='purchase' then perform 1 from public.purchases where id=p_id for update;
 else raise exception 'Unknown receipt type';end if;
 if exists(select 1 from public.receipt_edits where id=p_request and kind=p_kind and receipt_id=p_id and actor=auth.uid()) then return;end if;
 original:=public.receipt_edit_data(p_kind,p_id);
 if original is distinct from p_before then raise exception 'وەسڵەکە گۆڕاوە. دایبخە و دووبارە بیکەرەوە.';end if;
 if nullif(trim(p_reason),'') is null or length(p_reason)>500 or p_request is null then raise exception 'هۆکاری دەستکاری بنووسە';end if;
 if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_typeof(p_payments) is distinct from 'array' then raise exception 'Invalid items';end if;
 if jsonb_array_length(p_lines)<>jsonb_array_length(original->'lines') or (select count(distinct l->>'id') from jsonb_array_elements(p_lines) l)<>jsonb_array_length(p_lines) then raise exception 'Missing or duplicate line';end if;
 if p_kind='sale' and exists(select from public.sale_returns where sale_id=p_id) then raise exception 'ئەم وەسڵە گەڕاندنەوەی هەیە. بڕ و نرخی فرۆشتنەکە پارێزراون.';end if;
 for line in select * from jsonb_to_recordset(p_lines) as x(id uuid,units numeric,size numeric,price numeric,discount numeric) order by id loop
 if line.units is null or line.size is null or line.price is null or line.discount is null or line.units not between .001 and 99999999 or line.size not between .001 and 99999999 or line.price not between 0 and 999999999999 or line.discount not between 0 and 999999999999 or line.units<>round(line.units,3) or line.size<>round(line.size,3) or line.price<>round(line.price,2) or line.discount<>round(line.discount,2) then raise exception 'بڕ یان نرخ نادروستە';end if;
 qty:=line.units*line.size;
 line_net:=round(line.units*line.price,2)-line.discount;
 if qty<>round(qty,3) or line_net<0 then raise exception 'بڕ یان داشکاندن نادروستە';end if;
 if p_kind='sale' then
 select * into strict item from public.sale_items where id=line.id and sale_id=p_id;
 select * into strict product from public.products where id=item.product_id for update;
 delta:=qty-item.quantity;
 if line.size<>1 or line.discount<>0 or delta>product.stock_quantity then raise exception 'بڕی کۆگا بەس نییە یان ڕیزی فرۆشتن نادروستە';end if;
 if delta<0 then
 leftover:=-delta;
 for lot in select * from public.sale_lots where sale_item_id=item.id order by purchase_item_id for update loop
 take_qty:=least(leftover,lot.quantity);
 update public.purchase_items set remaining=remaining+take_qty where id=lot.purchase_item_id;
 if take_qty=lot.quantity then delete from public.sale_lots where sale_item_id=item.id and purchase_item_id=lot.purchase_item_id;
 else update public.sale_lots set quantity=quantity-take_qty where sale_item_id=item.id and purchase_item_id=lot.purchase_item_id;end if;
 leftover:=leftover-take_qty;exit when leftover=0;end loop;
 end if;
 if delta<>0 then
 perform set_config('market.sale_item',item.id::text,true);perform set_config('market.reason','sale_edit',true);
 update public.products set stock_quantity=stock_quantity-delta,updated_at=now() where id=product.id;
 end if;
 update public.sale_items set unit_price=line.price,quantity=qty where id=item.id;
 else
 select * into strict batch from public.purchase_items where id=line.id and purchase_id=p_id;
 select * into strict product from public.products where id=batch.product_id for update;
 select * into strict batch from public.purchase_items where id=line.id and purchase_id=p_id for update;
 delta:=qty-batch.quantity;
 if batch.remaining+delta<0 then raise exception 'بڕی نوێ کەمترە لە بڕی بەکارهاتووی ئەم دەفعەیە';end if;
 new_value:=product.stock_quantity*product.purchase_price+(batch.remaining+delta)*line_net/qty-batch.remaining*batch.net_amount/batch.quantity;
 if delta<>0 or line_net<>batch.net_amount then
 if delta<>0 then perform set_config('market.purchase_item',batch.id::text,true);perform set_config('market.reason','purchase_edit',true);end if;
 update public.products set stock_quantity=stock_quantity+delta,purchase_price=case when stock_quantity+delta>0 then greatest(0,round(new_value/(stock_quantity+delta),2)) else purchase_price end,updated_at=now() where id=product.id;
 end if;
 update public.purchase_items set packs=line.units,pack_size=line.size,pack_price=line.price,discount=line.discount,quantity=qty,net_amount=line_net,remaining=remaining+delta where id=batch.id;
 end if;
 if product.unit not in ('kg','litre') and qty<>trunc(qty) then raise exception 'کاڵای دانەیی بڕی تەواو وەردەگرێت';end if;
 gross:=gross+line_net;
 end loop;
 if p_kind='sale' then
 if discount is null or discount not between 0 and round(gross*.20,2) or discount<>round(discount,2) or jsonb_array_length(p_payments)>0 then raise exception 'داشکاندن دەبێت لە نێوان سفر و ٢٠٪ بێت';end if;
 with amounts as (select id,round(quantity*unit_price,2) line,sum(round(quantity*unit_price,2)) over(order by id) running from public.sale_items where sale_id=p_id)
 update public.sale_items i set net_amount=coalesce(round(a.running*(gross-discount)/nullif(gross,0),2)-round((a.running-a.line)*(gross-discount)/nullif(gross,0),2),0) from amounts a where i.id=a.id;
 update public.sales set total=gross,discount=p_discount,final_amount=gross-p_discount where id=p_id;
 else
 if (select count(distinct e->>'id') from jsonb_array_elements(p_payments)e)<>jsonb_array_length(p_payments) then raise exception 'Duplicate payment';end if;
 for entry in select * from jsonb_to_recordset(p_payments) as x(id uuid,amount numeric,source text) loop
 if entry.amount is null or entry.amount<=0 or entry.amount<>round(entry.amount,2) or entry.source not in ('register','owner') then raise exception 'پارەدان نادروستە';end if;
 if entry.source is null and not exists(select 1 from public.supplier_payments where id=entry.id and purchase_id=p_id and funding_source is null) then raise exception 'سەرچاوەی پارە دیاری بکە';end if;
 update public.supplier_payments set amount=entry.amount,funding_source=entry.source where id=entry.id and purchase_id=p_id;
 if not found then insert into public.supplier_payments(id,purchase_id,amount,created_by,funding_source) values(entry.id,p_id,entry.amount,auth.uid(),entry.source);end if;
 paid:=paid+entry.amount;
 end loop;
 if paid>gross then raise exception 'پارەی دراو زیاترە لە کۆی وەسڵ';end if;
 delete from public.supplier_payments p where p.purchase_id=p_id and not exists(select 1 from jsonb_array_elements(p_payments)e where (e->>'id')::uuid=p.id);
 update public.purchases set total=gross where id=p_id;
 end if;
 revised:=public.receipt_edit_data(p_kind,p_id);
 insert into public.receipt_edits(id,kind,receipt_id,actor,reason,original,revised) values(p_request,p_kind,p_id,auth.uid(),trim(p_reason),original,revised);
end $$;
revoke all on function public.edit_receipt(text,uuid,jsonb,jsonb,numeric,jsonb,text,uuid),public.receipt_edit_data(text,uuid) from public,anon,authenticated;
grant execute on function public.edit_receipt(text,uuid,jsonb,jsonb,numeric,jsonb,text,uuid),public.receipt_edit_data(text,uuid) to authenticated;
