-- Starter schema. Review and test before production.
create extension if not exists pgcrypto;
create table if not exists public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 full_name text not null default '',
 role text not null check(role in ('owner','admin','cashier')),
 active boolean not null default true
);
create table if not exists public.products (
 id uuid primary key default gen_random_uuid(),
 name text not null,
 barcode text unique,
 price numeric(14,2) not null check(price>=0),
 stock_quantity integer not null default 0 check(stock_quantity>=0),
 active boolean not null default true,
 created_at timestamptz not null default now()
);
create table if not exists public.sales (
 id uuid primary key default gen_random_uuid(),
 receipt_number text not null unique,
 cashier_id uuid not null references public.profiles(id),
 total numeric(14,2) not null,
 discount numeric(14,2) not null default 0,
 final_amount numeric(14,2) not null,
 payment_method text not null,
 created_at timestamptz not null default now()
);
create table if not exists public.sale_items (
 id uuid primary key default gen_random_uuid(),
 sale_id uuid not null references public.sales(id),
 product_id uuid not null references public.products(id),
 name_snapshot text not null,
 quantity integer not null check(quantity>0),
 unit_price numeric(14,2) not null
);
alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;
create policy "profile self read" on public.profiles for select to authenticated using (id=(select auth.uid()));
create policy "products read for staff" on public.products for select to authenticated using (exists(select 1 from public.profiles where id=(select auth.uid()) and active));
create policy "sales own read" on public.sales for select to authenticated using(cashier_id=(select auth.uid()));
create policy "sale items own read" on public.sale_items for select to authenticated using(exists(select 1 from public.sales where id=sale_id and cashier_id=(select auth.uid())));
create or replace function public.checkout_sale(p_items jsonb,p_discount numeric default 0,p_payment_method text default 'cash')
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid(); v_role text; v_total numeric(14,2):=0; v_sale uuid; v_receipt text; v_item record; v_product record; v_count int:=0;
begin
 select role into v_role from public.profiles where id=v_user and active=true;
 if v_role is null then raise exception 'Unauthorized cashier'; end if;
 if p_payment_method <> 'cash' then raise exception 'Unsupported payment method'; end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 or jsonb_array_length(p_items)>200 then raise exception 'Invalid cart'; end if;
 if p_discount<0 then raise exception 'Invalid discount'; end if;
 -- Lock all products in deterministic order to avoid deadlocks.
 for v_item in select (e->>'product_id')::uuid as pid,sum((e->>'quantity')::int)::int as qty from jsonb_array_elements(p_items) e group by 1 order by 1 loop
   if v_item.qty<=0 then raise exception 'Invalid quantity'; end if;
   select * into v_product from public.products where id=v_item.pid and active=true for update;
   if not found or v_product.stock_quantity<v_item.qty then raise exception 'Insufficient stock'; end if;
   v_total:=v_total+v_product.price*v_item.qty; v_count:=v_count+1;
 end loop;
 if p_discount>v_total then raise exception 'Discount exceeds total'; end if;
 v_receipt:='POS-'||replace(gen_random_uuid()::text,'-','');
 insert into public.sales(receipt_number,cashier_id,total,discount,final_amount,payment_method)
 values(v_receipt,v_user,v_total,p_discount,v_total-p_discount,p_payment_method) returning id into v_sale;
 for v_item in select (e->>'product_id')::uuid as pid,sum((e->>'quantity')::int)::int as qty from jsonb_array_elements(p_items) e group by 1 order by 1 loop
   select * into v_product from public.products where id=v_item.pid for update;
   update public.products set stock_quantity=stock_quantity-v_item.qty where id=v_item.pid;
   insert into public.sale_items(sale_id,product_id,name_snapshot,quantity,unit_price)
   values(v_sale,v_item.pid,v_product.name,v_item.qty,v_product.price);
 end loop;
 return jsonb_build_object('sale_id',v_sale,'receipt_number',v_receipt,'total',v_total-p_discount);
end $$;
revoke all on function public.checkout_sale(jsonb,numeric,text) from public,anon;
grant execute on function public.checkout_sale(jsonb,numeric,text) to authenticated;
-- Create auth users in Supabase Authentication and corresponding profiles with owner/admin/cashier role.
-- Admin product editing and backup automation are not implemented yet.
