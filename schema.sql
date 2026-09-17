-- ===========================================================================
-- APLIKASI KASIR (POS) — SKEMA SUPABASE
-- Jalankan SELURUH berkas ini sekali di Supabase → SQL Editor → New query.
-- Aman dijalankan ulang (memakai "if not exists" / "create or replace").
-- ===========================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- 1. TABEL
-- Semua id bertipe text karena aplikasi membuat id sendiri di sisi kasir
-- (crypto.randomUUID) dan data contoh memakai id seperti 'p-demo-1'.
-- ---------------------------------------------------------------------------

create table if not exists profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  name        text not null,
  role        text not null default 'CASHIER' check (role in ('OWNER','MANAGER','CASHIER')),
  active      boolean not null default true,
  pin_salt    text,
  pin_hash    text,
  created_at  timestamptz not null default now()
);

-- Pengaturan toko & penanda lain. Satu baris per kunci, persis seperti versi offline.
create table if not exists meta (
  k          text primary key,
  v          jsonb,
  updated_at timestamptz not null default now()
);

-- Penomoran nota per tanggal. Dinaikkan secara atomik oleh pos_create_sale.
create table if not exists counters (
  k text primary key,
  n bigint not null default 0
);

create table if not exists categories (
  id         text primary key,
  name       text not null,
  sort       int not null default 0,
  is_demo    boolean not null default false,
  updated_at timestamptz not null default now()
);

create table if not exists products (
  id            text primary key,
  sku           text,
  barcode       text,
  name          text not null,
  category_id   text,
  unit          text,
  price         bigint  not null default 0,
  cost          bigint  not null default 0,
  stock         numeric not null default 0,
  reorder_point numeric not null default 0,
  track_stock   boolean not null default true,
  taxable       boolean not null default true,
  active        boolean not null default true,
  is_demo       boolean not null default false,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- Nota disimpan utuh di kolom data (item, pembayaran, refund) supaya bentuknya
-- sama persis dengan yang dipakai aplikasi. Kolom di sebelahnya hanya untuk
-- penyaringan dan penguncian.
create table if not exists orders (
  id           text primary key,
  client_uuid  text unique not null,
  no           text not null,
  at           timestamptz not null,
  local_date   date not null,
  shift_id     text,
  cashier_id   text,
  cashier_name text,
  status       text not null,
  grand_total  bigint not null default 0,
  data         jsonb not null,
  updated_at   timestamptz not null default now()
);
create index if not exists orders_local_date_idx on orders(local_date);
create index if not exists orders_shift_idx on orders(shift_id);

create table if not exists stock_moves (
  id         text primary key,
  at         timestamptz not null,
  local_date date not null,
  product_id text not null,
  type       text not null,
  qty_delta  numeric not null,
  unit_cost  bigint not null default 0,
  ref_type   text,
  ref_id     text,
  ref_no     text,
  user_id    text,
  note       text
);
create index if not exists stock_moves_date_idx on stock_moves(local_date);
create index if not exists stock_moves_product_idx on stock_moves(product_id);

create table if not exists shifts (
  id         text primary key,
  status     text not null,
  opened_at  timestamptz,
  local_date date,
  data       jsonb not null,
  updated_at timestamptz not null default now()
);
-- Kunci pengaman lintas perangkat: hanya boleh ada SATU shift terbuka.
create unique index if not exists shifts_single_open_idx on shifts((status)) where status = 'OPEN';

create table if not exists cash_logs (
  id         text primary key,
  shift_id   text,
  local_date date,
  data       jsonb not null
);

create table if not exists parked (
  id   text primary key,
  at   timestamptz not null default now(),
  data jsonb not null
);

-- ---------------------------------------------------------------------------
-- 2. PROFIL OTOMATIS SAAT AKUN DIBUAT
-- Akun pertama otomatis menjadi Pemilik. Akun berikutnya memakai peran yang
-- dikirim saat pembuatan (lewat /api/users), bawaannya Kasir.
-- ---------------------------------------------------------------------------
create or replace function handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_first boolean;
begin
  select not exists (select 1 from profiles) into v_first;
  insert into profiles (id, name, role, active)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data->>'name',''), split_part(new.email,'@',1)),
    case when v_first then 'OWNER'
         else coalesce(nullif(new.raw_user_meta_data->>'role',''), 'CASHIER') end,
    true
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function handle_new_user();

