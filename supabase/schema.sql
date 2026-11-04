create extension if not exists pgcrypto;

create table if not exists public.admin_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique default 'RulzzAdmin',
  created_at timestamptz not null default now()
);

create table if not exists public.site_settings (
  id integer primary key default 1 check (id = 1),
  store_open boolean not null default true,
  price_per_hour integer not null default 20000 check (price_per_hour >= 0),
  payment_number text not null default '083102029092',
  payment_name text not null default 'Rulzz Store',
  methods jsonb not null default '{"DANA":true,"GoPay":true,"OVO":true,"QRIS":true}'::jsonb,
  updated_at timestamptz not null default now()
);
insert into public.site_settings(id) values (1) on conflict do nothing;

create table if not exists public.ba_schedules (
  id uuid primary key default gen_random_uuid(),
  server_name text not null check (char_length(server_name) between 1 and 80),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  status text not null default 'OPEN' check (status in ('OPEN','CLOSED')),
  note text not null default '',
  created_at timestamptz not null default now(),
  check (ends_at = starts_at + interval '3 hours')
);

create sequence if not exists public.rulzz_order_seq start with 98000 increment by 1;

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  order_code text unique not null default ('RULZ50000' || lpad(nextval('public.rulzz_order_seq')::text,5,'0')),
  buyer_name text not null check (char_length(buyer_name) between 1 and 70),
  buyer_phone text not null check (char_length(buyer_phone) between 8 and 20),
  service text not null check (service in ('Growtopia BA','Live Gaming','Jadwal Flexible')),
  server_detail text not null check (char_length(server_detail) between 1 and 100),
  schedule_id uuid references public.ba_schedules(id) on delete set null,
  preferred_date date not null,
  note text not null default '',
  payment_method text not null check (payment_method in ('DANA','GoPay','OVO','QRIS')),
  amount_paid integer not null check (amount_paid > 0),
  proof_path text,
  status text not null default 'waiting_admin_confirmation' check (status in ('waiting_admin_confirmation','waiting_payment_review','confirmed','rejected')),
  created_at timestamptz not null default now()
);
alter table public.orders add column if not exists order_code text;
update public.orders set order_code='RULZ50000'||lpad(nextval('public.rulzz_order_seq')::text,5,'0') where order_code is null;
alter table public.orders alter column order_code set default ('RULZ50000'||lpad(nextval('public.rulzz_order_seq')::text,5,'0'));
alter table public.orders alter column order_code set not null;
create unique index if not exists orders_order_code_uidx on public.orders(order_code);
create index if not exists orders_created_at_idx on public.orders(created_at desc);
create index if not exists schedules_starts_at_idx on public.ba_schedules(starts_at);

alter table public.admin_users enable row level security;
alter table public.site_settings enable row level security;
alter table public.ba_schedules enable row level security;
alter table public.orders enable row level security;

create or replace function public.is_rulzz_admin()
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.admin_users where user_id=auth.uid()); $$;
revoke all on function public.is_rulzz_admin() from public;
grant execute on function public.is_rulzz_admin() to anon, authenticated;

create policy "public reads site settings" on public.site_settings for select to anon, authenticated using (true);
create policy "admin updates site settings" on public.site_settings for update to authenticated using (public.is_rulzz_admin()) with check (public.is_rulzz_admin());
create policy "public reads schedules" on public.ba_schedules for select to anon, authenticated using (true);
create policy "admin manages schedules" on public.ba_schedules for all to authenticated using (public.is_rulzz_admin()) with check (public.is_rulzz_admin());
create policy "admin reads orders" on public.orders for select to authenticated using (public.is_rulzz_admin());
create policy "admin updates orders" on public.orders for update to authenticated using (public.is_rulzz_admin()) with check (public.is_rulzz_admin());
create policy "admin reads own admin marker" on public.admin_users for select to authenticated using (user_id=auth.uid());

