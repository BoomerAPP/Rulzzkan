-- ============================================================
-- RulzzGTPS: jalankan SEKALI di Supabase SQL Editor
-- Perbaikan alur order + flexible + setting durasi/batas server
-- ============================================================

-- 1) Kolom setting tambahan
alter table public.site_settings
  add column if not exists live_duration_hours integer not null default 3 check (live_duration_hours between 1 and 12),
  add column if not exists max_servers_per_day integer not null default 3 check (max_servers_per_day between 1 and 20);

-- 2) Jadwal: longgarkan constraint durasi 3 jam kaku (opsional tetap default 3 jam di app)
alter table public.ba_schedules drop constraint if exists ba_schedules_ends_at_check;
alter table public.ba_schedules drop constraint if exists ba_schedules_check;
-- pastikan ends_at > starts_at
do $$ begin
  alter table public.ba_schedules add constraint ba_schedules_ends_after_start check (ends_at > starts_at);
exception when duplicate_object then null;
end $$;

-- 3) create_public_order: support slot tetap ATAU flexible (schedule_id null)
create or replace function public.create_public_order(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
  v_slot public.ba_schedules;
  v_settings public.site_settings;
  v_schedule_id uuid;
  v_preferred date;
  v_service text;
  v_payment text;
begin
  select * into v_settings from public.site_settings where id = 1;
  if not found or not v_settings.store_open then
    raise exception 'Toko sedang CLOSED';
  end if;

  v_service := trim(p_payload->>'service');
  if v_service is null or v_service not in ('Growtopia BA','Live Gaming','Jadwal Flexible') then
    raise exception 'Layanan tidak valid';
  end if;

  v_payment := trim(p_payload->>'payment_method');
  if not coalesce((v_settings.methods->>v_payment)::boolean, false) then
    raise exception 'Metode pembayaran tidak aktif';
  end if;

  if coalesce((p_payload->>'amount_paid')::integer, 0) <= 0 then
    raise exception 'Nominal transfer harus diisi';
  end if;

  -- schedule_id opsional
  begin
    if nullif(trim(p_payload->>'schedule_id'),'') is null then
      v_schedule_id := null;
    else
      v_schedule_id := (p_payload->>'schedule_id')::uuid;
    end if;
  exception when others then
    raise exception 'Slot tidak tersedia';
  end;

  if v_schedule_id is not null then
    select * into v_slot
    from public.ba_schedules
    where id = v_schedule_id and status = 'OPEN';

    if not found then
      raise exception 'Slot tidak tersedia';
    end if;

    -- pakai tanggal slot (WIB) supaya tidak mismatch timezone
    v_preferred := (v_slot.starts_at at time zone 'Asia/Jakarta')::date;

    -- cegah double book slot yang sama (index unik + pesan jelas)
    if exists (
      select 1 from public.orders
      where schedule_id = v_schedule_id and status <> 'rejected'
    ) then
      raise exception 'Slot sudah dipesan orang lain';
    end if;
  else
    -- flexible: preferred_date wajib valid
    begin
      v_preferred := (p_payload->>'preferred_date')::date;
    exception when others then
      raise exception 'Tanggal tidak valid';
    end;
    if v_preferred is null then
      raise exception 'Tanggal tidak valid';
    end if;
  end if;

  insert into public.orders(
    buyer_name, buyer_phone, service, server_detail,
    schedule_id, preferred_date, note, payment_method, amount_paid
  ) values (
    left(trim(p_payload->>'buyer_name'), 70),
    left(trim(p_payload->>'buyer_phone'), 20),
    v_service,
    left(trim(p_payload->>'server_detail'), 100),
    v_schedule_id,
    v_preferred,
    left(coalesce(p_payload->>'note',''), 250),
    v_payment,
    (p_payload->>'amount_paid')::integer
  ) returning * into v_order;

  return jsonb_build_object(
    'id', v_order.id,
    'order_code', v_order.order_code,
    'status', v_order.status
  );
end;
$$;

revoke all on function public.create_public_order(jsonb) from public;
grant execute on function public.create_public_order(jsonb) to anon, authenticated;

-- 4) Pastikan lookup & attach tetap ada (aman jika sudah ada)
-- (tidak diubah di migration ini)

