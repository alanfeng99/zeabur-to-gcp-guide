#!/usr/bin/env bash
# 正式切換：Zeabur → GCP。在公告過的維護時段、使用者在場時執行，要加 --confirm 才會跑；
# 任何一步失敗就停。
#
#   0. 最後一次同步檔案：sync-assets.sh（有 MinIO 時）、sync-volume.sh（有 VOLUMES 時）。
#      都在 Zeabur 的容器裡跑，所以要在暫停之前
#   1. 停掉 Zeabur 的自動部署；暫停 API，等 worker 清空佇列（DRAIN_SECONDS），再暫停 worker。
#      從此 Zeabur 不再有新資料
#   2. sync-db.sh       最後一次資料庫同步（VM 進 standby），每張表筆數必須一致
#   3. verify.sh        資料庫參照的檔案都在，以及專案自己的檢查
#   4. GCP 離開 standby：worker 最後才啟動，確保同一時間只有一套 worker；寫入 live 標記
# 跑完後（不在這支腳本裡）：改 DNS 與外部後台 → 等 DNS 生效 → retire-zeabur-frontends.sh。
# 轉址一定在 DNS 之後：舊前台若也掛著自有網域，DNS 還指向 Zeabur 時轉址會指回自己、無限循環。
#
# 所有設定在動到 Zeabur 之前就先檢查完。
#
# 步驟 1 之後任何一步失敗（Zeabur 已暫停、GCP 還在 standby）：不要重跑這支腳本，跑
# ./rollback.sh --confirm 讓 Zeabur 恢復服務，查出原因後另約時間重來。例如步驟 0 與 1 之間
# 有新上傳的檔案，步驟 3 會因為檔案不在而停下。
#
# Rollback（客戶還沒寫入 GCP 之前）：./rollback.sh --confirm，再照它印出的步驟改回 DNS 與外部後台。
set -euo pipefail
cd "$(dirname "$0")"
source ./zeabur-lib.sh

if [ "${1:-}" != "--confirm" ]; then
  sed -n '2,/^set /{/^#/p;}' "$0"
  die "refusing to run without --confirm"
fi

step "Preflight: settings"
require ZEABUR_PROJECT_ID ZEABUR_ENV_ID ZEABUR_POSTGRES_ID ZEABUR_API_ID ZEABUR_WORKER_ID \
  NEW_API_URL GCP_PROJECT GCP_ZONE GCP_VM GCP_PUBLIC_IP GCP_DB_USER GCP_DB_NAME FILES_CHECK DRAIN_SECONDS
case "$FILES_CHECK" in
  gcs) require FILES_KEY_QUERY ASSETS_BUCKET ;;
  vm:/*) require FILES_KEY_QUERY ;;
  none) ;;
  *) die "FILES_CHECK must be 'gcs', 'vm:/absolute/dir' or 'none'" ;;
esac
# rollback.sh 需要的設定也先確認
[ -z "$GITHUB_REPO_ID" ] || require GITHUB_REPO_ID ZEABUR_GIT_BRANCH
if [ -n "$ZEABUR_MINIO_ID" ]; then
  require ASSETS_SA ASSETS_BUCKET
  [ -s "$WORK/dest-hmac.json" ] || die "no temporary HMAC key for sync-assets.sh: run ./sync-assets.sh --create-key first"
fi
# build-app-env.py 的 HOLD（會對外發訊息的憑證）要已經換成正式值
if [ -n "$(python3 -I build-app-env.py --hold)" ]; then
  # grep -c 讀完整份才結束（-q 提早結束會讓 gcloud 收到 SIGPIPE，pipefail 誤判失敗）；值不會印出
  [ "$(gcloud secrets versions access latest --secret app-env --project "$GCP_PROJECT" | grep -cx 'HELD_CREDENTIALS=live' || true)" -ge 1 ] \
    || die "app-env still holds back the messaging credentials: run ./sync-env.sh --live, then release.sh --deploy-only <tag>"
fi
! grep -q "^die \"add your project's own checks" verify.sh || die "fill in step 3 of verify.sh first"
echo "ok"

step "Preflight: the VM runs the latest secrets"
# sync-env.sh 寫進 Secret Manager 的新值，要重新部署才會進到 VM 的 app.env
deployed=$(gssh 'sudo stat -c %Y /srv/app/app.env' | tail -1 | tr -d '[:space:]')
for secret in app-env encryption-key; do
  created=$(gcloud secrets versions list "$secret" --project "$GCP_PROJECT" --limit 1 --sort-by=~createTime \
    --format='value(createTime.date("%s"))')
  [ -n "$created" ] || die "$secret has no version"
  [ "${deployed:-0}" -ge "$created" ] || die "$secret changed after the last deploy: run release.sh --deploy-only <tag> first"
done
echo "ok"

step "0. Files"
if [ -n "$ZEABUR_MINIO_ID" ]; then ./sync-assets.sh; fi
if [ -n "$VOLUMES" ]; then ./sync-volume.sh; fi
[ -n "$ZEABUR_MINIO_ID$VOLUMES" ] || echo "no MinIO and no volumes configured: nothing to copy"

step "1. Stop Zeabur auto-deploy, suspend its API, let the worker drain, suspend the worker"
# 從這裡開始失敗，Zeabur 已經停了：提示 rollback，不要重跑
on_exit() {
  local rc=$?
  [ "$rc" -eq 0 ] || echo "FAILED after Zeabur was suspended: do not rerun cutover.sh. Run ./rollback.sh --confirm to bring Zeabur back, then find the cause." >&2
}
trap on_exit EXIT
git_trigger zeabur-decommissioned "$ZEABUR_API_ID" "$ZEABUR_WORKER_ID"
zeabur service suspend --id "$ZEABUR_API_ID" --env-id "$ZEABUR_ENV_ID" -y -i=false
echo "waiting ${DRAIN_SECONDS}s for the worker to finish its queue"
sleep "$DRAIN_SECONDS"
zeabur service suspend --id "$ZEABUR_WORKER_ID" --env-id "$ZEABUR_ENV_ID" -y -i=false

step "2-3. Final database sync and checks"
./sync-db.sh
./verify.sh

step "4. Leave standby; mark the database as production"
gssh 'cd /srv/app && sudo rm -f standby && sudo touch live && sudo docker compose up --detach worker && sudo docker compose ps worker --format "worker: {{.Status}}"'

trap - EXIT

step "Done: GCP holds the data and runs the only worker"
cat << 'EOF'
Now, in this order:
  1. Switch DNS (and partner settings) to GCP, following the inventory.
  2. Wait until DNS resolves to the VM, then run the smoke tests. The rollback deadline starts now.
  3. Run ./retire-zeabur-frontends.sh: it refuses while DNS still points at Zeabur.
  4. With MinIO: ./sync-assets.sh --delete-key removes the temporary HMAC key.
If something is wrong before customers write to GCP: ./rollback.sh --confirm
EOF
