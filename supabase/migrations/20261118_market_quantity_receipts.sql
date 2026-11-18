-- Fractional receipts for weighed stock and protection against stale product edits.
create function public.receive_quantity(p_product uuid,p_quantity numeric,p_reason text) returns numeric language plpgsql security definer set search_path='' as $$
declare balance numeric;begin perform private.require_manager();
if p_quantity is null or p_quantity not between .001 and 1000000 or p_quantity<>round(p_quantity,3) then raise exception 'Invalid quantity';end if;
perform set_config('market.reason',coalesce(nullif(trim(p_reason),''),'received'),true);
update public.products set stock_quantity=stock_quantity+p_quantity,updated_at=now() where id=p_product and active returning stock_quantity into strict balance;
return balance;end $$;
revoke all on function public.receive_quantity(uuid,numeric,text) from public,anon,authenticated;
grant execute on function public.receive_quantity(uuid,numeric,text) to authenticated;
revoke all privileges on public.cashier_shifts from anon,authenticated,public;
