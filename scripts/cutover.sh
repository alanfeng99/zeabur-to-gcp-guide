#!/usr/bin/env bash
# 正式切換：Zeabur → GCP。在公告過的維護時段執行，要加 --confirm 才會跑；
# 任何一步失敗就停。
#
#   0. sync-assets.sh   最後一次同步檔案：在 Zeabur 的 API 容器裡跑，所以要在暫停之前
#   1. 停掉 Zeabur 的自動部署；暫停 API，等 worker 清空佇列（DRAIN_SECONDS），再暫停 worker。
#      從此 Zeabur 不再有新資料
#   2. sync-db.sh       最後一次資料庫同步（VM 進 standby），每張表筆數必須一致
#   3. verify.sh        資料庫參照的檔案都在 GCS，以及專案自己的檢查
#   4. GCP 離開 standby：worker 最後才啟動，確保同一時間只有一套 worker
#   5. retire-zeabur-frontends.sh：舊前台換成 302 轉址，舊連結繼續能用
# 之後改 DNS 與各外部後台的網址（照盤點表）。
#
# 所有設定在動到 Zeabur 之前就先檢查完。步驟 1 之後不能重跑：步驟 0 在已暫停的 API
# 容器裡執行，要先恢復 API，或 rollback。
#
# Rollback（客戶還沒寫入 GCP 之前）：在 VM 上 `sudo touch /srv/app/standby && sudo docker
# compose stop worker` → `bash -c 'source ./zeabur-lib.sh && python3 -I zeabur-git-trigger.py
# main <service-ids>'` → 恢復 Zeabur 的 API 與 worker → 前台從 main 重新部署（不能 restart：
# restart 沿用已被改寫的容器）。
set -euo pipefail
cd "$(dirname "$0")"
source ./zeabur-lib.sh

if [ "${1:-}" != "--confirm" ]; then
  sed -n '2,/^set /{/^#/p;}' "$0"
  die "refusing to run without --confirm"
fi

step "Preflight: every setting the steps below need"
require ZEABUR_PROJECT_ID ZEABUR_ENV_ID ZEABUR_POSTGRES_ID ZEABUR_API_ID ZEABUR_WORKER_ID ZEABUR_WEB_ID \
  ZEABUR_ADMIN_ID GITHUB_REPO_ID OLD_WEB_URL OLD_ADMIN_URL NEW_WEB_URL NEW_API_URL NEW_ADMIN_URL \
  GCP_PROJECT GCP_ZONE GCP_VM GCP_DB_USER GCP_DB_NAME ASSETS_BUCKET FILES_KEY_QUERY DRAIN_SECONDS
: "${DEST_ACCESS_KEY:?export DEST_ACCESS_KEY for sync-assets.sh}"
: "${DEST_SECRET_KEY:?export DEST_SECRET_KEY for sync-assets.sh}"
: "${DEST_BUCKET:?export DEST_BUCKET for sync-assets.sh}"
! grep -q "^die \"add your project's own checks" verify.sh || die "fill in step 3 of verify.sh first"
echo "ok"

step "0. Files"
./sync-assets.sh

step "1. Stop Zeabur auto-deploy, suspend its API, let the worker drain, suspend the worker"
python3 -I zeabur-git-trigger.py zeabur-decommissioned "$ZEABUR_API_ID" "$ZEABUR_WORKER_ID"
zeabur service suspend --id "$ZEABUR_API_ID" --env-id "$ZEABUR_ENV_ID" -y -i=false
echo "waiting ${DRAIN_SECONDS}s for the worker to finish its queue"
sleep "$DRAIN_SECONDS"
zeabur service suspend --id "$ZEABUR_WORKER_ID" --env-id "$ZEABUR_ENV_ID" -y -i=false

step "2-3. Final database sync and checks"
./sync-db.sh
./verify.sh

step "4. Leave standby"
gssh 'cd /srv/app && sudo rm -f standby && sudo docker compose up --detach worker && sudo docker compose ps worker --format "worker: {{.Status}}"'

step "5. Old Zeabur addresses → redirects"
./retire-zeabur-frontends.sh

step "Done"
echo "GCP is live. Switch DNS and partner settings now, then run the smoke tests; the rollback deadline starts now."
