// Mengirim alamat Supabase dan kunci "anon" ke aplikasi kasir.
// Kunci anon memang dirancang untuk dipasang di sisi peramban — yang menjaga
// data adalah Row Level Security di basis data, bukan kerahasiaan kunci ini.
// Kunci service role TIDAK BOLEH dikirim lewat sini.
module.exports = function (req, res) {
  var url = process.env.SUPABASE_URL || '';
  var anonKey = process.env.SUPABASE_ANON_KEY || '';
  res.setHeader('Cache-Control', 'no-store');
  if (!url || !anonKey) {
    res.status(404).json({ error: 'SUPABASE_URL atau SUPABASE_ANON_KEY belum diisi di Vercel.' });
    return;
  }
  res.status(200).json({ url: url.replace(/\/+$/, ''), anonKey: anonKey });
};
