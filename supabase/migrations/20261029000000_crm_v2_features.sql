-- VAYQEN CRM v2: follow-ups, notes, settings, deletes, production role,
-- unique order refs, atomic lead creation, job photos, realtime.
-- Additive and idempotent: safe to run more than once, no existing data is dropped.

create schema if not exists private;

create or replace function private.crm_is_production(p_company_id bigint)
returns boolean language sql stable security definer set search_path to '' as $$
  select exists (select 1 from public.company_members m
    where m.company_id = p_company_id and m.user_id = (select auth.uid()) and m.role = 'production');
$$;

-- 1. Follow-up date
alter table public.crm_leads add column if not exists next_contact_at timestamptz;
create index if not exists crm_leads_next_contact_idx on public.crm_leads (company_id, next_contact_at) where next_contact_at is not null;

-- 2. Unique order reference generated in DB
create sequence if not exists public.crm_order_ref_seq;
revoke all on sequence public.crm_order_ref_seq from anon, authenticated;
create or replace function public.crm_orders_set_ref()
returns trigger language plpgsql security definer set search_path to '' as $$
begin
  if new.reference_code is null or btrim(new.reference_code) = '' then
    new.reference_code := 'LS-' || to_char(now() at time zone 'Asia/Tashkent','YYMMDD') || '-' ||
      lpad(nextval('public.crm_order_ref_seq')::text, 4, '0');
  end if;
  return new;
end; $$;
revoke execute on function public.crm_orders_set_ref() from anon, authenticated, public;
drop trigger if exists crm_orders_ref on public.crm_orders;
create trigger crm_orders_ref before insert on public.crm_orders for each row execute function public.crm_orders_set_ref();

-- 3. Production role: read orders, change status only
drop policy if exists crm_orders_read_production on public.crm_orders;
create policy crm_orders_read_production on public.crm_orders for select to authenticated
  using (private.crm_is_production(company_id));
drop policy if exists crm_orders_update_production on public.crm_orders;
create policy crm_orders_update_production on public.crm_orders for update to authenticated
  using (private.crm_is_production(company_id) and status in ('confirmed','production','installation'))
  with check (private.crm_is_production(company_id) and status in ('confirmed','production','installation'));
create or replace function public.crm_guard_order_update()
returns trigger language plpgsql set search_path to '' as $$
begin
  if (select auth.role()) = 'service_role' then return new; end if;
  if private.crm_can_sell(old.company_id) then return new; end if;
  if (to_jsonb(new) - 'status' - 'updated_at') is distinct from (to_jsonb(old) - 'status' - 'updated_at') then
    raise exception 'Only status can be changed' using errcode = '42501';
  end if;
  return new;
end; $$;
drop trigger if exists crm_orders_guard on public.crm_orders;
create trigger crm_orders_guard before update on public.crm_orders for each row execute function public.crm_guard_order_update();

-- 4. Manager deletes
drop policy if exists crm_customers_delete on public.crm_customers;
create policy crm_customers_delete on public.crm_customers for delete to authenticated using (private.crm_can_manage(company_id));
drop policy if exists crm_leads_delete on public.crm_leads;
create policy crm_leads_delete on public.crm_leads for delete to authenticated using (private.crm_can_manage(company_id));
drop policy if exists crm_orders_delete on public.crm_orders;
create policy crm_orders_delete on public.crm_orders for delete to authenticated using (private.crm_can_manage(company_id));
drop policy if exists crm_jobs_delete on public.crm_jobs;
create policy crm_jobs_delete on public.crm_jobs for delete to authenticated using (private.crm_can_manage(company_id));

