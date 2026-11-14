#!/usr/bin/env bash
# Day code len Git: add -> commit -> pull --rebase -> push
# Dung: dat o thu muc goc du an, chay: bash gitpush.sh "noi dung commit"
set -e
cd "$(dirname "$0")"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "[LOI] Chua phai Git repo."; exit 1; }

BRANCH=$(git rev-parse --abbrev-ref HEAD)
MSG=${1:-"Cập nhật: sidebar gọn không cuộn, gợi ý PIC theo phòng ban"}

echo "Nhánh hiện tại: $BRANCH"
git status --short

git add -A
if git diff --cached --quiet; then
  echo "Không có thay đổi mới để commit."
else
  git commit -m "$MSG"
fi

git pull --rebase origin "$BRANCH" || { echo "[LOI] Xung đột khi pull. Sửa xong chạy 'git rebase --continue' rồi chạy lại."; exit 1; }
git push -u origin "$BRANCH"
echo "Đã đẩy code lên nhánh $BRANCH."
