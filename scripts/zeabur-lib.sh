# shellcheck shell=bash
# shellcheck disable=SC2034  # 這是設定檔：變數由 source 它的腳本使用
# 共用設定與函式。由其他 bash 腳本 `source` 載入，不要直接執行。
# 把每個 '<...>' 換成自己的值；腳本用 require 檢查自己需要的設定，沒填就停。
#
# Zeabur 服務 ID：npx zeabur@0.24.0 service list --project-id <ID> -i=false --json
# GitHub repo 的數字 ID：gh api repos/<owner>/<repo> --jq .id

# --- Zeabur ---------------------------------------------------------------
export ZEABUR_PROJECT_ID='<project-id>'
export ZEABUR_ENV_ID='<environment-id>'
export ZEABUR_POSTGRES_ID='<postgres-service-id>'
export ZEABUR_MINIO_ID='<minio-service-id>'
export ZEABUR_API_ID='<api-service-id>'
export ZEABUR_WORKER_ID='<worker-service-id>'
export ZEABUR_WEB_ID='<web-service-id>'
export ZEABUR_ADMIN_ID='<admin-service-id>'
export GITHUB_REPO_ID='<github-repo-numeric-id>'

OLD_WEB_URL='https://<old-web>.zeabur.app'
OLD_ADMIN_URL='https://<old-admin>.zeabur.app'

# --- GCP ------------------------------------------------------------------
GCP_PROJECT='<gcp-project>'
GCP_ZONE='<zone>'                 # 例如 asia-east1-b；不要依賴 gcloud 的預設值
GCP_VM='<vm-name>'
GCP_DB_USER='<db-user>'           # VM 上 Postgres 的使用者與資料庫
GCP_DB_NAME='<db-name>'
ASSETS_BUCKET='<assets-bucket>'   # 放 app 檔案的 GCS bucket（不含 gs://）
# 列出資料庫參照的每個 object key（一行一個），verify.sh 用它確認檔案都在 GCS
FILES_KEY_QUERY='<select key from your_files_table>'
# 切換時先暫停 API，等這麼多秒讓 worker 做完手上的 job、清空佇列，再暫停 worker
DRAIN_SECONDS=60

NEW_WEB_URL='https://www.example.com'
NEW_API_URL='https://api.example.com'
NEW_ADMIN_URL='https://admin.example.com'

export CLOUDSDK_CORE_DISABLE_PROMPTS=1

# --- 函式 -----------------------------------------------------------------
die() { echo "error: $*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

# 檢查設定都填了：require VAR...
require() {
  local v
  for v in "$@"; do
    case "${!v:-}" in '' | '<'* | *'<'*'>'*) die "set $v in zeabur-lib.sh first" ;; esac
  done
}

# 固定 CLI 版本：切換當晚 CLI 改版不能改掉 exec 的輸出格式
zeabur() { npx --yes zeabur@0.24.0 "$@"; }

# 在 Zeabur 容器裡執行指令。輸出經過終端機（CRLF），一次回應又有大小上限：
# 去掉 \r，每次只取少量輸出（大檔案用 fetch-file.sh 分片取回）
zexec() {
  local id=$1
  shift
  zeabur service exec --id "$id" --env-id "$ZEABUR_ENV_ID" -i=false -- "$@" 2>/dev/null | tr -d '\r'
}

# VM 上執行指令、傳檔案（SSH 只走 IAP）
gssh() {
  gcloud compute ssh "$GCP_VM" --project "$GCP_PROJECT" --zone "$GCP_ZONE" --tunnel-through-iap --quiet --command "$1"
}
gscp() {
  gcloud compute scp --project "$GCP_PROJECT" --zone "$GCP_ZONE" --tunnel-through-iap --quiet "$@"
}
