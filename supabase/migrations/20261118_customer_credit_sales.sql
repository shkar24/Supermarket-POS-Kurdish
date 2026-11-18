alter table public.sales add column customer_name text,add column credit_received numeric(16,2) not null default 0,add column debt_cancelled numeric(16,2) not null default 0;
alter table public.sales add column credit_due numeric(16,2) generated always as(case when payment_method='credit' then final_amount-credit_received-debt_cancelled else 0 end) stored,add constraint valid_credit_balance check(payment_method<>'credit' or (customer_name is not null and credit_received>=0 and debt_cancelled>=0 and final_amount>=credit_received+debt_cancelled));
create table public.customer_payments(id uuid primary key,sale_id uuid not null references public.sales,amount numeric(16,2) not null check(amount>0),received_at timestamptz not null default now(),received_by uuid not null references public.profiles);
create index customer_payments_sale on public.customer_payments(sale_id);
alter table public.customer_payments enable row level security;
revoke all on public.customer_payments from public,anon,authenticated;
grant select on public.customer_payments to authenticated;
create policy visible_customer_payments on public.customer_payments for select to authenticated using(exists(select from public.sales s where s.id=sale_id));
create index open_credit_sales on public.sales(created_at desc) where payment_method='credit' and credit_due>0;
alter table public.sale_returns add column cash_refunded numeric(16,2);
create function private.split_credit_return() returns trigger language plpgsql security definer set search_path='' as $$
declare s public.sales; relief numeric;
begin select * into strict s from public.sales where id=new.sale_id for update;
relief:=least(s.credit_due,new.amount);
if relief>0 then update public.sales set debt_cancelled=debt_cancelled+relief where id=s.id;end if;
new.cash_refunded:=new.amount-relief;return new;end $$;
create trigger credit_return before insert on public.sale_returns for each row execute function private.split_credit_return();
CREATE OR REPLACE FUNCTION public.checkout_with_credit(p_items jsonb, p_discount numeric, p_payment_method text, p_request uuid,p_customer text,p_initial numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare staff text:=private.staff_role(); body jsonb:=case when p_payment_method='cash' then jsonb_build_array(p_items,p_discount,p_payment_method) else jsonb_build_array(p_items,p_discount,p_payment_method,trim(p_customer),p_initial) end;s public.sales;line record;p public.products;gross numeric:=0;running numeric:=0;amount numeric;line_id uuid;
begin
if coalesce(staff,'') not in ('owner','admin','cashier') then raise exception 'Active staff required';end if;
if p_request is null or coalesce(p_payment_method,'') not in ('cash','credit') or jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) not between 1 and 200 or p_discount is null or p_discount<0 or p_discount<>round(p_discount,2) or (staff='cashier' and p_discount<>0) then raise exception 'Invalid checkout';end if;
if p_payment_method='credit' and (nullif(trim(p_customer),'') is null or length(trim(p_customer))>160 or p_initial is null or p_initial<0 or p_initial<>round(p_initial,2)) then raise exception 'ناوی کڕیار و بڕی پارەی دراو بپشکنە';end if;
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
insert into public.sales(receipt_number,cashier_id,total,discount,final_amount,payment_method,request_id,request_body,customer_name,credit_received) values('POS-'||replace(gen_random_uuid()::text,'-',''),auth.uid(),gross,p_discount,gross-p_discount,p_payment_method,p_request,body,case when p_payment_method='credit' then trim(p_customer) end,case when p_payment_method='credit' then p_initial else 0 end) returning * into s;
if p_payment_method='credit' and p_initial>0 then
 insert into public.customer_payments(id,sale_id,amount,received_by) values(p_request,s.id,p_initial,auth.uid());
