// Pengelolaan akun karyawan. Membuat akun butuh kunci service role, dan kunci
// itu tidak boleh ada di peramban — jadi pekerjaannya dilakukan di sini.
//
// Setiap permintaan diperiksa dua kali:
//   1. token pemanggil harus token Supabase yang sah;
//   2. profil pemanggil harus berperan OWNER dan masih aktif.
//
// Variabel lingkungan yang dibutuhkan:
//   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY

var URL_BASE = (process.env.SUPABASE_URL || '').replace(/\/+$/, '');
var ANON = process.env.SUPABASE_ANON_KEY || '';
var SERVICE = process.env.SUPABASE_SERVICE_ROLE_KEY || '';

function send(res, code, body) {
  res.setHeader('Cache-Control', 'no-store');
  res.status(code).json(body);
}

async function readBody(req) {
  if (req.body && typeof req.body === 'object') return req.body;
  if (typeof req.body === 'string') { try { return JSON.parse(req.body); } catch (e) { return {}; } }
  return await new Promise(function (resolve) {
    var raw = '';
    req.on('data', function (c) { raw += c; });
    req.on('end', function () { try { resolve(JSON.parse(raw || '{}')); } catch (e) { resolve({}); } });
  });
}

async function callerIsOwner(token) {
  var who = await fetch(URL_BASE + '/auth/v1/user', {
    headers: { apikey: ANON, Authorization: 'Bearer ' + token }
  });
  if (!who.ok) return null;
  var user = await who.json();
  if (!user || !user.id) return null;

  var prof = await fetch(
    URL_BASE + '/rest/v1/profiles?id=eq.' + encodeURIComponent(user.id) + '&select=role,active',
    { headers: { apikey: SERVICE, Authorization: 'Bearer ' + SERVICE } }
  );
  if (!prof.ok) return null;
  var rows = await prof.json();
  var p = rows && rows[0];
  if (!p || p.active !== true || p.role !== 'OWNER') return null;
  return user;
}

module.exports = async function (req, res) {
  if (req.method !== 'POST') return send(res, 405, { error: 'Metode tidak didukung.' });
  if (!URL_BASE || !SERVICE || !ANON) {
    return send(res, 500, { error: 'Server belum lengkap: isi SUPABASE_URL, SUPABASE_ANON_KEY, dan SUPABASE_SERVICE_ROLE_KEY di Vercel.' });
  }

  var auth = req.headers['authorization'] || '';
  var token = auth.indexOf('Bearer ') === 0 ? auth.slice(7) : '';
  if (!token) return send(res, 401, { error: 'Anda belum masuk.' });

  var owner;
  try { owner = await callerIsOwner(token); }
  catch (e) { return send(res, 502, { error: 'Tidak bisa memeriksa akun Anda ke Supabase.' }); }
  if (!owner) return send(res, 403, { error: 'Hanya pemilik toko yang boleh mengelola akun.' });

  var body = await readBody(req);
  var action = body.action;
  var admin = { apikey: SERVICE, Authorization: 'Bearer ' + SERVICE, 'Content-Type': 'application/json' };

  try {
    if (action === 'create') {
      var email = String(body.email || '').trim();
      var password = String(body.password || '');
      var name = String(body.name || '').trim();
      var role = ['OWNER', 'MANAGER', 'CASHIER'].indexOf(body.role) >= 0 ? body.role : 'CASHIER';
      if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return send(res, 400, { error: 'Email belum benar.' });
      if (password.length < 8) return send(res, 400, { error: 'Kata sandi minimal 8 karakter.' });
      if (!name) return send(res, 400, { error: 'Nama wajib diisi.' });

      var r = await fetch(URL_BASE + '/auth/v1/admin/users', {
        method: 'POST', headers: admin,
        body: JSON.stringify({
          email: email, password: password, email_confirm: true,
          user_metadata: { name: name, role: role }
        })
      });
      var created = await r.json();
      if (!r.ok) {
        var m = created && (created.msg || created.message || created.error_description);
        return send(res, 400, { error: /registered|exists/i.test(String(m)) ? 'Email ini sudah dipakai akun lain.' : (m || 'Akun gagal dibuat.') });
      }

      // Pemicu di basis data sudah membuat profil; peran dipastikan lagi di sini.
      await fetch(URL_BASE + '/rest/v1/profiles?id=eq.' + encodeURIComponent(created.id), {
        method: 'PATCH', headers: Object.assign({ Prefer: 'return=minimal' }, admin),
        body: JSON.stringify({ name: name, role: role, active: true })
      });
      return send(res, 200, { userId: created.id });
    }

    if (action === 'password') {
      var uid = String(body.userId || '');
      var pass = String(body.password || '');
      if (!uid) return send(res, 400, { error: 'Pengguna tidak dikenali.' });
      if (pass.length < 8) return send(res, 400, { error: 'Kata sandi minimal 8 karakter.' });
      var r2 = await fetch(URL_BASE + '/auth/v1/admin/users/' + encodeURIComponent(uid), {
        method: 'PUT', headers: admin, body: JSON.stringify({ password: pass })
      });
      if (!r2.ok) return send(res, 400, { error: 'Kata sandi gagal diganti.' });
      return send(res, 200, { ok: true });
    }

    if (action === 'delete') {
      var did = String(body.userId || '');
      if (!did) return send(res, 400, { error: 'Pengguna tidak dikenali.' });
      if (did === owner.id) return send(res, 400, { error: 'Anda tidak bisa menghapus akun sendiri.' });
      var r3 = await fetch(URL_BASE + '/auth/v1/admin/users/' + encodeURIComponent(did), {
        method: 'DELETE', headers: admin
      });
      if (!r3.ok) return send(res, 400, { error: 'Akun gagal dihapus.' });
      return send(res, 200, { ok: true });
    }

    return send(res, 400, { error: 'Tindakan tidak dikenali.' });
  } catch (e) {
    return send(res, 502, { error: 'Supabase tidak bisa dihubungi dari server.' });
  }
};
