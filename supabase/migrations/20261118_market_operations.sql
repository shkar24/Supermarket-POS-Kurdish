-- Monetary snapshots, purchasing, stock provenance and fractional quantities.
alter table public.products alter stock_quantity type numeric(16,3);
alter table public.sale_items alter quantity type numeric(16,3), add column unit_cost numeric(16,4), add column cost_estimated boolean not null default false, add column barcode_snapshot text, add column unit_snapshot text, add column net_amount numeric(16,2);
alter table public.sale_return_items alter quantity type numeric(16,3), add column restocked boolean not null default true;
alter table public.inventory_movements alter quantity_change type numeric(16,3), add column sale_item_id uuid references public.sale_items, add column return_item_id uuid references public.sale_return_items;
alter table public.sales add column request_id uuid unique, add column request_body jsonb;
update public.sale_items i set unit_cost=p.purchase_price,cost_estimated=true from public.products p where p.id=i.product_id;
update public.sale_items set cost_estimated=true where unit_cost is null;
-- Cumulative rounding makes line amounts sum to the exact receipt total.
with parts as (select i.id,i.unit_price*i.quantity line_total,s.total,s.final_amount,
 sum(i.unit_price*i.quantity) over(partition by i.sale_id order by i.id) running from public.sale_items i join public.sales s on s.id=i.sale_id)
update public.sale_items i set net_amount=coalesce(round(running*final_amount/nullif(total,0),2)-round((running-line_total)*final_amount/nullif(total,0),2),0) from parts where parts.id=i.id;
alter table public.sale_items alter net_amount set not null;

create table public.suppliers(id uuid primary key default gen_random_uuid(), name text not null check(trim(name)<>''),phone text,address text,active boolean not null default true);
create table public.purchases(id uuid primary key, supplier_id uuid not null references public.suppliers, invoice_number text not null check(trim(invoice_number)<>''),invoice_date date not null,created_at timestamptz not null default now(),created_by uuid not null references public.profiles,total numeric(16,2) not null check(total>=0),unique(supplier_id,invoice_number));
create table public.purchase_items(id uuid primary key default gen_random_uuid(),purchase_id uuid not null references public.purchases,product_id uuid not null references public.products,name_snapshot text not null,packs numeric(16,3) not null check(packs>0),pack_size numeric(16,3) not null check(pack_size>0),pack_price numeric(16,2) not null check(pack_price>=0),discount numeric(16,2) not null check(discount>=0),quantity numeric(16,3) not null check(quantity>0),net_amount numeric(16,2) not null check(net_amount>=0),expires_on date,remaining numeric(16,3) not null check(remaining between 0 and quantity));
create table public.supplier_payments(id uuid primary key,purchase_id uuid not null references public.purchases,amount numeric(16,2) not null check(amount>0),created_at timestamptz not null default now(),created_by uuid not null references public.profiles);
create table public.sale_lots(sale_item_id uuid references public.sale_items,purchase_item_id uuid references public.purchase_items,quantity numeric(16,3) not null,restored numeric(16,3) not null default 0,primary key(sale_item_id,purchase_item_id));
alter table public.inventory_movements add column purchase_item_id uuid references public.purchase_items;
create index purchase_supplier on public.purchases(supplier_id);
create index purchase_lines on public.purchase_items(purchase_id);
create index stock_batches on public.purchase_items(product_id,expires_on) where remaining>0;
create index invoice_payments on public.supplier_payments(purchase_id);
do $$ declare t text;begin
 foreach t in array array['suppliers','purchases','purchase_items','supplier_payments','sale_lots'] loop
 execute format('alter table public.%I enable row level security',t);
 execute format('revoke all on public.%I from public,anon,authenticated',t);
 execute format('grant select on public.%I to authenticated',t);
 execute format('create policy management_read on public.%I for select to authenticated using ((select private.staff_role()) in (''owner'',''admin''))',t);
 end loop;end $$;
grant insert(name,phone,address) on public.suppliers to authenticated;
create policy supplier_add on public.suppliers for insert to authenticated with check((select private.staff_role()) in ('owner','admin'));

create function private.require_manager() returns void language plpgsql set search_path='' as $$
begin if coalesce(private.staff_role(),'') not in ('owner','admin') then raise exception 'Management permission required'; end if;end $$;
-- Every product stock write is journalled, including manual product edits.
create function private.stock_journal() returns trigger language plpgsql security definer set search_path='' as $$
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
if delta<0 then
needed:=-delta;
for lot in select id,remaining from public.purchase_items where product_id=new.id and remaining>0 and (sid is null or expires_on is null or expires_on >= (now() at time zone 'Asia/Baghdad')::date) order by expires_on nulls last,id for update loop
taken:=least(needed,lot.remaining);
update public.purchase_items set remaining=remaining-taken where id=lot.id;
if sid is not null then insert into public.sale_lots values(sid,lot.id,taken,0);end if;
needed:=needed-taken;exit when needed=0;
end loop;
if sid is not null and new.stock_quantity<(select coalesce(sum(remaining),0) from public.purchase_items where product_id=new.id) then raise exception 'Available unexpired stock is insufficient';end if;
end if;
perform set_config('market.sale_item','',true);perform set_config('market.purchase_item','',true);perform set_config('market.return_item','',true);perform set_config('market.reason','',true);
return new;end $$;
create trigger market_stock after insert or update of stock_quantity on public.products for each row execute function private.stock_journal();

