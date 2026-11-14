# Theo dõi gửi mẫu – DTRG

App web tĩnh (HTML/JS) chạy trên GitHub Pages, dữ liệu và đăng nhập dùng Supabase.

```
docs/index.html                         Giao diện app (GitHub Pages phục vụ thư mục docs/)
docs/config.js                          URL + publishable key Supabase
supabase/migrations/001_init.sql        Tạo schema, phân quyền, trigger audit
supabase/migrations/001_init_rollback.sql
supabase/migrations/002_password_login.sql    Đăng nhập email + mật khẩu, mã kích hoạt
supabase/migrations/002_password_login_rollback.sql
supabase/migrations/003_teams_notify.sql      Tự nhắn Teams riêng cho từng nhân sự
supabase/migrations/003_teams_notify_rollback.sql
supabase/migrations/003b_teams_card_format.sql  Chỉ chạy nếu đã chạy bản 003 cũ
supabase/migrations/004_teams_card_v2.sql     Card Teams mới (màu theo loại tin, nút mở thẳng hồ sơ)
supabase/migrations/004_teams_card_v2_rollback.sql
.github/workflows/backup.yml            Backup hằng tuần (mã hóa, giữ 90 ngày)
```

## Cách bảo mật hoạt động

- Trình duyệt chỉ được **đọc** dữ liệu (Row Level Security), và chỉ khi email đã có trong bảng `app_users` ở trạng thái hoạt động.
- Mọi thao tác **ghi** đi qua hàm RPC trong database (`fn_save_task`, `fn_decide_gate`, …). Hàm kiểm tra phòng ban, bước hiện tại, trường được phép nhập và dữ liệu bắt buộc. Sửa giao diện hay gọi API trực tiếp cũng không vượt qua được.
- Không có xóa cứng: trigger chặn `DELETE`; hủy dự án, gỡ quyền đều là đổi trạng thái kèm lý do.
- Mọi thay đổi được trigger ghi vào `audit_log` (giá trị cũ, mới, người, phòng ban, thời điểm). `audit_log` chỉ ghi thêm.

## Cài đặt lần đầu

1. **Tạo project Supabase** (region Southeast Asia – Singapore). Nên có thêm một project thứ hai để thử (staging).
2. **Chạy migration** trong SQL Editor, lần lượt:
   - `supabase/migrations/001_init.sql`
   - `supabase/migrations/002_password_login.sql`
3. **Cấu hình đăng nhập:** Authentication → Sign In / Providers → Email: bật Email provider, **tắt "Confirm email"**. App không gửi email nên không cần SMTP.
4. **Tạo Owner đầu tiên** (SQL Editor), lấy mã kích hoạt ở cột kết quả:
   ```sql
   insert into public.app_users (email, display_name, full_name, dept_code, app_role, status)
   values ('email-cua-ban@congty.vn', 'Tên hiển thị', 'Họ và tên đầy đủ', 'RD', 'owner', 'invited');
   select public.fn_issue_activation(id) as ma_kich_hoat
   from public.app_users where email = 'email-cua-ban@congty.vn';
   ```
   Mở app → "Kích hoạt tài khoản / quên mật khẩu" → nhập email, mã, đặt mật khẩu.
5. **Điền `docs/config.js`:** Settings → API Keys → Project URL và Publishable key (`sb_publishable_...`). Không đưa secret key hay mật khẩu database vào repo.
6. **Bật GitHub Pages:** Settings → Pages → Deploy from a branch → `main` / thư mục `/docs`.
   GitHub Pages miễn phí chỉ dùng với repo public; muốn repo private thì dùng gói trả phí hoặc Cloudflare Pages / Netlify.

## Đăng nhập và quản lý nhân sự

- Owner thêm nhân sự ở tab **Quản trị người dùng** → app hiện **mã kích hoạt** (8 ký tự, hết hạn 7 ngày, khóa sau 5 lần nhập sai). Gửi mã cho nhân sự qua kênh nội bộ.
- Nhân sự mở app → "Kích hoạt tài khoản / quên mật khẩu" → email + mã + tự đặt mật khẩu. Các lần sau đăng nhập bằng email + mật khẩu.
- **Quên mật khẩu:** Owner bấm **Cấp mã mới** cho người đó; nhân sự kích hoạt lại bằng mã mới để đặt mật khẩu mới.
- Nếu app báo "Email này đã có tài khoản đăng nhập cũ": Owner xóa tài khoản đó ở Supabase → Authentication → Users, rồi nhân sự kích hoạt lại bằng cùng mã.
- Owner quên mật khẩu: chạy lại câu `select public.fn_issue_activation(...)` ở bước 4 trong SQL Editor để lấy mã mới.

