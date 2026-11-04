-- RulzzGTPS: jalankan SEKALI setelah schema.sql awal berhasil diterapkan.
-- Menambahkan jangkauan dan reward per jadwal BA.
alter table public.ba_schedules
  add column if not exists reach_label text not null default '1 server',
  add column if not exists reward_top1 text,
  add column if not exists reward_top2 text,
  add column if not exists reward_top3 text;

comment on column public.ba_schedules.reach_label is 'Jangkauan promosi per jadwal, contoh: 1 server / 1 world';
comment on column public.ba_schedules.reward_top1 is 'Reward untuk peringkat live nomor 1';
comment on column public.ba_schedules.reward_top2 is 'Reward untuk peringkat live nomor 2';
comment on column public.ba_schedules.reward_top3 is 'Reward untuk peringkat live nomor 3';
