# shellcheck shell=bash
# shellcheck disable=SC2034  # 這是設定檔：變數由 source 它的腳本使用
# 共用設定與函式。由其他 bash 腳本 `source` 載入，不要直接執行。
# 把每個 '<...>' 換成自己的值；腳本用 require 檢查自己需要的設定，沒填就停。
# zeabur-discover.py 會印出建議的 Zeabur 設定；GCP 的值來自 `infra/gcp/tf.sh output`。
#
# Zeabur 服務 ID：npx zeabur@0.24.0 service list --project-id <ID> -i=false --json
# GitHub repo 的數字 ID 與 Zeabur 部署的分支：zeabur-discover.py 會印出來（也可以 gh api repos/<owner>/<repo> --jq .id）

# --- Zeabur ---------------------------------------------------------------
export ZEABUR_PROJECT_ID='<project-id>'
export ZEABUR_ENV_ID='<environment-id>'
export ZEABUR_POSTGRES_ID='<postgres-service-id>'
export ZEABUR_API_ID='<api-service-id>'
export ZEABUR_WORKER_ID='<worker-service-id>'
export ZEABUR_WEB_ID='<web-service-id>'
export ZEABUR_ADMIN_ID='<admin-service-id>'
# 服務沒有 Git 自動部署（用上傳部署）就把下面兩個都設成 ''：切換時跳過停用自動部署
export GITHUB_REPO_ID='<github-repo-numeric-id>'
# Zeabur 原本從哪個分支自動部署：切換時改指到不存在的分支，rollback.sh 改回這裡
ZEABUR_GIT_BRANCH='main'
# 這些服務的環境變數會合併進 app-env（sync-env.sh）；沒有的服務就從清單拿掉
ENV_SERVICE_IDS="$ZEABUR_API_ID $ZEABUR_WORKER_ID $ZEABUR_WEB_ID $ZEABUR_ADMIN_ID"
# app 的加密金鑰在 Zeabur 上的變數名稱（sync-env.sh 另存成 encryption-key 並比對指紋）；沒有就留空 ''
ENCRYPTION_KEY_VAR='ENCRYPTION_KEY'

# 檔案存放：用到哪一種就填哪一種，沒用到的留空字串 ''
#   MinIO（S3 相容）：物件複製到 GCS（sync-assets.sh）
ZEABUR_MINIO_ID=''                # 例如 '<minio-service-id>'
#   app 服務自己掛的 volume：整個目錄搬到 VM 的資料碟（sync-volume.sh），compose 再掛回同一個路徑。
#   每項是 <service-id>:<容器內目錄>:<VM 上的目錄>，以空白分隔
VOLUMES=''                        # 例如 '<api-service-id>:/data/media:/srv/data/media'

OLD_WEB_URL='https://<old-web>.zeabur.app'
OLD_ADMIN_URL='https://<old-admin>.zeabur.app'

# --- GCP ------------------------------------------------------------------
GCP_PROJECT='<gcp-project>'
GCP_REGION='<region>'             # 例如 asia-east1
GCP_ZONE='<zone>'                 # 例如 asia-east1-b；不要依賴 gcloud 的預設值
GCP_VM='<vm-name>'
GCP_PUBLIC_IP='<egress-ip>'       # infra/gcp/tf.sh output egress_ip：公開網域的 DNS A 記錄指向它
# VM 上 Postgres 的使用者與資料庫：要和 compose.yaml 的 POSTGRES_USER／POSTGRES_DB 相同
# （範本是 app／app）。Zeabur 那一邊的使用者與資料庫從容器的環境變數讀，不用填。
GCP_DB_USER='app'
GCP_DB_NAME='app'
ASSETS_BUCKET='<assets-bucket>'   # infra/gcp/tf.sh output assets_bucket（不含 gs://）
ASSETS_SA='<assets-service-account-email>'   # infra/gcp/tf.sh output assets_service_account：app 存取 GCS 用的 HMAC 金鑰屬於它
# verify.sh 用：列出資料庫參照的每個檔案 key（一行一個）
FILES_KEY_QUERY='<select key from your_files_table>'
# 這些 key 在哪裡找：'gcs'（ASSETS_BUCKET）、'vm:<VM 上的目錄>'（例如 vm:/srv/data/media），
# 或 'none'（沒有要搬的檔案：FILES_KEY_QUERY 留空）
FILES_CHECK='gcs'
# 切換時先暫停 API，等這麼多秒讓 worker 做完手上的 job、清空佇列，再暫停 worker
DRAIN_SECONDS=60

NEW_WEB_URL='https://www.example.com'
NEW_API_URL='https://api.example.com'
NEW_ADMIN_URL='https://admin.example.com'

# dump、比對結果、取回的檔案放這裡，不放在專案目錄（裡面是正式環境的個資）
WORK=${MIGRATION_WORK:-$HOME/.zeabur-to-gcp-work}

export CLOUDSDK_CORE_DISABLE_PROMPTS=1

# --- 函式 -----------------------------------------------------------------
die() { echo "error: $*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

# 檢查設定都填了：require VAR...
require() {
  local v
  for v in "$@"; do
    case "${!v:-}" in '' | '<'* | *'<'*'>'* | *example.com*) die "set $v in zeabur-lib.sh first" ;; esac
  done
}

# 工作目錄：只有自己能讀
work_dir() {
  mkdir -p "$WORK"
  chmod 700 "$WORK"
}

# 把服務的 Git 自動部署指到某個分支：git_trigger <branch> <service-id>...（沒有自動部署就跳過）
git_trigger() {
  if [ -z "$GITHUB_REPO_ID" ]; then
    echo "GITHUB_REPO_ID is empty: no Git auto-deploy to change, skipped"
    return 0
  fi
  require GITHUB_REPO_ID
  python3 -I zeabur-git-trigger.py "$@"
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