-- Dipakai layar masuk untuk tahu apakah toko ini belum punya pemilik.
create or replace function pos_needs_setup()
returns boolean language sql security definer set search_path = public as $$
  select not exists (select 1 from profiles);
$$;
grant execute on function pos_needs_setup() to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. PEMBANTU HAK AKSES
-- ---------------------------------------------------------------------------
create or replace function my_role()
returns text language sql stable security definer set search_path = public as $$
  select role from profiles where id = auth.uid() and active;
$$;

create or replace function is_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and active);
$$;

create or replace function is_manager()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(my_role() in ('OWNER','MANAGER'), false);
$$;

create or replace function is_owner()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(my_role() = 'OWNER', false);
$$;

-- ---------------------------------------------------------------------------
-- 4. OPERASI YANG HARUS ATOMIK
-- Penjualan, pembatalan/refund, dan koreksi stok memakai fungsi di bawah ini.
-- Tanpa ini, dua kasir bisa menjual barang terakhir yang sama.
-- ---------------------------------------------------------------------------

-- Menyelesaikan penjualan: cek stok sambil mengunci baris produk, ambil nomor
-- nota secara atomik, simpan nota, kurangi stok, catat pergerakan stok.
create or replace function pos_create_sale(p_order jsonb, p_date text, p_prefix text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_dup   jsonb;
  v_item  jsonb;
  v_no    text;
  v_n     bigint;
  v_order jsonb;
  v_allow boolean;
  v_stock numeric;
  v_name  text;
  v_unit  text;
begin
  if not is_staff() then raise exception 'AKSES: akun tidak aktif atau belum masuk.'; end if;

  -- Idempoten: tombol bayar tertekan dua kali tidak membuat dua nota.
  select data into v_dup from orders where client_uuid = p_order->>'clientUuid';
  if v_dup is not null then
    return jsonb_build_object('order', v_dup, 'duplicate', true);
  end if;

  select coalesce((v->>'allowNegativeStock')::boolean, false) into v_allow from meta where k = 'settings';
  v_allow := coalesce(v_allow, false);

  for v_item in select * from jsonb_array_elements(p_order->'items') loop
    if coalesce((v_item->>'trackStock')::boolean, false) then
      select stock, name, unit into v_stock, v_name, v_unit
        from products where id = v_item->>'productId' for update;
      if not found then
        raise exception 'PRODUK: produk "%" sudah tidak ada. Hapus dari keranjang.', v_item->>'name';
      end if;
      if not v_allow and v_stock < (v_item->>'qty')::numeric then
        raise exception 'STOK: stok "%" tinggal % %.', v_name,
          trim(to_char(v_stock, 'FM999999990.###')), coalesce(v_unit,'');
      end if;
    end if;
  end loop;

  insert into counters (k, n) values ('seq:' || p_date, 1)
    on conflict (k) do update set n = counters.n + 1
    returning n into v_n;

  v_no := coalesce(nullif(p_prefix, ''), substr(replace(p_date, '-', ''), 3))
          || '-' || lpad(v_n::text, 4, '0');
  v_order := jsonb_set(p_order, '{no}', to_jsonb(v_no));

  insert into orders (id, client_uuid, no, at, local_date, shift_id, cashier_id,
                      cashier_name, status, grand_total, data)
  values (v_order->>'id', v_order->>'clientUuid', v_no,
          (v_order->>'at')::timestamptz, (v_order->>'localDate')::date,
          nullif(v_order->>'shiftId',''), nullif(v_order->>'cashierId',''),
          v_order->>'cashierName', v_order->>'status',
          (v_order->>'grandTotal')::bigint, v_order);

  for v_item in select * from jsonb_array_elements(v_order->'items') loop
    if coalesce((v_item->>'trackStock')::boolean, false) then
      update products
         set stock = round(stock - (v_item->>'qty')::numeric, 3), updated_at = now()
       where id = v_item->>'productId';
      insert into stock_moves (id, at, local_date, product_id, type, qty_delta,
                               unit_cost, ref_type, ref_id, ref_no, user_id, note)
      values (gen_random_uuid()::text, (v_order->>'at')::timestamptz,
              (v_order->>'localDate')::date, v_item->>'productId', 'SALE',
              -(v_item->>'qty')::numeric, coalesce((v_item->>'unitCost')::bigint, 0),
              'ORDER', v_order->>'id', v_no, nullif(v_order->>'cashierId',''), '');
    end if;
  end loop;

  return jsonb_build_object('order', v_order, 'duplicate', false);
end $$;

-- Dipakai pembatalan nota dan refund. Nota hanya boleh ditulis kalau status dan
-- nilai refund-nya masih sama dengan yang dilihat kasir — kalau perangkat lain
-- sudah mengubahnya lebih dulu, penulisan ditolak, bukan saling menimpa.
create or replace function pos_apply_order_change(
  p_id text, p_expected_status text, p_expected_refunded bigint,
  p_order jsonb, p_moves jsonb
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_status text; v_ref bigint; v_m jsonb;
begin
  if not is_staff() then raise exception 'AKSES: akun tidak aktif atau belum masuk.'; end if;

  select status, coalesce((data->>'refundedAmount')::bigint, 0)
    into v_status, v_ref
    from orders where id = p_id for update;
  if not found then raise exception 'NOTA: nota tidak ditemukan.'; end if;
  if v_status is distinct from p_expected_status or v_ref is distinct from p_expected_refunded then
    raise exception 'BENTROK: nota ini baru saja diubah di perangkat lain. Muat ulang halaman lalu ulangi.';
  end if;

  for v_m in select * from jsonb_array_elements(coalesce(p_moves, '[]'::jsonb)) loop
    update products
       set stock = round(stock + (v_m->>'qtyDelta')::numeric, 3), updated_at = now()
     where id = v_m->>'productId';
    insert into stock_moves (id, at, local_date, product_id, type, qty_delta,
                             unit_cost, ref_type, ref_id, ref_no, user_id, note)
    values (coalesce(nullif(v_m->>'id',''), gen_random_uuid()::text),
            (v_m->>'at')::timestamptz, (v_m->>'localDate')::date,
            v_m->>'productId', v_m->>'type', (v_m->>'qtyDelta')::numeric,
            coalesce((v_m->>'unitCost')::bigint, 0), v_m->>'refType',
            nullif(v_m->>'refId',''), v_m->>'refNo', nullif(v_m->>'userId',''),
            coalesce(v_m->>'note',''));
  end loop;

  update orders
     set data = p_order, status = p_order->>'status', updated_at = now()
   where id = p_id;

  return p_order;
end $$;

-- Koreksi stok manual (barang masuk, rusak, opname).
create or replace function pos_adjust_stock(
  p_product_id text, p_delta numeric, p_new_cost bigint, p_move jsonb
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_allow boolean; v_after numeric; v_row products;
begin
  if not is_manager() then raise exception 'AKSES: hanya manajer atau pemilik yang boleh mengubah stok.'; end if;

  select coalesce((v->>'allowNegativeStock')::boolean, false) into v_allow from meta where k = 'settings';

  select * into v_row from products where id = p_product_id for update;
  if not found then raise exception 'PRODUK: produk tidak ditemukan.'; end if;

  v_after := round(v_row.stock + p_delta, 3);
  if v_after < 0 and not coalesce(v_allow, false) then
    raise exception 'STOK: stok tidak boleh menjadi negatif.';
  end if;

  update products
     set stock = v_after,
         cost = coalesce(p_new_cost, cost),
         updated_at = now()
   where id = p_product_id
  returning * into v_row;

  insert into stock_moves (id, at, local_date, product_id, type, qty_delta,
                           unit_cost, ref_type, ref_id, ref_no, user_id, note)
  values (coalesce(nullif(p_move->>'id',''), gen_random_uuid()::text),
          (p_move->>'at')::timestamptz, (p_move->>'localDate')::date,
          p_product_id, p_move->>'type', p_delta,
          coalesce((p_move->>'unitCost')::bigint, 0), coalesce(p_move->>'refType','MANUAL'),
          nullif(p_move->>'refId',''), coalesce(p_move->>'refNo',''),
          nullif(p_move->>'userId',''), coalesce(p_move->>'note',''));

  return to_jsonb(v_row);
end $$;

grant execute on function pos_create_sale(jsonb, text, text) to authenticated;
grant execute on function pos_apply_order_change(text, text, bigint, jsonb, jsonb) to authenticated;
grant execute on function pos_adjust_stock(text, numeric, bigint, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. KEAMANAN BARIS (RLS)
-- Aturan dasar: hanya pengguna yang sudah masuk DAN masih aktif yang bisa
-- membaca. Menulis data induk (produk, kategori, pengaturan) butuh manajer.
-- ---------------------------------------------------------------------------
alter table profiles    enable row level security;
alter table meta        enable row level security;
alter table counters    enable row level security;
alter table categories  enable row level security;
alter table products    enable row level security;
alter table orders      enable row level security;
alter table stock_moves enable row level security;
alter table shifts      enable row level security;
alter table cash_logs   enable row level security;
alter table parked      enable row level security;

do $$
declare t text;
begin
  foreach t in array array['profiles','meta','counters','categories','products',
                           'orders','stock_moves','shifts','cash_logs','parked'] loop
    execute format('drop policy if exists %I on %I', t || '_read', t);
    execute format('drop policy if exists %I on %I', t || '_write', t);
    execute format('drop policy if exists %I on %I', t || '_update', t);
    execute format('drop policy if exists %I on %I', t || '_delete', t);
  end loop;
end $$;

-- Baca: semua karyawan aktif.
create policy profiles_read    on profiles    for select using (is_staff());
create policy meta_read        on meta        for select using (is_staff());
create policy counters_read    on counters    for select using (is_staff());
create policy categories_read  on categories  for select using (is_staff());
create policy products_read    on products    for select using (is_staff());
create policy orders_read      on orders      for select using (is_staff());
create policy stock_moves_read on stock_moves for select using (is_staff());
create policy shifts_read      on shifts      for select using (is_staff());
create policy cash_logs_read   on cash_logs   for select using (is_staff());
create policy parked_read      on parked      for select using (is_staff());

-- Profil: ubah milik sendiri (nama & PIN); pemilik boleh mengubah siapa pun.
create policy profiles_update on profiles for update
  using (id = auth.uid() or is_owner()) with check (id = auth.uid() or is_owner());
create policy profiles_delete on profiles for delete using (is_owner());

-- Data induk: manajer ke atas.
create policy categories_write  on categories for insert with check (is_manager());
create policy categories_update on categories for update using (is_manager());
create policy categories_delete on categories for delete using (is_manager());
create policy products_write    on products   for insert with check (is_manager());
create policy products_update   on products   for update using (is_manager());
create policy products_delete   on products   for delete using (is_manager());
create policy meta_write        on meta       for insert with check (is_manager());
create policy meta_update       on meta       for update using (is_manager());
create policy meta_delete       on meta       for delete using (is_owner());

-- Data transaksi: semua kasir aktif boleh menulis.
create policy orders_write       on orders      for insert with check (is_staff());
create policy orders_update      on orders      for update using (is_staff());
create policy orders_delete      on orders      for delete using (is_owner());
create policy stock_moves_write  on stock_moves for insert with check (is_staff());
create policy stock_moves_delete on stock_moves for delete using (is_manager());
create policy shifts_write       on shifts      for insert with check (is_staff());
create policy shifts_update      on shifts      for update using (is_staff());
create policy shifts_delete      on shifts      for delete using (is_owner());
create policy cash_logs_write    on cash_logs   for insert with check (is_staff());
create policy cash_logs_delete   on cash_logs   for delete using (is_owner());
create policy parked_write       on parked      for insert with check (is_staff());
create policy parked_update      on parked      for update using (is_staff());
create policy parked_delete      on parked      for delete using (is_staff());
create policy counters_delete    on counters    for delete using (is_owner());

-- ---------------------------------------------------------------------------
-- 6. REALTIME
-- Supaya perubahan di satu perangkat langsung terlihat di perangkat lain.
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['meta','profiles','categories','products','orders',
                           'stock_moves','shifts','cash_logs','parked'] loop
    begin
      execute format('alter publication supabase_realtime add table %I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;

-- Realtime mengirim baris lama saat dihapus hanya kalau replica identity penuh.
alter table products    replica identity full;
alter table orders      replica identity full;
alter table categories  replica identity full;
alter table shifts      replica identity full;
alter table parked      replica identity full;
alter table meta        replica identity full;
alter table profiles    replica identity full;
alter table cash_logs   replica identity full;
alter table stock_moves replica identity full;