comment on function public.create_public_order(jsonb) is
  'Public order: schedule_id opsional. Jika diisi, tanggal diambil dari slot WIB. Null = flexible.';


-- 5) Alasan reject + update lookup status
alter table public.orders
  add column if not exists rejection_reason text;

create or replace function public.lookup_public_order_status(p_order_code text, p_phone text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_order public.orders;
begin
  if p_order_code !~ '^RULZ50000[0-9]{5}$' then
    return jsonb_build_object('status', null);
  end if;
  select * into v_order from public.orders
  where order_code = upper(trim(p_order_code))
    and regexp_replace(buyer_phone, '[^0-9]', '', 'g')
      = regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
  if not found then
    return jsonb_build_object('status', null);
  end if;
  return jsonb_build_object(
    'status', v_order.status,
    'service', v_order.service,
    'server_detail', v_order.server_detail,
    'preferred_date', v_order.preferred_date,
    'payment_method', v_order.payment_method,
    'amount_paid', v_order.amount_paid,
    'rejection_reason', v_order.rejection_reason
  );
end;
$$;

revoke all on function public.lookup_public_order_status(text, text) from public;
grant execute on function public.lookup_public_order_status(text, text) to anon, authenticated;


-- 6) Fase live BA: OPEN -> BOOKED (setelah konfirmasi order) -> LIVE (admin Mulai BA) -> DONE
alter table public.ba_schedules
  add column if not exists live_phase text not null default 'idle'
    check (live_phase in ('idle','booked','live','done')),
  add column if not exists live_started_at timestamptz,
  add column if not exists confirmed_order_id uuid references public.orders(id) on delete set null;

-- longgarkan status jadwal agar tetap kompatibel
-- status: OPEN/CLOSED untuk ketersediaan booking; live_phase untuk proses BA

create or replace function public.admin_start_ba(p_schedule_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_slot public.ba_schedules;
begin
  if not public.is_rulzz_admin() then raise exception 'Unauthorized'; end if;
  select * into v_slot from public.ba_schedules where id = p_schedule_id for update;
  if not found then raise exception 'Jadwal tidak ditemukan'; end if;
  if v_slot.live_phase = 'live' then raise exception 'BA sudah berjalan'; end if;
  if v_slot.live_phase = 'done' then raise exception 'BA sudah selesai'; end if;
  -- boleh start dari idle atau booked
  update public.ba_schedules
  set live_phase = 'live',
      live_started_at = now(),
      status = 'CLOSED' -- tutup booking saat live
  where id = p_schedule_id
  returning * into v_slot;
  return jsonb_build_object(
    'id', v_slot.id,
    'live_phase', v_slot.live_phase,
    'live_started_at', v_slot.live_started_at
  );
end;
$$;

create or replace function public.admin_finish_ba(p_schedule_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_slot public.ba_schedules;
begin
  if not public.is_rulzz_admin() then raise exception 'Unauthorized'; end if;
  update public.ba_schedules
  set live_phase = 'done',
      status = 'CLOSED'
  where id = p_schedule_id
  returning * into v_slot;
  if not found then raise exception 'Jadwal tidak ditemukan'; end if;
  return jsonb_build_object('id', v_slot.id, 'live_phase', v_slot.live_phase);
end;
$$;

revoke all on function public.admin_start_ba(uuid) from public;
revoke all on function public.admin_finish_ba(uuid) from public;
grant execute on function public.admin_start_ba(uuid) to authenticated;
grant execute on function public.admin_finish_ba(uuid) to authenticated;
