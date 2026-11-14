// Cấu hình kết nối Supabase.
// Lấy tại Supabase Dashboard → Project Settings → API:
//   - Project URL           → SUPABASE_URL
//   - anon / publishable key → SUPABASE_ANON_KEY
// Khóa anon/publishable được thiết kế để công khai trên trình duyệt: bảo mật nằm ở
// Row Level Security và các hàm RPC kiểm tra quyền trong database (xem 001_init.sql).
// KHÔNG BAO GIỜ đưa service_role key hoặc mật khẩu database vào file này.
window.APP_CONFIG = {
  SUPABASE_URL: "https://eydnjnvikrdqhasfdgyq.supabase.co",
  SUPABASE_ANON_KEY: "sb_publishable_8l_FMfsSq535nIsleBbqkw_-HcBn8jP"
};
