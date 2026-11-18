create table public.credit_customers (
 id uuid primary key default gen_random_uuid(),
 name text not null check(length(trim(name)) between 1 and 160),
 name_key text generated always as (lower(name)) stored unique
);
alter table public.credit_customers enable row level security;
revoke all on public.credit_customers from public,anon,authenticated;
grant select(id,name) on public.credit_customers to authenticated;
create policy staff_customer_names on public.credit_customers for select to authenticated using ((select private.staff_role()) in ('cashier','admin','owner'));
alter table public.sales add column credit_customer_id uuid references public.credit_customers;
create index sales_credit_customer on public.sales(credit_customer_id) where credit_customer_id is not null;
create function private.assign_credit_customer() returns trigger language plpgsql security definer set search_path='' as $$
declare cleaned text;
begin
 if new.payment_method='credit' then
 cleaned:=trim(regexp_replace(new.customer_name,'[[:space:]]+',' ','g'));
 insert into public.credit_customers(name) values(cleaned)
 on conflict(name_key) do update set name=credit_customers.name returning id,name into new.credit_customer_id,new.customer_name;
 end if;
 return new;
end $$;
revoke all on function private.assign_credit_customer() from public,anon,authenticated;
create trigger assign_credit_customer before insert or update of customer_name on public.sales for each row execute function private.assign_credit_customer();
update public.sales set customer_name=customer_name where payment_method='credit';
create function public.period_receipts(p_start timestamptz,p_end timestamptz) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare staff text:=private.staff_role(); mine boolean; n bigint; cash numeric;credit_total numeric;initial numeric;collections numeric;refunds numeric;relief numeric;
begin
 if coalesce(staff,'') not in ('owner','admin','cashier') then raise exception 'Active staff required';end if;
 if p_start is null or p_end is null or p_end<=p_start or p_end-p_start>interval '370 days' then raise exception 'Invalid period';end if;
 mine:=staff='cashier';
 select count(*),coalesce(sum(final_amount) filter(where payment_method='cash'),0),coalesce(sum(final_amount) filter(where payment_method='credit'),0)
 into n,cash,credit_total from public.sales where created_at>=p_start and created_at<p_end and (not mine or cashier_id=auth.uid());
 select coalesce(sum(p.amount) filter(where p.id=s.request_id),0),coalesce(sum(p.amount) filter(where p.id is distinct from s.request_id),0)
 into initial,collections from public.customer_payments p join public.sales s on s.id=p.sale_id where p.received_at>=p_start and p.received_at<p_end and (not mine or s.cashier_id=auth.uid());
 select coalesce(sum(coalesce(r.cash_refunded,r.amount)),0),coalesce(sum(r.amount-coalesce(r.cash_refunded,r.amount)),0)
 into refunds,relief from public.sale_returns r join public.sales s on s.id=r.sale_id where r.created_at>=p_start and r.created_at<p_end and (not mine or s.cashier_id=auth.uid());
 return jsonb_build_object('count',n,'cash_sales',cash,'initial',initial,'collections',collections,'refunds',refunds,'cash_net',cash+initial+collections-refunds,'credit_issued',credit_total-initial,'debt_cancelled',relief);
end $$;
revoke all on function public.period_receipts(timestamptz,timestamptz) from public,anon,authenticated;
grant execute on function public.period_receipts(timestamptz,timestamptz) to authenticated;