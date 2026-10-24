#!/usr/bin/env bash
# 把 Zeabur 上的舊前台換成只做 302 轉址的小服務（templates/zeabur-redirect），路徑與參數保留，
# 並停掉它們的自動部署（否則下次合併會蓋回去）。
#
# 只把前台的 API 網址指到新 API 不夠：Next.js 的 JS 檔快取一年，而網址是在容器啟動時
# 改寫進去的、檔名不變，回訪者的瀏覽器會一直用快取裡呼叫舊 API 的那份。轉址讓他們到
# 新網域重新載入。先用 302；確定不會 rollback 後，把 Caddyfile 的 302 改成 301、commit，再跑一次這支腳本。
set -euo pipefail
cd "$(dirname "$0")"
source ./zeabur-lib.sh
require ZEABUR_PROJECT_ID ZEABUR_ENV_ID ZEABUR_WEB_ID ZEABUR_ADMIN_ID OLD_WEB_URL OLD_ADMIN_URL NEW_WEB_URL NEW_ADMIN_URL
# 轉址服務的兩個檔案：在這個 repo 是 ../templates/zeabur-redirect；放到別處就設 REDIRECT_DIR
REDIRECT_DIR=$(cd "${REDIRECT_DIR:-../templates/zeabur-redirect}" && pwd)
CODE=$(sed -nE 's/^[[:space:]]*redir .* (30[12])$/\1/p' "$REDIRECT_DIR/Caddyfile")
[ -n "$CODE" ] || die "no 'redir … 301|302' line in $REDIRECT_DIR/Caddyfile"

step "Preflight: the new addresses are already served by GCP"
# 舊前台若也掛著自有網域，而 DNS 還指向 Zeabur，轉址會指回自己、無限循環。
for url in "$NEW_WEB_URL" "$NEW_ADMIN_URL"; do
  headers=$(curl -sI -m 15 "$url/" || true)
  [ -n "$headers" ] || die "$url does not answer"
  ! grep -qi '^x-zeabur-request-id' <<< "$headers" || die "$url is still served by Zeabur: switch DNS first and wait for it"
done
if command -v dig > /dev/null && [[ -n $GCP_PUBLIC_IP && $GCP_PUBLIC_IP != *'<'* ]]; then
  host=${NEW_WEB_URL#https://}
  ips=$(dig +short "$host" A || true)
  grep -qxF "$GCP_PUBLIC_IP" <<< "$ips" || die "$host does not resolve to $GCP_PUBLIC_IP yet"
fi
echo "ok"

step "Stop the old frontends auto-deploying"
git_trigger zeabur-decommissioned "$ZEABUR_WEB_ID" "$ZEABUR_ADMIN_ID"

# 服務若設了 ZBPACK_DOCKERFILE_PATH，上傳的目錄裡 Dockerfile 要放在那個路徑：
# 把 REDIRECT_DIR 的兩個檔案複製到對應位置再上傳。
redirect() {
  local id=$1 target=$2
  step "$target"
  zeabur variable create --id "$id" --env-id "$ZEABUR_ENV_ID" -k "REDIRECT_TO=$target" -y -i=false > /dev/null 2>&1 \
    || zeabur variable update --id "$id" --env-id "$ZEABUR_ENV_ID" -k "REDIRECT_TO=$target" -y -i=false > /dev/null
  (cd "$REDIRECT_DIR" && zeabur deploy --project-id "$ZEABUR_PROJECT_ID" --service-id "$id" --json -i=false)
}
redirect "$ZEABUR_WEB_ID" "$NEW_WEB_URL"
redirect "$ZEABUR_ADMIN_ID" "$NEW_ADMIN_URL"

# `zeabur deploy` 在上傳完成時就回報成功，不是建置完成：等轉址真的生效
step "Wait for the redirects to go live"
for _ in $(seq 1 30); do
  web=$(curl -s -m 10 -o /dev/null -w '%{http_code} %{redirect_url}' "$OLD_WEB_URL/" || true)
  admin=$(curl -s -m 10 -o /dev/null -w '%{http_code} %{redirect_url}' "$OLD_ADMIN_URL/" || true)
  if [[ $web == "$CODE $NEW_WEB_URL/" && $admin == "$CODE $NEW_ADMIN_URL/" ]]; then
    echo "live ($CODE): $OLD_WEB_URL → $NEW_WEB_URL, $OLD_ADMIN_URL → $NEW_ADMIN_URL"
    exit 0
  fi
  sleep 10
done
die "redirects not live after 5 minutes (web: $web, admin: $admin)"