create or replace function public.receive_stock(p_product_id uuid,p_quantity integer,p_reason text default 'Stock received') returns integer language plpgsql security definer set search_path='' as $$
declare qty numeric;begin perform private.require_manager();if p_quantity is null or p_quantity not between 1 and 1000000 then raise exception 'Invalid quantity';end if;
perform set_config('market.reason',coalesce(nullif(trim(p_reason),''),'received'),true);
update public.products set stock_quantity=stock_quantity+p_quantity,updated_at=now() where id=p_product_id and active returning stock_quantity into strict qty;
return qty::integer;end $$;

create function public.record_purchase(p_id uuid,p_supplier uuid,p_invoice text,p_date date,p_items jsonb,p_paid numeric) returns uuid language plpgsql security definer set search_path='' as $$
declare line record;p public.products;qty numeric;net numeric;v_total numeric:=0;lid uuid;
begin perform private.require_manager();
if p_id is null or p_paid is null or p_paid<0 or p_date is null or nullif(trim(p_invoice),'') is null or jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) not between 1 and 200 then raise exception 'Invalid purchase';end if;
perform pg_advisory_xact_lock(hashtextextended(p_id::text,0));
if exists(select 1 from public.purchases where id=p_id and created_by=auth.uid()) then return p_id;end if;
insert into public.purchases values(p_id,p_supplier,trim(p_invoice),p_date,now(),auth.uid(),0);
for line in select * from jsonb_to_recordset(p_items) as x(product_id uuid,packs numeric,pack_size numeric,pack_price numeric,discount numeric,expires_on date) order by product_id loop
select * into strict p from public.products where id=line.product_id and active for update;
qty:=line.packs*line.pack_size;net:=round(line.packs*line.pack_price-line.discount,2);
if qty<>round(qty,3) or qty<=0 or net<0 or (p.unit not in ('kg','litre') and qty<>trunc(qty)) then raise exception 'Invalid purchase line';end if;
insert into public.purchase_items(purchase_id,product_id,name_snapshot,packs,pack_size,pack_price,discount,quantity,net_amount,expires_on,remaining) values(p_id,p.id,p.name,line.packs,line.pack_size,line.pack_price,line.discount,qty,net,line.expires_on,qty) returning id into lid;
perform set_config('market.purchase_item',lid::text,true);perform set_config('market.reason','purchase',true);
update public.products set purchase_price=round((stock_quantity*purchase_price+net)/(stock_quantity+qty),2),stock_quantity=stock_quantity+qty,updated_at=now() where id=p.id;
v_total:=v_total+net;
end loop;
if p_paid>v_total then raise exception 'Payment exceeds invoice';end if;
update public.purchases set total=v_total where id=p_id;
if p_paid>0 then insert into public.supplier_payments values(gen_random_uuid(),p_id,p_paid,now(),auth.uid());end if;
return p_id;end $$;

create function public.pay_supplier(p_id uuid,p_purchase uuid,p_amount numeric) returns uuid language plpgsql security definer set search_path='' as $$
declare due numeric;begin perform private.require_manager();
select total into strict due from public.purchases where id=p_purchase for update;
if exists(select 1 from public.supplier_payments where id=p_id and purchase_id=p_purchase and amount=p_amount) then return p_id;end if;
select due-coalesce(sum(amount),0) into due from public.supplier_payments where purchase_id=p_purchase;
if p_amount<=0 or p_amount>due then raise exception 'Invalid payment';end if;
insert into public.supplier_payments values(p_id,p_purchase,p_amount,now(),auth.uid());return p_id;end $$;