end if;
for line in select * from jsonb_to_recordset(p_items) as x(product_id uuid,quantity numeric) order by product_id loop
select * into strict p from public.products where id=line.product_id;
amount:=round(line.quantity*p.price,2);
insert into public.sale_items(sale_id,product_id,name_snapshot,quantity,unit_price,unit_cost,barcode_snapshot,unit_snapshot,net_amount)
values(s.id,p.id,p.name,line.quantity,p.price,p.purchase_price,p.barcode,p.unit,coalesce(round((running+amount)*s.final_amount/nullif(gross,0),2)-round(running*s.final_amount/nullif(gross,0),2),0)) returning id into line_id;
running:=running+amount;
perform set_config('market.sale_item',line_id::text,true);perform set_config('market.reason','sale',true);
update public.products set stock_quantity=stock_quantity-line.quantity,updated_at=now() where id=p.id;
end loop;end if;
return jsonb_build_object('payment_method',s.payment_method,'customer_name',s.customer_name,'due',s.credit_due,'sale_id',s.id,'receipt_number',s.receipt_number,'total',s.final_amount,'created_at',s.created_at,'lines',(select jsonb_agg(jsonb_build_object('name',name_snapshot,'price',unit_price,'qty',quantity,'net',net_amount)) from public.sale_items where sale_id=s.id));
end $function$
;
create function public.collect_customer_payment(p_sale uuid,p_amount numeric,p_request uuid) returns numeric language plpgsql security definer set search_path='' as $$
declare s public.sales;prev public.customer_payments;staff text:=private.staff_role();
begin select * into strict s from public.sales where id=p_sale for update;
if coalesce(staff,'') not in ('owner','admin','cashier') or (staff='cashier' and s.cashier_id<>auth.uid()) or s.payment_method<>'credit' then raise exception 'Permission denied';end if;
select * into prev from public.customer_payments where id=p_request;
if found then
 if prev.sale_id<>s.id or prev.received_by<>auth.uid() or prev.amount is distinct from p_amount then raise exception 'Payment request differs';end if;return s.credit_due;end if;
if p_amount is null or p_amount<=0 or p_amount>s.credit_due or p_amount<>round(p_amount,2) then raise exception 'بڕی وەرگیراو لە قەرزی ماوە زیاترە یان نادروستە';end if;
insert into public.customer_payments(id,sale_id,amount,received_by) values(p_request,s.id,p_amount,auth.uid());
update public.sales set credit_received=credit_received+p_amount where id=s.id returning credit_due into s.credit_due;
return s.credit_due;end $$;
CREATE OR REPLACE FUNCTION public.register_flow(p_start timestamp with time zone, p_end timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare received numeric;refunded numeric;spent numeric;paid numeric;unclassified numeric;
begin perform private.require_manager();
select coalesce(sum(final_amount),0) into received from public.sales where created_at>=p_start and created_at<p_end and payment_method='cash';
select received+coalesce(sum(amount),0) into received from public.customer_payments where received_at>=p_start and received_at<p_end;
select coalesce(sum(coalesce(cash_refunded,amount)),0) into refunded from public.sale_returns where created_at>=p_start and created_at<p_end;
select coalesce(sum(amount) filter(where funding_source='register'),0),coalesce(sum(amount) filter(where funding_source is null),0) into spent,unclassified from public.expenses where created_at>=p_start and created_at<p_end;
select coalesce(sum(amount) filter(where funding_source='register'),0),unclassified+coalesce(sum(amount) filter(where funding_source is null),0) into paid,unclassified from public.supplier_payments where created_at>=p_start and created_at<p_end;
return jsonb_build_object('net',received-refunded-spent-paid,'unclassified',unclassified);end $function$
;
revoke all on function public.checkout_with_credit(jsonb,numeric,text,uuid,text,numeric),public.collect_customer_payment(uuid,numeric,uuid) from public,anon,authenticated;
grant execute on function public.checkout_with_credit(jsonb,numeric,text,uuid,text,numeric),public.collect_customer_payment(uuid,numeric,uuid) to authenticated;
