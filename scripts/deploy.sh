#!/usr/bin/env bash
# VM 上的部署流程，放在 /srv/app（與 compose.yaml 同一個目錄），由 release.sh 呼叫：
#
#   sudo /srv/app/deploy.sh <image-tag>
#
# 順序：secrets → 清舊 image → pull → migrate → api、admin、web 依序 docker rollout
# → worker → 清掉剛被換下的 image。任何一步失敗就停，舊版繼續服務。
#
# Secret Manager 裡要有：app-env（app 的環境變數，含 POSTGRES_PASSWORD）、encryption-key，
# 以及（用 Cloudflare tunnel 時）cloudflared-tunnel-token。
set -euo pipefail

TAG=${1:?usage: deploy.sh <image-tag>}
cd "$(dirname "$0")"

# docker-rollout 外掛，固定版本並驗 checksum：https://github.com/wowu/docker-rollout
ROLLOUT_VERSION=v0.14
ROLLOUT_SHA256=cdeaba6ae9eee3b0b606286e585bbda6787283d801a6ad6d9b9d2bc347fda05b   # 換版本時要重算
ROLLOUT_PLUGIN=/usr/local/lib/docker/cli-plugins/docker-rollout

PROJECT=$(curl -fsS -H 'Metadata-Flavor: Google' \
  http://metadata.google.internal/computeMetadata/v1/project/project-id)
secret() { gcloud secrets versions access latest --secret "$1" --project "$PROJECT"; }

# 1. docker-rollout
if ! echo "$ROLLOUT_SHA256  $ROLLOUT_PLUGIN" | sha256sum --check --status 2>/dev/null; then
  mkdir -p "$(dirname "$ROLLOUT_PLUGIN")"
  curl -fsSL -o "$ROLLOUT_PLUGIN.tmp" \
    "https://github.com/wowu/docker-rollout/releases/download/$ROLLOUT_VERSION/docker-rollout"
  echo "$ROLLOUT_SHA256  $ROLLOUT_PLUGIN.tmp" | sha256sum --check --status
  chmod +x "$ROLLOUT_PLUGIN.tmp"
  mv "$ROLLOUT_PLUGIN.tmp" "$ROLLOUT_PLUGIN"
fi

# 2. secrets → app.env（api／worker 的執行環境）與 .env（compose 的變數），權限 600
umask 077
# app 讀加密金鑰的變數名稱：和 zeabur-lib.sh 的 ENCRYPTION_KEY_VAR 相同（沒有加密金鑰就留空）
ENCRYPTION_KEY_VAR=ENCRYPTION_KEY
# 單獨一行：寫在 echo 的參數裡，$(...) 失敗不會觸發 set -e，會寫出空的金鑰
ENCRYPTION_KEY=$(secret encryption-key)
{
  secret app-env
  echo
  [ -z "$ENCRYPTION_KEY_VAR" ] || echo "$ENCRYPTION_KEY_VAR=$ENCRYPTION_KEY"
} > app.env.new
mv app.env.new app.env

POSTGRES_PASSWORD=$(sed -n 's/^POSTGRES_PASSWORD=//p' app.env)
TUNNEL_TOKEN=$(secret cloudflared-tunnel-token 2>/dev/null || true)
{
  echo "IMAGE_TAG=$TAG"
  echo "POSTGRES_PASSWORD=$POSTGRES_PASSWORD"
  if [ -n "$TUNNEL_TOKEN" ]; then
    echo "TUNNEL_TOKEN=$TUNNEL_TOKEN"
    echo "COMPOSE_PROFILES=tunnel"
  fi
} > .env.new
mv .env.new .env

# 3. 每版約 4 GB、系統碟 20 GB：先清掉沒有容器在用的 image，再 pull
docker image prune --all --force >/dev/null
docker compose pull --quiet
# 容器裡的程式以非 root 執行，掛載點要能進得去（不要用上面的 077）
install -d -m 0755 /srv/data/postgres /srv/data/redis
install -d -m 0700 /srv/data/traefik
docker compose up --detach --wait postgres redis socket-proxy traefik
# cloudflared 只在 image 版本變了才換，而且用 rollout，讓一個連線一直在
if [ -n "$TUNNEL_TOKEN" ]; then
  want=$(docker compose config --images cloudflared)
  have=$(docker compose ps --format '{{.Image}}' cloudflared | sort -u)
  [ "$have" = "$want" ] || docker rollout cloudflared
fi

# 4. migration 只在這裡跑一次，在任何新程式接流量之前
docker compose run --rm migrate

# 5. HTTP 服務一次換一個
for service in api admin web; do
  docker rollout --timeout 120 --wait-after-healthy 5 "$service"
done

# 6. worker 不接流量，最後換。standby 旗標存在時保持停止：切換前用正式資料跑 GCP 時，
#    避免和 Zeabur 的 worker 同時對客戶發訊息
if [ -e standby ]; then
  echo "standby: worker kept stopped"
  docker compose stop worker
else
  docker compose up --detach worker
fi

# 7. 每晚備份的 timer，隨每次部署安裝或更新
install -m 0644 db-backup.service db-backup.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now db-backup.timer

# 8. 剛被換下的版本沒有容器在用了，清掉（預設的 prune 只刪沒有 tag 的，舊版會累積到磁碟滿）。
#    回滾時從 Artifact Registry 重新下載。
docker image prune --all --force | tail -1
echo "free on /: $(df -h --output=avail / | tail -1 | tr -d ' ')"
echo "deployed $TAG"
