#!/usr/bin/env bash
# 建立後台用的 Cloudflare tunnel，把後台網域指到它，token 直接寫進 Secret Manager（不顯示）。
# 在你自己的電腦執行，需要 cloudflared（macOS：brew install cloudflared）。
#
#   ./setup-tunnel.sh <tunnel-name>
#
# tunnel 是本機管理的：routing 寫在 compose（cloudflared 把所有流量送到 Traefik 的內部入口），
# Cloudflare dashboard 裡不用設 ingress。下一次部署 deploy.sh 會讀到 token、啟動 cloudflared。
#
# 順序很重要：先用 cloudflare-access.py 建好後台的 Access 應用，再跑這支。
# 後台網域的 DNS 一建立就已經在 Access 後面，中間沒有對外公開的空窗。
set -euo pipefail
cd "$(dirname "$0")"
source ./zeabur-lib.sh
require GCP_PROJECT NEW_ADMIN_URL
NAME=${1:?usage: setup-tunnel.sh <tunnel-name>}
host=${NEW_ADMIN_URL#https://}

command -v cloudflared > /dev/null || die "install cloudflared first (macOS: brew install cloudflared)"
[ -f "$HOME/.cloudflared/cert.pem" ] \
  || die "run 'cloudflared tunnel login' first: it opens a browser; pick the zone that $host belongs to"

step "tunnel $NAME"
if cloudflared tunnel list -o json | python3 -I -c 'import json, sys; sys.exit(0 if any(t.get("name") == sys.argv[1] for t in json.load(sys.stdin) or []) else 1)' "$NAME"; then
  echo "exists"
else
  cloudflared tunnel create "$NAME" > /dev/null
  echo "created"
fi

step "DNS: $host → tunnel (proxied CNAME, required for Access)"
cloudflared tunnel route dns "$NAME" "$host"

step "token → Secret Manager (cloudflared-tunnel-token)"
cloudflared tunnel token "$NAME" | tr -d '\n' \
  | gcloud secrets versions add cloudflared-tunnel-token --project "$GCP_PROJECT" --data-file=- --format='value(name)' \
  | sed 's#.*/versions/#cloudflared-tunnel-token: added version #'
echo "the next release.sh starts cloudflared; then check with verify-admin-block.sh"