## Thông báo Teams

- Migration `003_teams_notify.sql` tự nhắn Teams riêng (qua Flow bot) khi: dự án sang bước mới, Kế hoạch chốt ngày có mẫu, dự án bị hủy hoặc hoàn thành.
- Người nhận: PIC của phòng trong dự án (tên PIC trùng tên hiển thị hoặc họ tên người dùng); không khớp thì gửi tất cả người dùng đang hoạt động của phòng.
- Cấu hình trong SQL Editor:
  ```sql
  update public.app_settings set value = '<URL workflow>' where key = 'teams_webhook_url';
  update public.app_settings set value = 'https://<user>.github.io/<repo>/' where key = 'app_url';
  -- tạm ngưng: update public.app_settings set value = 'false' where key = 'teams_enabled';
  ```
- Migration `004_teams_card_v2.sql` đổi tin nhắn sang card cùng khung: dòng "Bạn có 0X công việc / thông báo mới", dải màu (lam: đến lượt, vàng: thông báo, đỏ: hủy, xanh lá: hoàn thành), 4 dòng thông tin và nút "Mở hồ sơ" mở thẳng `<app_url>#p-<id>`. Quay lại card cũ: chạy `004_teams_card_v2_rollback.sql`.
- Kiểm tra đã gửi: `select * from public.notify_log order by id desc limit 20;`
  và kết quả HTTP: `select id, status_code, content from net._http_response order by id desc limit 20;`

## Backup hằng tuần

Workflow chạy 01:00 sáng thứ Hai (giờ VN), có thể chạy tay ở tab Actions.

1. Settings → Secrets and variables → Actions, thêm:
   - `SUPABASE_DB_URL`: Supabase → Connect → **Session pooler** → connection string (đã thay mật khẩu). Dùng Session pooler vì máy GitHub Actions dùng IPv4.
   - `BACKUP_PASSPHRASE`: mật khẩu mã hóa bản backup. Lưu ở nơi an toàn; mất mật khẩu là không giải mã được.
2. Chạy tay lần đầu để kiểm tra. File backup nằm trong mục Artifacts của lần chạy, giữ 90 ngày.

**Khôi phục (nên làm thử ít nhất mỗi quý trên project staging):**

```bash
gpg --decrypt dtrg-backup-YYYYMMDD-HHMM.dump.gpg > backup.dump
# Project đích chưa có bảng của app (project mới, chưa chạy 001_init.sql):
pg_restore --no-owner --no-privileges --schema=public -d "<SESSION_POOLER_URL_DICH>" backup.dump
```

Sau khi khôi phục sang project Supabase khác, tài khoản đăng nhập là mới nên cần cho người dùng liên kết lại:

```sql
update public.app_users set auth_user_id = null, status = 'invited'
where status = 'active' and is_deleted = false;
```

Lưu ý: chỉ schema `public` được sao lưu (dữ liệu app). Cấu hình Authentication, publication realtime cần làm lại theo mục Cài đặt.

## Thay đổi quy trình hoặc schema

- Mọi thay đổi qua file migration mới (`002_...sql` kèm `002_..._rollback.sql`), lưu trong repo, chạy staging trước rồi mới production. Không sửa tay dữ liệu production.
- Danh sách ô/bước nằm ở bảng `task_blocks`, `task_defs`, `field_defs` (server dùng để kiểm tra quyền) và hằng `TK`, `B`, `F` trong `docs/index.html` (giao diện). Hai nơi phải khớp nhau.

## Lưu ý vận hành gói Supabase miễn phí

- Project tạm dừng sau 7 ngày không có hoạt động; vào Dashboard bấm Restore để chạy lại. Khi cả công ty dùng hằng ngày, cân nhắc gói Pro.
- Mỗi lần đọc, Supabase trả tối đa 1.000 dòng; app hiện đọc toàn bộ dự án một lần. Khi dữ liệu vượt mức này, cần thêm phân trang.