create function public.market_checkout(p_items jsonb,p_discount numeric,p_payment_method text,p_request uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare staff text:=private.staff_role(); body jsonb:=jsonb_build_array(p_items,p_discount,p_payment_method);s public.sales;line record;p public.products;gross numeric:=0;running numeric:=0;amount numeric;line_id uuid;
begin
if coalesce(staff,'') not in ('owner','admin','cashier') then raise exception 'Active staff required';end if;
if p_request is null or p_payment_method is distinct from 'cash' or jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) not between 1 and 200 or p_discount is null or p_discount<0 or p_discount<>round(p_discount,2) or (staff='cashier' and p_discount<>0) then raise exception 'Invalid checkout';end if;
perform pg_advisory_xact_lock(hashtextextended(p_request::text,0));
select * into s from public.sales where request_id=p_request;
if found then
if s.cashier_id<>auth.uid() or s.request_body<>body then raise exception 'Request differs from prior sale';end if;
else
for line in select * from jsonb_to_recordset(p_items) as x(product_id uuid,quantity numeric) order by product_id loop
select * into strict p from public.products where id=line.product_id and active for update;
if line.quantity is null or line.quantity not between 0.001 and least(100000,p.stock_quantity) or line.quantity<>round(line.quantity,3) or (p.unit not in ('kg','litre') and line.quantity<>trunc(line.quantity)) then raise exception 'Invalid quantity or insufficient stock';end if;
gross:=gross+round(line.quantity*p.price,2);end loop;
if p_discount>round(gross*0.2,2) then raise exception 'Discount exceeds 20 percent';end if;
insert into public.sales(receipt_number,cashier_id,total,discount,final_amount,payment_method,request_id,request_body) values('POS-'||replace(gen_random_uuid()::text,'-',''),auth.uid(),gross,p_discount,gross-p_discount,'cash',p_request,body) returning * into s;
for line in select * from jsonb_to_recordset(p_items) as x(product_id uuid,quantity numeric) order by product_id loop
select * into strict p from public.products where id=line.product_id;
amount:=round(line.quantity*p.price,2);
insert into public.sale_items(sale_id,product_id,name_snapshot,quantity,unit_price,unit_cost,barcode_snapshot,unit_snapshot,net_amount)
values(s.id,p.id,p.name,line.quantity,p.price,p.purchase_price,p.barcode,p.unit,coalesce(round((running+amount)*s.final_amount/nullif(gross,0),2)-round(running*s.final_amount/nullif(gross,0),2),0)) returning id into line_id;
running:=running+amount;
perform set_config('market.sale_item',line_id::text,true);perform set_config('market.reason','sale',true);
update public.products set stock_quantity=stock_quantity-line.quantity,updated_at=now() where id=p.id;
end loop;end if;
return jsonb_build_object('sale_id',s.id,'receipt_number',s.receipt_number,'total',s.final_amount,'created_at',s.created_at,'lines',(select jsonb_agg(jsonb_build_object('name',name_snapshot,'price',unit_price,'qty',quantity,'net',net_amount)) from public.sale_items where sale_id=s.id));
end $$;
create or replace function public.checkout_sale(p_items jsonb,p_discount numeric default 0,p_payment_method text default 'cash') returns jsonb language sql security definer set search_path='' as $$select public.market_checkout(p_items,p_discount,p_payment_method,gen_random_uuid())$$;

create function public.market_return(p_sale_item_id uuid,p_quantity numeric,p_reason text,p_restock boolean,p_request uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare i public.sale_items;previous numeric;amount numeric;rid uuid;lot record;needed numeric:=p_quantity;taken numeric;
begin perform private.require_manager();
select * into strict i from public.sale_items where id=p_sale_item_id for update;
if exists(select 1 from public.sale_returns where id=p_request) then return jsonb_build_object('return_id',p_request);end if;
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
return jsonb_build_object('return_id',p_request,'amount',amount);end $$;
create or replace function public.return_sale_item(p_sale_item_id uuid,p_quantity integer,p_reason text default '') returns jsonb language sql security definer set search_path='' as $$select public.market_return(p_sale_item_id,p_quantity,p_reason,true,gen_random_uuid())$$;

create or replace function public.sales_financial_summary(p_start timestamptz,p_end timestamptz) returns jsonb language plpgsql security definer set search_path='' as $$
declare n int;gross numeric;cost numeric;restored_cost numeric;refund numeric;expense numeric;est boolean;
begin perform private.require_manager();
if p_start is null or p_end<=p_start or p_end is null or p_end>p_start+interval '370 days' then raise exception 'Invalid period';end if;
select count(*),coalesce(sum(final_amount),0) into n,gross from public.sales where created_at>=p_start and created_at<p_end;
select coalesce(sum(i.unit_cost*i.quantity),0),coalesce(bool_or(i.cost_estimated),false) into cost,est from public.sale_items i join public.sales s on s.id=i.sale_id where s.created_at>=p_start and s.created_at<p_end;
select coalesce(sum(i.unit_cost*r.quantity),0),est or coalesce(bool_or(i.cost_estimated),false) into restored_cost,est from public.sale_return_items r join public.sale_returns t on t.id=r.return_id join public.sale_items i on i.id=r.sale_item_id where r.restocked and t.created_at>=p_start and t.created_at<p_end;
select coalesce(sum(amount),0) into refund from public.sale_returns where created_at>=p_start and created_at<p_end;
select coalesce(sum(amount),0) into expense from public.expenses where created_at>=p_start and created_at<p_end;
return jsonb_build_object('count',n,'gross',gross,'cost_estimate',round(cost-restored_cost,2),'returns',refund,'expenses',expense,'estimated_profit',round(gross-cost+restored_cost-refund-expense,2),'historical_estimate',est);end $$;
do $$ declare f regprocedure;begin
foreach f in array array['public.market_checkout(jsonb,numeric,text,uuid)'::regprocedure,'public.market_return(uuid,numeric,text,boolean,uuid)'::regprocedure,'public.pay_supplier(uuid,uuid,numeric)'::regprocedure,'public.record_purchase(uuid,uuid,text,date,jsonb,numeric)'::regprocedure] loop
execute format('revoke all on function %s from public,anon,authenticated',f);
execute format('grant execute on function %s to authenticated',f);end loop;end $$;
