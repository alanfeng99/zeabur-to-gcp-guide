#!/usr/bin/env bash
# 切換後退回 Zeabur（GCP 還沒有客戶寫入之前）。要加 --confirm 才會跑。
#
#   ./rollback.sh --confirm
#
#   1. GCP 回 standby：移除 live 標記、建立 standby 旗標、停 worker
#   2. Zeabur 的 API 與 worker 的自動部署改回 ZEABUR_GIT_BRANCH
#   3. 恢復 Zeabur 的 API 與 worker：Zeabur 沒有 resume，暫停的服務用 restart 叫醒；
#      5 分鐘內沒回到 RUNNING 就改用 redeploy
# 之後要人做的（腳本最後也會印出來）：
#   - DNS 與外部後台改回 Zeabur（照盤點表）
#   - 已經跑過 retire-zeabur-frontends.sh 的話，前台也要退回（見最後印出的指令）
# GCP 一旦有客戶寫入，退回就要把那些資料反向搬回 Zeabur，這支腳本不處理。
# 退回之後可以另約時間重跑 cutover.sh（live 標記已移除）。這支腳本還沒有在真實的切換中跑過。
set -euo pipefail
cd "$(dirname "$0")"
source ./zeabur-lib.sh

if [ "${1:-}" != "--confirm" ]; then
  sed -n '2,/^set /{/^#/p;}' "$0"
  die "refusing to run without --confirm"
fi
require ZEABUR_ENV_ID ZEABUR_API_ID ZEABUR_WORKER_ID GCP_PROJECT GCP_ZONE GCP_VM
[ -z "$GITHUB_REPO_ID" ] || require GITHUB_REPO_ID ZEABUR_GIT_BRANCH

step "1. GCP back to standby"
gssh 'cd /srv/app && sudo rm -f live && sudo touch standby && sudo docker compose stop worker && echo "standby, worker stopped"'

step "2. Zeabur auto-deploy back to ${ZEABUR_GIT_BRANCH:-its branch}"
git_trigger "$ZEABUR_GIT_BRANCH" "$ZEABUR_API_ID" "$ZEABUR_WORKER_ID"

step "3. Resume Zeabur's API and worker"
wait_running() {
  local _
  for _ in $(seq 1 30); do
    python3 -I zeabur-status.py "$ZEABUR_API_ID" "$ZEABUR_WORKER_ID" > /dev/null && return 0
    sleep 10
  done
  return 1
}
for id in "$ZEABUR_API_ID" "$ZEABUR_WORKER_ID"; do
  zeabur service restart --id "$id" --env-id "$ZEABUR_ENV_ID" -y -i=false
done
if ! wait_running; then
  echo "not RUNNING after restart: trying redeploy"
  for id in "$ZEABUR_API_ID" "$ZEABUR_WORKER_ID"; do
    zeabur service redeploy --id "$id" --env-id "$ZEABUR_ENV_ID" -y -i=false
  done
  wait_running || die "Zeabur's API or worker is not RUNNING: resume it in the Zeabur dashboard"
fi
python3 -I zeabur-status.py "$ZEABUR_API_ID" "$ZEABUR_WORKER_ID"

cat << EOF

Now, by hand:
  1. Switch DNS and partner settings back to Zeabur, following the inventory.
  2. If retire-zeabur-frontends.sh already ran, bring the frontends back from git
     (redeploy, not restart: restart reuses the redirect container):
       (cd $(pwd) && bash -c 'source ./zeabur-lib.sh && git_trigger "\$ZEABUR_GIT_BRANCH" "\$ZEABUR_WEB_ID" "\$ZEABUR_ADMIN_ID" && zeabur service redeploy --id "\$ZEABUR_WEB_ID" --env-id "\$ZEABUR_ENV_ID" -y -i=false && zeabur service redeploy --id "\$ZEABUR_ADMIN_ID" --env-id "\$ZEABUR_ENV_ID" -y -i=false')
     If the redeploy still serves the redirect, deploy from the dashboard (latest commit of $ZEABUR_GIT_BRANCH).
EOF
