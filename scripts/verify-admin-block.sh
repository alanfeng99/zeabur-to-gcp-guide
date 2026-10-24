#!/usr/bin/env bash
# 確認後台 API 只能從 Cloudflare Access 後面的後台網域進去：
#
#   ./verify-admin-block.sh https://api.example.com https://admin.example.com <vm-ip>
#
# 1. 公開 API 網域上，每一種 /api/admin 變形都要回 404。Express 預設不分大小寫，
#    /API/Admin、/api//admin、/api/%61dmin 都會路由到後台 controller，所以全部要測。
#    封鎖前先對舊版跑一次：回 401 的那些就是會到後台的變形。
# 2. 後台網域從外面打要先被導到 Access 的登入頁（302）。
# 3. 繞過 Cloudflare 直連 VM 也不能進後台（404）。
set -uo pipefail
api=${1:?usage: verify-admin-block.sh <public-api-url> <admin-url> <vm-ip>}
admin=${2:?usage: verify-admin-block.sh <public-api-url> <admin-url> <vm-ip>}
vm_ip=${3:?usage: verify-admin-block.sh <public-api-url> <admin-url> <vm-ip>}
fail=0

echo "== public API host: every variant must be 404"
for p in /api/admin/x /API/ADMIN/x /api/Admin/x /api//admin/x /api/%61dmin/x /api/./admin/x /api/a/../admin/x /api%2Fadmin/x; do
  code=$(curl -s --path-as-is -o /dev/null -m 15 -w '%{http_code}' "$api$p")
  printf '  %-24s %s\n' "$p" "$code"
  [ "$code" = 404 ] || fail=1
done

echo "== admin host from outside: must redirect to the Access login"
loc=$(curl -s -o /dev/null -m 15 -w '%{http_code} %{redirect_url}' "$admin/api/admin/x")
echo "  $loc"
[[ $loc == 302\ https://*.cloudflareaccess.com/* ]] || fail=1

echo "== admin host straight to the VM, skipping Cloudflare: must be 404"
host=${admin#https://}
code=$(curl -sk -o /dev/null -m 15 -w '%{http_code}' --resolve "$host:443:$vm_ip" "$admin/login")
echo "  $code"
[ "$code" = 404 ] || fail=1

[ "$fail" -eq 0 ] && echo "all checks passed" || { echo "SOME CHECKS FAILED" >&2; exit 1; }
