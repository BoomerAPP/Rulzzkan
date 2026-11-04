# RulzzGTPS — Royal Red Edition

Versi visual yang mengikuti referensi Royal Red: sidebar gelap-merah, hero maskot, aksen neon merah, kartu skeuomorphic/glass, dan navigasi responsif. Credit desain: **@Simbaa — Designer**.

## Isi project
- `index.html` — website dan UI interaktif.
- `assets/mascot-hero.png`, `assets/mascot-card.png` — aset visual maskot hasil crop dari referensi yang diberikan.
- `qris-rulzz.jpg` — QRIS yang diberikan.
- `supabase/schema.sql` — skema database, RLS, fungsi pemesanan dan lookup dari project backend sebelumnya.
- `config.example.js` — contoh konfigurasi publik Supabase.
- `bootstrap-admin.mjs` — provisioning akun admin melalui Supabase Auth.

## Menjalankan
1. Isi URL dan anon key Supabase pada konfigurasi `window.RULZZ_SUPABASE_URL` dan `window.RULZZ_SUPABASE_ANON_KEY` (lihat `config.example.js`).
2. Jalankan `supabase/schema.sql` di Supabase SQL Editor.
3. Provision akun admin melalui prosedur di dokumentasi/bootstrap-admin.mjs. Jangan menaruh password admin di HTML atau JavaScript publik.
4. Jalankan melalui static hosting atau server lokal, bukan `file://`, agar modul dan koneksi backend berjalan normal.

## Catatan
UI dapat dibuka sebagai preview statis, tetapi booking online, upload bukti privat, login admin, pencarian pesanan, dan realtime membutuhkan project Supabase aktif dengan schema, storage bucket, policy, dan konfigurasi yang benar. QRIS adalah informasi pembayaran; transfer tetap diverifikasi manual admin.

## Update tampilan jadwal mingguan
Versi ini menampilkan Senin–Minggu, termasuk hari tanpa jadwal. Kartu jadwal mendukung jangkauan dan reward Top 1–3.

Setelah mengganti file website, buka Supabase → SQL Editor dan jalankan **sekali** isi `supabase/migration_schedule_rewards.sql`. Migration ini menambah kolom `reach_label`, `reward_top1`, `reward_top2`, dan `reward_top3` pada `ba_schedules`. Jangan jalankan `schema.sql` awal ulang pada project yang sudah aktif.

## Sesi admin
Supabase Auth menggunakan `persistSession: true` dan refresh token otomatis. Admin yang sudah login akan tetap login pada perangkat/browser tersebut sampai logout, sesi kedaluwarsa/dicabut, atau data browser dihapus. Pengunjung biasa tetap tidak dapat membuka panel karena aplikasi memeriksa user di tabel `admin_users`; keamanan data sebenarnya tetap ditegakkan oleh RLS di database. Jangan membagikan kredensial admin.

Catatan: membatasi satu akun agar tidak bisa login bersamaan dari perangkat lain (single-session lock) memerlukan mekanisme server-side tambahan seperti Edge Function + tabel sesi aktif. Frontend saja tidak aman untuk menjamin hal tersebut.

## Perbaikan order + bukti (WAJIB)

1. Buka Supabase → **SQL Editor**
2. Jalankan file `supabase/migration_fix_orders.sql` **sekali**
3. Pastikan `config.js` berisi URL + anon key project (sudah terisi di bundle ini)
4. Hard refresh website (Ctrl+Shift+R)

### Penyebab error sebelumnya
- Fungsi `create_public_order` **wajib** `schedule_id` OPEN → flexible gagal ("Slot tidak tersedia")
- `preferred_date` harus sama dengan tanggal slot **WIB** → mismatch timezone ("Tanggal tidak cocok")
- Satu slot hanya boleh 1 order aktif (cegah bentrok)
- ID `RULZ50000xxxxx` adalah ID asli dari sequence database, bukan dummy

### Setelah migration
- Order dengan slot valid → dapat `order_code` asli + upload bukti ke storage
- Order flexible (hari kosong) → `schedule_id` null, tetap tercatat
- Admin Setting: durasi live + max server/hari tersimpan di `site_settings`
