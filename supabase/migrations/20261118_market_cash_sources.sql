alter table public.expenses add column funding_source text check(funding_source in ('register','owner'));
alter table public.supplier_payments add column funding_source text check(funding_source in ('register','owner'));
create function public.market_purchase(p_id uuid,p_supplier uuid,p_invoice text,p_date date,p_items jsonb,p_paid numeric,p_source text) returns uuid language plpgsql security definer set search_path='' as $$
declare invoice uuid;
begin perform private.require_manager();
if p_source is null or p_source not in ('register','owner') then raise exception 'Invalid funding source';end if;
invoice:=public.record_purchase(p_id,p_supplier,p_invoice,p_date,p_items,p_paid);
update public.supplier_payments set funding_source=p_source where purchase_id=invoice and funding_source is null;
return invoice;end $$;
create function public.market_payment(p_id uuid,p_purchase uuid,p_amount numeric,p_source text) returns uuid language plpgsql security definer set search_path='' as $$
begin perform private.require_manager();
if p_source is null or p_source not in ('register','owner') then raise exception 'Invalid funding source';end if;
perform public.pay_supplier(p_id,p_purchase,p_amount);
update public.supplier_payments set funding_source=p_source where id=p_id and funding_source is null;
return p_id;end $$;
create function public.register_flow(p_start timestamptz,p_end timestamptz) returns jsonb language plpgsql security definer set search_path='' as $$
declare received numeric;refunded numeric;spent numeric;paid numeric;unclassified numeric;
begin perform private.require_manager();
select coalesce(sum(final_amount),0) into received from public.sales where created_at>=p_start and created_at<p_end and payment_method='cash';
select coalesce(sum(amount),0) into refunded from public.sale_returns where created_at>=p_start and created_at<p_end;
select coalesce(sum(amount) filter(where funding_source='register'),0),coalesce(sum(amount) filter(where funding_source is null),0) into spent,unclassified from public.expenses where created_at>=p_start and created_at<p_end;
select coalesce(sum(amount) filter(where funding_source='register'),0),unclassified+coalesce(sum(amount) filter(where funding_source is null),0) into paid,unclassified from public.supplier_payments where created_at>=p_start and created_at<p_end;
return jsonb_build_object('net',received-refunded-spent-paid,'unclassified',unclassified);end $$;
revoke execute on function public.record_purchase(uuid,uuid,text,date,jsonb,numeric),public.pay_supplier(uuid,uuid,numeric) from authenticated;
revoke all on function public.market_purchase(uuid,uuid,text,date,jsonb,numeric,text),public.market_payment(uuid,uuid,numeric,text),public.register_flow(timestamptz,timestamptz) from public,anon,authenticated;
grant execute on function public.market_purchase(uuid,uuid,text,date,jsonb,numeric,text),public.market_payment(uuid,uuid,numeric,text),public.register_flow(timestamptz,timestamptz) to authenticated;