-- 5. Notes / contact history
create table if not exists public.crm_notes (
  id uuid primary key default gen_random_uuid(),
  company_id bigint not null references public.companies(id),
  entity_type text not null check (entity_type in ('lead','order','customer')),
  entity_id uuid not null,
  body text not null check (length(btrim(body)) > 0),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
alter table public.crm_notes enable row level security;
create index if not exists crm_notes_entity_idx on public.crm_notes (company_id, entity_type, entity_id, created_at desc);
drop policy if exists crm_notes_read on public.crm_notes;
create policy crm_notes_read on public.crm_notes for select to authenticated
  using (private.crm_can_sell(company_id) or private.crm_can_finance(company_id));
drop policy if exists crm_notes_insert on public.crm_notes;
create policy crm_notes_insert on public.crm_notes for insert to authenticated
  with check ((private.crm_can_sell(company_id) or private.crm_can_finance(company_id)) and created_by = (select auth.uid()));
drop policy if exists crm_notes_delete on public.crm_notes;
create policy crm_notes_delete on public.crm_notes for delete to authenticated
  using (private.crm_can_manage(company_id) or created_by = (select auth.uid()));
revoke all on public.crm_notes from anon;
drop trigger if exists crm_notes_audit on public.crm_notes;
create trigger crm_notes_audit after insert or update or delete on public.crm_notes for each row execute function public.crm_audit_changes();

-- 6. Company settings (products / sources lists)
create table if not exists public.crm_company_settings (
  company_id bigint primary key references public.companies(id),
  products text[] not null default array['Markiza','Zontik','Pergola','ZIP Screen'],
  sources text[] not null default array['Instagram','Telegram','WhatsApp','Telefon','Tavsiya'],
  updated_at timestamptz not null default now()
);
alter table public.crm_company_settings enable row level security;
drop policy if exists crm_settings_read on public.crm_company_settings;
create policy crm_settings_read on public.crm_company_settings for select to authenticated using (private.is_company_member(company_id));
drop policy if exists crm_settings_insert on public.crm_company_settings;
create policy crm_settings_insert on public.crm_company_settings for insert to authenticated with check (private.crm_can_manage(company_id));
drop policy if exists crm_settings_update on public.crm_company_settings;
create policy crm_settings_update on public.crm_company_settings for update to authenticated using (private.crm_can_manage(company_id)) with check (private.crm_can_manage(company_id));
revoke all on public.crm_company_settings from anon;
drop trigger if exists crm_settings_touch on public.crm_company_settings;
create trigger crm_settings_touch before update on public.crm_company_settings for each row execute function public.crm_touch_updated_at();

-- 7. Atomic lead creation (customer + lead in one transaction, RLS applies)
create or replace function public.crm_create_lead(
  p_company_id bigint, p_name text, p_phone text, p_address text, p_source text, p_product text,
  p_notes text, p_estimated_amount numeric, p_customer_id uuid default null, p_next_contact_at timestamptz default null)
returns uuid language plpgsql security invoker set search_path to '' as $$
declare v_customer uuid := p_customer_id; v_lead uuid;
begin
  if v_customer is null then
    insert into public.crm_customers(company_id, name, phone, address)
    values (p_company_id, p_name, nullif(btrim(coalesce(p_phone,'')),''), nullif(btrim(coalesce(p_address,'')),''))
    returning id into v_customer;
  end if;
  insert into public.crm_leads(company_id, customer_id, title, source, notes, status, estimated_amount, next_contact_at)
  values (p_company_id, v_customer, coalesce(nullif(btrim(coalesce(p_product,'')),''),'Markiza'), coalesce(nullif(p_source,''),'Telefon'),
          nullif(btrim(coalesce(p_notes,'')),''), 'new', p_estimated_amount, p_next_contact_at)
  returning id into v_lead;
  return v_lead;
end; $$;
revoke execute on function public.crm_create_lead(bigint,text,text,text,text,text,text,numeric,uuid,timestamptz) from anon, public;
grant execute on function public.crm_create_lead(bigint,text,text,text,text,text,text,numeric,uuid,timestamptz) to authenticated;

-- 8. Storage bucket for job photos
insert into storage.buckets (id, name, public, file_size_limit)
values ('crm-files','crm-files', false, 10485760)
on conflict (id) do nothing;
drop policy if exists crm_files_read on storage.objects;
create policy crm_files_read on storage.objects for select to authenticated
  using (bucket_id = 'crm-files' and (storage.foldername(name))[1] ~ '^[0-9]+$'
         and private.is_company_member(((storage.foldername(name))[1])::bigint));
drop policy if exists crm_files_insert on storage.objects;
create policy crm_files_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'crm-files' and (storage.foldername(name))[1] ~ '^[0-9]+$'
         and private.is_company_member(((storage.foldername(name))[1])::bigint));
drop policy if exists crm_files_delete on storage.objects;
create policy crm_files_delete on storage.objects for delete to authenticated
  using (bucket_id = 'crm-files' and (storage.foldername(name))[1] ~ '^[0-9]+$'
         and (owner_id = (select auth.uid())::text or private.crm_can_manage(((storage.foldername(name))[1])::bigint)));

-- 9. Realtime
do $$
declare t text;
begin
  foreach t in array array['crm_customers','crm_leads','crm_orders','crm_jobs','crm_payments','crm_notes'] loop
    if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename=t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

select 'VAYQEN CRM v2 тайёр ✅' as natija;
