# Kasir Online — Supabase + Vercel

Versi daring dari aplikasi kasir satu berkas. Data pindah dari browser ke
Postgres di Supabase, sehingga satu toko bisa dipegang beberapa perangkat
sekaligus dan perubahan saling menyusul secara realtime.

```
index.html          aplikasi kasir (satu berkas, tanpa proses build)
api/config.js       mengirim alamat Supabase + kunci anon ke aplikasi
api/users.js        membuat / mengganti sandi / menghapus akun karyawan
supabase/schema.sql tabel, fungsi transaksi, RLS, realtime
vercel.json         header dan cache
```

## Pasang dalam 6 langkah

**1. Buat proyek Supabase** — supabase.com → New project. Catat sandi basis
data, pilih wilayah terdekat (Singapore untuk Indonesia).

**2. Jalankan skema** — SQL Editor → New query → tempel seluruh isi
`supabase/schema.sql` → Run. Berkas ini aman dijalankan ulang.

**3. Matikan konfirmasi email** — Authentication → Providers → Email →
nonaktifkan *Confirm email*. Karyawan toko biasanya tidak punya email kantor
yang selalu dibuka. Kalau tetap ingin dinyalakan, setiap akun baru harus
mengklik tautan di emailnya sebelum bisa masuk.

**4. Ambil kunci** — Project Settings → API. Anda butuh:

| Nilai | Dipakai di | Boleh dilihat publik |
|---|---|---|
| Project URL | `SUPABASE_URL` | ya |
| anon public | `SUPABASE_ANON_KEY` | ya — dijaga oleh RLS |
| service_role | `SUPABASE_SERVICE_ROLE_KEY` | **tidak pernah** |

**5. Sebar ke Vercel** — unggah folder ini ke GitHub, lalu di Vercel: Add New →
Project → pilih repo → Deploy (tanpa framework, tanpa build command). Setelah
itu Settings → Environment Variables, isi ketiga nilai di atas untuk
Production, Preview, dan Development, lalu Redeploy sekali agar terbaca.

Tanpa repo pun bisa: `npm i -g vercel` lalu `vercel` di dalam folder ini.

**6. Buka alamat Vercel Anda** → "Siapkan toko baru" → isi nama usaha, nama
Anda, email, kata sandi. Akun pertama otomatis menjadi Pemilik.

Menambah karyawan: Pengaturan → Pengguna → Tambah. Beri tahu email dan kata
sandi awalnya; mereka bisa menggantinya lewat "Lupa kata sandi" di layar masuk.

## Printer Bluetooth

Halaman **Printer** (ada di menu semua kasir) → Hubungkan printer → pilih nama
printer dari daftar Bluetooth → Uji cetak.

- Berlaku untuk printer struk ESC/POS 58 mm dan 80 mm.
- Pengaturannya tersimpan di perangkat itu saja, jadi tiap kasir bisa punya
  printer sendiri.
- Jalan di **Chrome/Edge**: Android, Windows, macOS, Linux, ChromeOS.
- **iPhone dan iPad tidak bisa**: Safari maupun Chrome di iOS tidak mendukung
  Web Bluetooth. Pilihannya: cetak lewat tombol "Cetak kertas" (AirPrint), atau
  pakai peramban Bluefy.
- Pemasangan harus lewat https. Vercel sudah https.
- Kalau hasil cetak terpotong di kanan, ganti lebar kertas di halaman Printer.

## Yang membuatnya aman dipakai bersamaan

Bagian yang tidak boleh salah dikerjakan di dalam basis data, bukan di
peramban (lihat `supabase/schema.sql`):

- `pos_create_sale` mengunci baris produk, memeriksa stok, mengambil nomor nota
  secara atomik, lalu menulis nota + stok + kartu stok dalam satu transaksi.
  Dua kasir tidak bisa menjual barang terakhir yang sama, dan nomor nota tidak
  pernah kembar. Nota juga idempoten: tombol bayar tertekan dua kali tetap
  menghasilkan satu nota.
- `pos_apply_order_change` (batal & refund) menolak menulis kalau nota sudah
  diubah perangkat lain lebih dulu — muncul pesan "nota baru saja diubah",
  bukan saling menimpa diam-diam.
- `pos_adjust_stock` mengunci produk sebelum menambah atau mengurangi stok.
- Hanya boleh ada satu shift terbuka; dijaga indeks unik di tabel `shifts`.
- Row Level Security: kasir boleh menjual, manajer boleh mengubah produk dan
  stok, pemilik boleh mengubah pengaturan dan akun. Akun yang dinonaktifkan
  langsung kehilangan akses di semua perangkat.

Perhitungan uang tetap di aplikasi (fungsi murni yang bisa Anda uji sendiri
lewat menu **Uji sistem**) dan tidak berubah dari versi luring: pajak inklusif
diekstrak bukan ditambahkan, semua nominal bilangan bulat rupiah.

## Batas yang perlu diketahui

- **Harus ada internet.** Tidak ada mode luring. Kalau sambungan putus di
  tengah transaksi, penjualan ditolak dengan pesan jelas — tidak ada nota
  setengah jadi.
- Aplikasi memuat nota dan kartu stok **400 hari terakhir** ke memori. Laporan
  di luar rentang itu perlu penyesuaian di `CLOUD.historyDays`.
- Satu proyek Supabase = satu toko. Untuk banyak cabang, buat proyek terpisah,
  atau tambahkan kolom cabang di skema dan sesuaikan RLS.
- Pemulihan cadangan tidak menimpa akun pengguna, karena akun hidup di sistem
  masuk Supabase, bukan di tabel biasa.
- Penomoran nota disimpan di tabel `counters`, jadi tidak ikut terbawa berkas
  cadangan lama.

## Perawatan

- Supabase mencadangkan basis data otomatis (harian pada paket berbayar).
  Unduhan lewat Pengaturan → Cadangan data berguna untuk arsip sendiri.
- Menonaktifkan karyawan yang berhenti: Pengaturan → Pengguna → Nonaktif.
  Nama mereka tetap tercatat di nota lama.
- Menu **Uji sistem** menjalankan uji rumus sungguhan dan mencocokkan nota
  dengan kartu stok. Jalankan setelah setiap perubahan besar.