create or replace function public.create_public_order(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare v_order public.orders; v_slot public.ba_schedules; v_settings public.site_settings;
begin
  select * into v_settings from public.site_settings where id=1;
  if not found or not v_settings.store_open then raise exception 'Toko sedang CLOSED'; end if;
  select * into v_slot from public.ba_schedules where id=(p_payload->>'schedule_id')::uuid and status='OPEN';
  if not found then raise exception 'Slot tidak tersedia'; end if;
  if (v_slot.starts_at at time zone 'Asia/Jakarta')::date <> (p_payload->>'preferred_date')::date then raise exception 'Tanggal tidak cocok dengan slot'; end if;
  if not coalesce((v_settings.methods->>(p_payload->>'payment_method'))::boolean,false) then raise exception 'Metode pembayaran tidak aktif'; end if;
  if coalesce((p_payload->>'amount_paid')::integer,0) <= 0 then raise exception 'Nominal transfer harus diisi'; end if;
  insert into public.orders(buyer_name,buyer_phone,service,server_detail,schedule_id,preferred_date,note,payment_method,amount_paid)
  values (left(trim(p_payload->>'buyer_name'),70),left(trim(p_payload->>'buyer_phone'),20),p_payload->>'service',left(trim(p_payload->>'server_detail'),100),v_slot.id,(p_payload->>'preferred_date')::date,left(coalesce(p_payload->>'note',''),250),p_payload->>'payment_method',(p_payload->>'amount_paid')::integer) returning * into v_order;
  return jsonb_build_object('id',v_order.id,'order_code',v_order.order_code,'status',v_order.status);
end; $$;
revoke all on function public.create_public_order(jsonb) from public;
grant execute on function public.create_public_order(jsonb) to anon, authenticated;

create or replace function public.attach_payment_proof(p_order_id uuid,p_object_path text)
returns void language plpgsql security definer set search_path=public
as $$
begin
 if p_object_path !~ ('^'||p_order_id::text||'/[A-Za-z0-9._-]{1,180}$') then raise exception 'Path bukti tidak valid'; end if;
 update public.orders set proof_path=p_object_path,status='waiting_payment_review' where id=p_order_id and proof_path is null and status='waiting_admin_confirmation';
 if not found then raise exception 'Pembelian tidak ditemukan atau bukti sudah dikirim'; end if;
end; $$;
revoke all on function public.attach_payment_proof(uuid,text) from public;
grant execute on function public.attach_payment_proof(uuid,text) to anon, authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('payment-proofs','payment-proofs',false,5242880,array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict(id) do update set public=false,file_size_limit=5242880,allowed_mime_types=excluded.allowed_mime_types;
create or replace function public.can_upload_order_proof(p_order_id uuid)
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.orders o where o.id=p_order_id and o.proof_path is null and o.status='waiting_admin_confirmation'); $$;
revoke all on function public.can_upload_order_proof(uuid) from public;
grant execute on function public.can_upload_order_proof(uuid) to anon, authenticated;

create policy "anonymous uploads proof to order folder" on storage.objects for insert to anon, authenticated
with check (bucket_id='payment-proofs' and (storage.foldername(name))[1] ~* '^[0-9a-f-]{36}$' and public.can_upload_order_proof(((storage.foldername(name))[1])::uuid));
create policy "admin reads proof files" on storage.objects for select to authenticated
using (bucket_id='payment-proofs' and public.is_rulzz_admin());
create policy "admin deletes proof files" on storage.objects for delete to authenticated
using (bucket_id='payment-proofs' and public.is_rulzz_admin());

-- Enable realtime for public operational data and admin order notifications.
alter publication supabase_realtime add table public.site_settings;
alter publication supabase_realtime add table public.ba_schedules;
alter publication supabase_realtime add table public.orders;

-- Prevent two active purchases from claiming the same live slot.
-- Rejected orders release the slot; pending review and confirmed orders keep it reserved.
create unique index if not exists orders_one_active_order_per_slot
on public.orders(schedule_id)
where schedule_id is not null and status <> 'rejected';

-- Admin-only audit trail for operational changes.
create table if not exists public.admin_audit_logs (
  id bigserial primary key,
  table_name text not null,
  action text not null,
  record_id text,
  changed_at timestamptz not null default now(),
  changed_by uuid default auth.uid(),
  summary text not null default ''
);
alter table public.admin_audit_logs enable row level security;
create policy "admin reads audit logs" on public.admin_audit_logs
for select to authenticated using (public.is_rulzz_admin());

create or replace function public.write_rulzz_audit_log()
returns trigger language plpgsql security definer set search_path=public
as $$
declare v_id text; v_summary text;
begin
  if tg_op='DELETE' then
    v_id := coalesce(to_jsonb(old)->>'id','');
    v_summary := 'Record dihapus';
    insert into public.admin_audit_logs(table_name,action,record_id,summary)
    values (tg_table_name,tg_op,v_id,v_summary);
    return old;
  elsif tg_op='INSERT' then
    v_id := coalesce(to_jsonb(new)->>'id','');
    v_summary := case when tg_table_name='orders' then 'Pembelian baru dibuat' else 'Record baru dibuat' end;
    insert into public.admin_audit_logs(table_name,action,record_id,summary)
    values (tg_table_name,tg_op,v_id,v_summary);
    return new;
  else
    v_id := coalesce(to_jsonb(new)->>'id','');
    if tg_table_name='orders' then
      v_summary := 'Status pembelian: '||coalesce(to_jsonb(old)->>'status','?')||' → '||coalesce(to_jsonb(new)->>'status','?');
    elsif tg_table_name='ba_schedules' then
      v_summary := 'Jadwal/server diperbarui';
    else
      v_summary := 'Pengaturan website diperbarui';
    end if;
    insert into public.admin_audit_logs(table_name,action,record_id,summary)
    values (tg_table_name,tg_op,v_id,v_summary);
    return new;
  end if;
end; $$;

drop trigger if exists audit_orders_changes on public.orders;
create trigger audit_orders_changes after insert or update or delete on public.orders
for each row execute function public.write_rulzz_audit_log();
drop trigger if exists audit_schedule_changes on public.ba_schedules;
create trigger audit_schedule_changes after insert or update or delete on public.ba_schedules
for each row execute function public.write_rulzz_audit_log();
drop trigger if exists audit_settings_changes on public.site_settings;
create trigger audit_settings_changes after update on public.site_settings
for each row execute function public.write_rulzz_audit_log();

-- Public status lookup reveals only the order status and service details,
-- and requires both the unguessable order UUID and the buyer's phone number.
drop function if exists public.lookup_public_order_status(uuid,text);
create or replace function public.lookup_public_order_status(p_order_code text,p_phone text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare v_order public.orders;
begin
  if p_order_code !~ '^RULZ50000[0-9]{5}$' then return jsonb_build_object('status',null); end if;
  select * into v_order from public.orders
  where order_code=upper(trim(p_order_code))
    and regexp_replace(buyer_phone,'[^0-9]','','g')=regexp_replace(coalesce(p_phone,''),'[^0-9]','','g');
  if not found then return jsonb_build_object('status',null); end if;
  return jsonb_build_object('status',v_order.status,'service',v_order.service,'server_detail',v_order.server_detail,'preferred_date',v_order.preferred_date,'payment_method',v_order.payment_method,'amount_paid',v_order.amount_paid);
end; $$;
revoke all on function public.lookup_public_order_status(text,text) from public;
grant execute on function public.lookup_public_order_status(text,text) to anon, authenticated;

alter publication supabase_realtime add table public.admin_audit_logs;
