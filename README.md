# Supermarket POS — Kurdish Sorani (Online only)

Starter implementation based on the supplied purple/white POS layout. React + TypeScript + Vite + Supabase. No local database, IndexedDB or localStorage used by app. Supabase auth uses in-memory sessions (`persistSession:false`); browser may still cache static assets.

## Setup
1. Create a NEW Supabase project.
2. Run `supabase/schema.sql` in SQL Editor.
3. Create an email/password user under Authentication > Users.
4. In SQL Editor run (replace UUID with Auth user ID):
   `insert into public.profiles(id,full_name,role) values ('USER_UUID','Owner','owner');`
5. Create products in Supabase Table Editor (public.products), e.g. name, barcode, price, stock_quantity.
6. Copy `.env.example` to `.env`, fill Supabase URL and publishable key. **Never put service_role/secret keys in frontend.**
7. `npm install && npm run dev`.
8. Deploy as Render Static Site: build command `npm ci && npm run build`, publish directory `dist`; configure the two VITE_ environment variables.

## Current scope
Functional: login, product search and barcode keyboard input, cart, quantities, discounts, atomic cash checkout with server-side stock validation, products/inventory read-only, realtime refresh when products change (enable replication for products in Supabase). UI labels are Sorani.

Not implemented yet: receipt printing, admin CRUD, returns, cashier shifts, reporting, card payments, backup automation, role management UI. These require follow-up work and verification before production use.

## Security and limitations
- Never rely on frontend prices: checkout RPC calculates all prices from database and serializes stock updates.
- No client INSERT/UPDATE permissions on sales/products; only authenticated checkout RPC can write sales.
- Supabase RPC is `security definer`, with authenticated role checks, explicit grants, and a fixed search path. Review with Supabase security advisors before production.
- This is a starter, not production-certified. Set up backups, audit logging, rate limits and test multi-cashier concurrency before real use.
- Run `npm install` to generate and commit package-lock.json for reproducible builds before deploying with `npm ci`.
